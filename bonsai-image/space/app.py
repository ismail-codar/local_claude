"""HF Space wrapper around scripts.local_backend.

Adds a metrics middleware that:
  - tracks total / success / error counters (cumulative since first launch)
  - per-shape latency histogram (rolling)
  - rolling 1000-request log with hashed-IP for unique-user count
  - per-day buckets (UTC date) for the daily archives the metrics_pusher
    sidecar writes under $BONSAI_STATE_DIR/daily/YYYY-MM-DD.json

State loaded at boot from $BONSAI_STATE_DIR/state.json so counters survive
Space restarts (assuming a persistent storage bucket is mounted; entrypoint
falls back to ephemeral disk otherwise).

Run with: uvicorn space.app:app
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import time
from collections import defaultdict, deque
from datetime import datetime, timezone
from threading import Lock

from fastapi import Request

# Re-export the real backend's app object so /generate, /backends, /docs
# are served untouched.
from scripts.local_backend import app  # noqa: F401  (re-exported)

# ── /backends override: restrict the studio picker (Space-only) ───────────────
# scripts.local_backend advertises both Bonsai variants. For this Space we
# restrict the picker to a single family (ternary) so mixed traffic doesn't
# make each replica thrash its resident transformer (ternary↔binary, ~1s/swap
# under nginx least_conn). Binary weights stay on disk + servable via a direct
# API call; the UI just won't offer the choice.
#
# Done here (Space wrapper) rather than in scripts/local_backend.py so the
# demo repo stays untouched. Strip the imported /backends route then register
# ours — FastAPI's router iterates in registration order, so re-adding the
# decorator without removing the original would be a no-op. Same pattern as
# scripts/local_backend_mac.py. Set BONSAI_SUPPORTED_FAMILIES (comma-separated)
# to override; defaults to both so removing the Space Variable restores parity
# with the upstream backend.
_SUPPORTED_FAMILIES = [
    f.strip()
    for f in os.environ.get(
        "BONSAI_SUPPORTED_FAMILIES", "bonsai-ternary,bonsai-binary"
    ).split(",")
    if f.strip()
]
app.router.routes = [
    r for r in app.router.routes if getattr(r, "path", "") != "/backends"
]


@app.get("/backends")
def _backends_restricted() -> dict:
    """Demo-shaped /backends with a configurable supported_families list.

    Mirrors scripts.local_backend._backends' kind/default_family derivation
    (split the resident arm's trailing -gemlite/-mlx), but swaps in the
    BONSAI_SUPPORTED_FAMILIES list so the picker can be narrowed per-Space.
    """
    arm = os.environ.get("MFLUX_STUDIO_GPU_DEFAULT_BACKEND", "bonsai-ternary-gemlite")
    if arm.endswith("-gemlite"):
        default_family, kind = arm[: -len("-gemlite")], "gemlite"
    elif arm.endswith("-mlx"):
        default_family, kind = arm[: -len("-mlx")], "mlx"
    else:
        default_family, kind = arm, "gemlite"
    return {
        "kind": kind,
        "supported_families": _SUPPORTED_FAMILIES,
        "default_family": default_family,
        "healthy": True,
        "reason": None,
    }

# ── in-memory state ──────────────────────────────────────────────────────────
_lock = Lock()
_started_at = time.monotonic()
_total = {"requests": 0, "success": 0, "errors": 0}
_by_shape: dict[str, dict] = defaultdict(
    lambda: {"count": 0, "duration_ms_total": 0, "durations": deque(maxlen=200)}
)
# Cumulative by-variant counter. The `variant` key is "ternary", "binary",
# or "unknown" (parsed from the request's `backend` field — see middleware).
# Mirrors by_shape's shape so the dashboard can show "ternary: X · binary: Y"
# across all time without re-summing the by_day history.
_by_variant: dict[str, dict] = defaultdict(
    lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}
)
_recent: deque = deque(maxlen=1000)

# Per-day buckets keyed by UTC YYYY-MM-DD. Last 30 days kept in memory;
# older days remain on disk (metrics_pusher writes one file per day under
# $BONSAI_STATE_DIR/daily/).
_MAX_DAYS_IN_MEMORY = 30
_by_day: dict[str, dict] = {}

# UTC bucketing. (We tried Pacific Time, but `zoneinfo.ZoneInfo` needs
# /usr/share/zoneinfo/ which our CUDA Ubuntu base image strips with
# --no-install-recommends. To re-enable PT, install `tzdata` in the
# Dockerfile and swap these back to ZoneInfo("America/Los_Angeles").)


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _now_hour() -> int:
    return datetime.now(timezone.utc).hour


def _empty_day() -> dict:
    return {
        "requests": 0,
        "success": 0,
        "errors": 0,
        # queue_ms_total at three levels: day-total + per_shape + per_gpu.
        # Day-total powers the dashboard's "today avg queue" tile; the
        # per-shape and per-gpu views surface where queueing pressure is
        # actually landing (e.g. is the slow GPU starving on small shapes?).
        "by_shape": defaultdict(lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}),
        "by_hour": [0] * 24,
        "unique_ips": set(),
        # Per-GPU attribution for this day. Persisted to state.json +
        # written into daily/YYYY-MM-DD.json so historical days retain
        # their original GPU split even after a tier swap.
        "by_gpu": defaultdict(lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}),
        # Per-variant attribution (ternary/binary/unknown). Tells you which
        # arm took the traffic on this day independent of which GPU served
        # it — useful for "did users actually click binary today, or are
        # they all defaulting to ternary?" analysis.
        "by_variant": defaultdict(lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}),
        "queue_ms_total": 0,
    }


def _bump_day(date: str, ok: bool, shape: str, dt_ms: int, queue_ms: int, hour: int, ip_hash: str, variant: str) -> None:
    """Increment today's bucket. Caller must hold _lock."""
    if date not in _by_day:
        _by_day[date] = _empty_day()
    d = _by_day[date]
    d["requests"] += 1
    if ok:
        d["success"] += 1
    else:
        d["errors"] += 1
    d["by_shape"][shape]["count"] += 1
    d["by_shape"][shape]["duration_ms_total"] += dt_ms
    d["by_shape"][shape]["queue_ms_total"] += queue_ms
    d["by_hour"][hour] += 1
    d["unique_ips"].add(ip_hash)
    d["by_gpu"][_GPU_NAME]["count"] += 1
    d["by_gpu"][_GPU_NAME]["duration_ms_total"] += dt_ms
    d["by_gpu"][_GPU_NAME]["queue_ms_total"] += queue_ms
    d["by_variant"][variant]["count"] += 1
    d["by_variant"][variant]["duration_ms_total"] += dt_ms
    d["by_variant"][variant]["queue_ms_total"] += queue_ms
    d["queue_ms_total"] += queue_ms
    if len(_by_day) > _MAX_DAYS_IN_MEMORY:
        for stale in sorted(_by_day)[:-_MAX_DAYS_IN_MEMORY]:
            del _by_day[stale]


# ── persisted state ──────────────────────────────────────────────────────────
# $BONSAI_STATE_DIR is set by entrypoint.sh — /data/state if a persistent
# storage bucket is mounted, else $APP_DIR/outputs/.state (ephemeral).
_STATE_DIR = os.environ.get("BONSAI_STATE_DIR", "/tmp")
_STATE_PATH = os.path.join(_STATE_DIR, "state.json")
# entrypoint.sh sets this to "1" when /data is mounted + writable, else "0".
# Surfaced to the dashboard so it can show a "counters won't persist" warning.
_PERSISTENT_STORAGE = os.environ.get("BONSAI_PERSISTENT_STORAGE", "0") == "1"


def _load_state() -> dict:
    """Return a dict with all persisted fields, or fresh defaults on miss / parse error."""
    fresh = {
        "pepper": os.urandom(16).hex().encode(),
        "totals": {"requests": 0, "success": 0, "errors": 0},
        "by_shape": {},
        "by_variant": {},  # parallel to by_shape; new in this build, may be missing in old state files
        "recent": [],
        "by_day": {},
    }
    try:
        with open(_STATE_PATH) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError) as exc:
        print(f"[space.app] no prior state ({type(exc).__name__}: {exc}); starting fresh", flush=True)
        return fresh
    try:
        fresh["pepper"] = (data.get("ip_pepper") or fresh["pepper"].decode()).encode()
        fresh["totals"] = {
            "requests": int(data.get("total_requests", 0)),
            "success": int(data.get("success", 0)),
            "errors": int(data.get("errors", 0)),
        }
        by_shape_raw = data.get("by_shape", {}) or {}
        by_shape_loaded = {}
        for shape, b in by_shape_raw.items():
            by_shape_loaded[shape] = {
                "count": int(b.get("count", 0)),
                "duration_ms_total": int(b.get("duration_ms_total", 0)),
                "durations": deque(maxlen=200),  # p50/p95 starts fresh after a boot
            }
        fresh["by_shape"] = by_shape_loaded
        # by_variant: parallel to by_shape, no `durations` deque (no need
        # for p50/p95 yet, just cumulative count + duration + queue).
        by_variant_raw = data.get("by_variant", {}) or {}
        by_variant_loaded = {}
        for variant, b in by_variant_raw.items():
            by_variant_loaded[variant] = {
                "count": int(b.get("count", 0)),
                "duration_ms_total": int(b.get("duration_ms_total", 0)),
                "queue_ms_total": int(b.get("queue_ms_total", 0)),
            }
        fresh["by_variant"] = by_variant_loaded
        fresh["recent"] = data.get("recent", []) or []
        # Per-day
        by_day_raw = data.get("by_day", {}) or {}
        by_day_loaded: dict[str, dict] = {}
        for date, d in by_day_raw.items():
            bd = _empty_day()
            bd["requests"] = int(d.get("requests", 0))
            bd["success"] = int(d.get("success", 0))
            bd["errors"] = int(d.get("errors", 0))
            # queue_ms_total fields default to 0 for state files persisted
            # before this feature shipped — keeps reload graceful.
            bd["queue_ms_total"] = int(d.get("queue_ms_total", 0))
            for shape, s in (d.get("by_shape", {}) or {}).items():
                bd["by_shape"][shape] = {
                    "count": int(s.get("count", 0)),
                    "duration_ms_total": int(s.get("duration_ms_total", 0)),
                    "queue_ms_total": int(s.get("queue_ms_total", 0)),
                }
            bh = d.get("by_hour") or [0] * 24
            bd["by_hour"] = list(bh) + [0] * max(0, 24 - len(bh))
            bd["unique_ips"] = set(d.get("unique_ips", []) or [])
            for gpu_name, g in (d.get("by_gpu", {}) or {}).items():
                bd["by_gpu"][gpu_name] = {
                    "count": int(g.get("count", 0)),
                    "duration_ms_total": int(g.get("duration_ms_total", 0)),
                    "queue_ms_total": int(g.get("queue_ms_total", 0)),
                }
            for variant_name, v in (d.get("by_variant", {}) or {}).items():
                bd["by_variant"][variant_name] = {
                    "count": int(v.get("count", 0)),
                    "duration_ms_total": int(v.get("duration_ms_total", 0)),
                    "queue_ms_total": int(v.get("queue_ms_total", 0)),
                }
            by_day_loaded[date] = bd
        fresh["by_day"] = by_day_loaded
    except Exception as exc:
        print(f"[space.app] state file partially malformed ({exc}); using what we could parse", flush=True)
    return fresh


# ── replica gating for multi-GPU deploys ─────────────────────────────────────
# Each uvicorn process (one per GPU) sets BONSAI_REPLICA_INDEX via entrypoint.
# Only replica 0 seeds its in-memory counters from state.json — other
# replicas start at zero. metrics_pusher polls every replica and sums them,
# so this avoids N-way inflation of cumulative counts. Pepper comes from
# the env (set by entrypoint), shared across all replicas so unique-user
# hashing is consistent.
_REPLICA_INDEX = int(os.environ.get("BONSAI_REPLICA_INDEX", "0"))
# Name of the GPU this replica is pinned to (entrypoint sets it from
# `nvidia-smi --query-gpu=name`). Exposed in /metrics so the pusher can
# aggregate per-GPU averages on the dashboard. Falls back to "unknown"
# if not provided.
# Default to NVIDIA L40S if entrypoint didn't supply a name — that's the
# tier we ran on for most of the demo's history, so unattributed counters
# get folded into the L40S bucket rather than a misleading "unknown".
_GPU_NAME = os.environ.get("BONSAI_GPU_NAME", "").strip() or "NVIDIA L40S"
_loaded = _load_state()
if _REPLICA_INDEX == 0:
    _total.update(_loaded["totals"])
    for _s, _b in _loaded["by_shape"].items():
        _by_shape[_s] = _b
    for _v, _b in _loaded["by_variant"].items():
        _by_variant[_v] = _b
    for _r in _loaded["recent"][-1000:]:
        _recent.append(_r)
    _by_day.update(_loaded["by_day"])
    print(
        f"[space.app] replica 0: seeded counters from {_STATE_PATH} "
        f"(requests={_total['requests']} days={len(_by_day)} "
        f"persistent_storage={_PERSISTENT_STORAGE})",
        flush=True,
    )
else:
    print(
        f"[space.app] replica {_REPLICA_INDEX}: starting counters at 0 "
        f"(replica 0 owns cumulative state)",
        flush=True,
    )

# Pepper: prefer env (entrypoint exports a single value for all replicas).
# Fall back to whatever _load_state surfaced (typically random on first
# launch) — fine for single-replica or testing.
_IP_PEPPER = os.environ.get("BONSAI_IP_PEPPER", _loaded["pepper"].decode()).encode()


def _hash_ip(ip: str) -> str:
    return hashlib.sha256(_IP_PEPPER + ip.encode()).hexdigest()[:12]


# Concurrency cap per replica. Image-gen is compute-bound; two concurrent
# requests at one GPU just contend for the same SMs and serialize at the
# kernel-launch level, wasting time. With Semaphore(1), additional requests
# queue at the asyncio level, and nginx's least_conn sees them as "this
# replica is busy" → routes to a free GPU when one's available.
_GENERATE_CONCURRENCY = int(os.environ.get("BONSAI_GENERATE_CONCURRENCY", "1"))
_generate_sem = asyncio.Semaphore(_GENERATE_CONCURRENCY)

# In-flight gauge. Incremented when a /generate request enters the middleware
# (before semaphore acquire — so queued requests count), decremented in
# finally. metrics_pusher sums across replicas and derives queue depth as
# max(0, total_inflight - total_concurrency).
_inflight = 0
_inflight_lock = Lock()

# Mirror the live inflight to a tiny file on every change. The /metrics HTTP
# scrape is unreadable while this replica is mid-generation (pipeline.generate_png
# holds the GIL, so the scrape times out exactly when inflight is highest) — so
# the dashboard's "pending" gauge always sampled ~0. metrics_pusher reads this
# file instead: a filesystem read needs no HTTP and no GIL, so it reflects the
# true queue depth even while the replica is busy. Written in the async
# middleware at request enter/exit, NOT during the GIL-bound generation, so the
# write itself never contends with inference.
_INFLIGHT_DIR = os.environ.get("BONSAI_INFLIGHT_DIR", "/tmp")
_INFLIGHT_PATH = os.path.join(_INFLIGHT_DIR, f"inflight-{_REPLICA_INDEX}.txt")


def _write_inflight(value: int) -> None:
    """Persist the current inflight count. Best-effort — a failed write just
    means the pusher falls back to the (stale) scraped value for this tick."""
    try:
        with open(_INFLIGHT_PATH, "w") as f:
            f.write(str(value))
    except OSError:
        pass


# Seed the file at 0 so the pusher sees a valid value before the first request.
_write_inflight(0)


# ── middleware ───────────────────────────────────────────────────────────────
@app.middleware("http")
async def _track_generate(request: Request, call_next):
    if request.url.path != "/generate" or request.method != "POST":
        return await call_next(request)

    # Read + replay the body so the downstream handler still sees it.
    body = await request.body()

    async def _receive() -> dict:
        return {"type": "http.request", "body": body, "more_body": False}

    request._receive = _receive  # type: ignore[attr-defined]

    shape = "unknown"
    # variant: "ternary" / "binary" / "unknown". Parsed from the request's
    # `backend` field — values look like "bonsai-ternary-gemlite" or
    # "bonsai-binary-mlx". If the client omits backend, FastAPI's default
    # picks the resident pipeline arm (set by MFLUX_STUDIO_GPU_DEFAULT_BACKEND
    # in entrypoint.sh — currently bonsai-ternary-gemlite) so we mirror that
    # default here for fair attribution.
    variant = "ternary"
    try:
        payload = json.loads(body or b"{}")
        w, h = int(payload.get("width", 0)), int(payload.get("height", 0))
        if w and h:
            shape = f"{w}x{h}"
        backend = (payload.get("backend") or "").lower()
        if "ternary" in backend:
            variant = "ternary"
        elif "binary" in backend:
            variant = "binary"
        elif backend:
            variant = "unknown"
        # else: backend missing → keep the default "ternary" set above
    except Exception:
        pass

    # Identity for unique-user counting. Preference order:
    #   1. X-IP-Token — set by HF when the visitor is logged into
    #      huggingface.co and viewing the Space via the embed. Tied to
    #      their HF session, stable across home↔mobile network changes.
    #   2. X-Forwarded-For — real client IP, set by nginx (and propagated
    #      by Next.js's /api/generate route handler).
    #   3. request.client.host — direct-loopback fallback (mostly never).
    # The "hf:" / "ip:" prefix keeps the two namespaces from colliding.
    hf_token = request.headers.get("x-ip-token")
    if hf_token:
        identity = f"hf:{hf_token}"
    else:
        forwarded = request.headers.get("x-forwarded-for")
        ip = forwarded.split(",")[0].strip() if forwarded else (request.client.host if request.client else "0.0.0.0")
        identity = f"ip:{ip}"
    ip_hash = _hash_ip(identity)

    date = _today()
    hour = _now_hour()

    # Increment in-flight gauge BEFORE the semaphore so queued requests are
    # visible to the dashboard ("X pending"). Decrement in finally so the
    # gauge stays accurate even on exceptions.
    global _inflight
    t_enqueue = time.monotonic()
    with _inflight_lock:
        _inflight += 1
        _write_inflight(_inflight)
    try:
        # Queue at the semaphore so only N requests per replica run on the
        # GPU at once. The HTTP connection stays open while we wait, which
        # makes nginx's least_conn see this replica as busy → routes new
        # arrivals to a free GPU when one's available.
        async with _generate_sem:
            t_start = time.monotonic()
            queue_ms = int((t_start - t_enqueue) * 1000)
            try:
                response = await call_next(request)
            except Exception:
                dt_ms = int((time.monotonic() - t_start) * 1000)
                with _lock:
                    _total["requests"] += 1
                    _total["errors"] += 1
                    _by_variant[variant]["count"] += 1
                    _by_variant[variant]["duration_ms_total"] += dt_ms
                    _by_variant[variant]["queue_ms_total"] += queue_ms
                    _recent.append({"ts": int(time.time()), "shape": shape, "duration_ms": dt_ms, "queue_ms": queue_ms, "ip_hash": ip_hash, "gpu": _GPU_NAME, "variant": variant, "ok": False})
                    _bump_day(date, False, shape, dt_ms, queue_ms, hour, ip_hash, variant)
                raise

            dt_ms = int((time.monotonic() - t_start) * 1000)
            ok = response.status_code < 400
            with _lock:
                _total["requests"] += 1
                if ok:
                    _total["success"] += 1
                else:
                    _total["errors"] += 1
                bucket = _by_shape[shape]
                bucket["count"] += 1
                bucket["duration_ms_total"] += dt_ms
                bucket["durations"].append(dt_ms)
                _by_variant[variant]["count"] += 1
                _by_variant[variant]["duration_ms_total"] += dt_ms
                _by_variant[variant]["queue_ms_total"] += queue_ms
                _recent.append({"ts": int(time.time()), "shape": shape, "duration_ms": dt_ms, "queue_ms": queue_ms, "ip_hash": ip_hash, "gpu": _GPU_NAME, "variant": variant, "ok": ok})
                _bump_day(date, ok, shape, dt_ms, queue_ms, hour, ip_hash, variant)
        return response
    finally:
        with _inflight_lock:
            _inflight -= 1
            _write_inflight(_inflight)


# ── /metrics endpoint (loopback-only via nginx) ──────────────────────────────
def _percentile(xs: list[int], p: int) -> int | None:
    if not xs:
        return None
    s = sorted(xs)
    idx = min(int(len(s) * p / 100), len(s) - 1)
    return s[idx]


@app.get("/metrics")
def get_metrics() -> dict:
    """Scraped by metrics_pusher every few seconds. Returns the full in-memory
    state so the sidecar can rebuild analytics.json + write daily archives.
    """
    with _lock:
        by_shape = {}
        for shape, b in _by_shape.items():
            durs = list(b["durations"])
            by_shape[shape] = {
                "count": b["count"],
                "duration_ms_total": b["duration_ms_total"],
                "duration_ms_p50": _percentile(durs, 50),
                "duration_ms_p95": _percentile(durs, 95),
            }

        by_day_out = {}
        for date, d in _by_day.items():
            by_day_out[date] = {
                "requests": d["requests"],
                "success": d["success"],
                "errors": d["errors"],
                # queue_ms_total exposed at all three levels (day + per-shape +
                # per-gpu) so the pusher can compute today's average queue at
                # arbitrary slicing without re-summing recent[].
                "queue_ms_total": d.get("queue_ms_total", 0),
                "by_shape": {
                    s: {
                        "count": b["count"],
                        "duration_ms_total": b["duration_ms_total"],
                        "queue_ms_total": b.get("queue_ms_total", 0),
                    }
                    for s, b in d["by_shape"].items()
                },
                "by_hour": list(d["by_hour"]),
                "unique_users": len(d["unique_ips"]),
                "unique_ips": list(d["unique_ips"]),  # for round-trip persistence
                "by_gpu": {
                    g: {
                        "count": v["count"],
                        "duration_ms_total": v["duration_ms_total"],
                        "queue_ms_total": v.get("queue_ms_total", 0),
                    }
                    for g, v in d["by_gpu"].items()
                },
                "by_variant": {
                    v: {
                        "count": b["count"],
                        "duration_ms_total": b["duration_ms_total"],
                        "queue_ms_total": b.get("queue_ms_total", 0),
                    }
                    for v, b in d.get("by_variant", {}).items()
                },
            }

        with _inflight_lock:
            inflight = _inflight
        # Replica's own cumulative duration sum (sum across all shapes).
        # Used by the pusher to compute per-GPU avg latency without
        # rebuilding it from `recent` (which would lose history).
        total_duration_ms = sum(b["duration_ms_total"] for b in _by_shape.values())
        return {
            "uptime_s": int(time.monotonic() - _started_at),
            "replica_index": _REPLICA_INDEX,
            "gpu_name": _GPU_NAME,
            "inflight": inflight,
            "generate_concurrency": _GENERATE_CONCURRENCY,
            "total_requests": _total["requests"],
            "success": _total["success"],
            "errors": _total["errors"],
            "total_duration_ms": total_duration_ms,
            "by_shape": by_shape,
            "by_variant": {
                v: {
                    "count": b["count"],
                    "duration_ms_total": b["duration_ms_total"],
                    "queue_ms_total": b.get("queue_ms_total", 0),
                }
                for v, b in _by_variant.items()
            },
            "by_day": by_day_out,
            "recent": list(_recent),
            "ip_pepper": _IP_PEPPER.decode(),
            "persistent_storage": _PERSISTENT_STORAGE,
            "state_dir": _STATE_DIR,
        }
