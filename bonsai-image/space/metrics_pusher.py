"""Sidecar that aggregates backend /metrics + nvidia-smi into JSON files.

On every tick (default 5 s) it writes:
  /tmp/analytics.json            current totals, today + 7d summaries, GPU info flag
  /tmp/gpu-stats.json            nvidia-smi snapshot

Every Nth tick (default 12 → ~1 min) it also writes:
  $BONSAI_STATE_DIR/state.json              boot-recovery snapshot
  $BONSAI_STATE_DIR/daily/YYYY-MM-DD.json   per-UTC-day archive (one file/day)

Robust to:
  - missing /data bucket (writes go to ephemeral $BONSAI_STATE_DIR fallback)
  - missing nvidia-smi
  - backend not yet up (HTTP errors logged, tick continues)
  - FUSE-backed mounts that don't support atomic rename (falls back to in-place)
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.request
from collections import defaultdict

# Day bucketing is in UTC — matches what space.app uses for `_by_day` keys
# (we tried PT but the CUDA Ubuntu base image strips tzdata).

BACKEND_URLS = [u.strip() for u in os.environ.get("BACKEND_URLS", "http://127.0.0.1:8000").split(",") if u.strip()]
INTERVAL = int(os.environ.get("METRICS_INTERVAL", "2"))
ANALYTICS_PATH = "/tmp/analytics.json"
GPU_PATH = "/tmp/gpu-stats.json"

# Persisted state. STATE_DIR is /data/state when a bucket is mounted, else
# ephemeral under outputs/ (gone on Space restart).
STATE_DIR = os.environ.get("BONSAI_STATE_DIR", "/tmp")
STATE_PATH = os.path.join(STATE_DIR, "state.json")
DAILY_DIR = os.path.join(STATE_DIR, "daily")

# Write durable files (state.json + daily archives) every Nth tick to amortize
# disk traffic. Losing N*INTERVAL seconds of counter increments on unclean
# shutdown is acceptable.
STATE_WRITE_EVERY_N_TICKS = int(os.environ.get("STATE_WRITE_EVERY_N_TICKS", "12"))

# Surfaces in analytics.json so the dashboard shows a "counters won't persist"
# banner when a bucket is not mounted. Set by entrypoint.sh.
PERSISTENT_STORAGE = os.environ.get("BONSAI_PERSISTENT_STORAGE", "0") == "1"


def _fetch_json(url: str, timeout: float = 5.0) -> dict | None:
    # 5s timeout (was 2s): under 16-concurrent /generate load the uvicorn
    # event loop can briefly queue /metrics behind in-flight responses.
    # 5s is still well under the dashboard's polling cadence (so the user
    # doesn't see a delay) and gives the backend headroom under stress.
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception:
        return None


# Per-replica last-good /metrics cache. A replica that's mid-generation holds
# the GIL during the CPU-bound stretches of pipeline.generate_png, so its
# /metrics scrape times out — even though the replica is perfectly healthy and
# the image finishes fine. Without this cache we'd drop it from the aggregate
# that tick, which makes the dashboard flicker "N-1 / N · 1 down" AND (if the
# dropped replica is replica 0, the one holding the cumulative counters while
# 1..N report deltas) briefly collapses the all-time totals toward zero.
#
# Carry forward the last successful scrape for up to _REPLICA_GRACE_SECONDS so
# a busy-but-alive replica stays counted with its last-known numbers. Only a
# replica that's been unreachable LONGER than the grace window is treated as
# genuinely down. Grace is set comfortably above the longest expected single
# generation (high-step / large-shape renders can hold the GIL ~30s).
_LAST_GOOD: dict[str, dict] = {}  # url -> {"ts": float, "data": dict}
_REPLICA_GRACE_SECONDS = 90.0

# Each backend writes its live inflight to inflight-<replica_index>.txt (see
# space/app.py). We read that file instead of trusting the /metrics `inflight`
# field, because the scrape times out exactly when a replica is busy (GIL held
# by generation) — so the scraped value is stale-low and "pending" always
# showed 0. A filesystem read has no such blind spot.
_INFLIGHT_DIR = os.environ.get("BONSAI_INFLIGHT_DIR", "/tmp")


def _read_inflight_file(replica_index) -> int | None:
    """Live inflight for a replica from its on-disk gauge. None if unavailable
    (file missing / unparseable / no index) → caller falls back to scraped."""
    if replica_index is None:
        return None
    try:
        with open(os.path.join(_INFLIGHT_DIR, f"inflight-{replica_index}.txt")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def fetch_backend_metrics() -> dict:
    """Aggregate /metrics from every backend replica."""
    agg: dict = {
        "total_requests": 0,
        "success": 0,
        "errors": 0,
        "uptime_s": 0,
        "inflight": 0,             # sum across replicas — total in-flight requests
        "generate_capacity": 0,    # sum of per-replica concurrency caps
        "replicas_seen": 0,        # how many replicas answered /metrics this tick
        # Per-replica details — list of {gpu_name, inflight, capacity,
        # uptime_s, total_requests}. Used to compute accurate queue_depth
        # (sum of per-replica (inflight - capacity)+ rather than the sum-
        # then-subtract approximation that hides imbalance) and to render
        # the multi-GPU health card on the dashboard.
        "per_replica": [],
        "by_shape": defaultdict(lambda: {"count": 0, "duration_ms_total": 0}),
        # Cumulative per-variant counter. Replicas each report their own
        # _by_variant; we sum them here. Variants are "ternary", "binary",
        # or "unknown" — parsed from the request's `backend` field.
        "by_variant": defaultdict(lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}),
        "by_day": {},  # date -> {requests, success, errors, by_shape, by_hour, unique_ips set, queue_ms_total}
        # Per-GPU model breakdown — each replica's gpu_name + counts +
        # duration sum get folded in. Multiple replicas on the same GPU
        # model (e.g. l40sx4 = 4× "NVIDIA L40S") merge into one bucket.
        "by_gpu": defaultdict(lambda: {"count": 0, "success": 0, "errors": 0, "duration_ms_total": 0, "replicas": 0}),
        "recent": [],
        "ip_pepper": None,
    }
    for url in BACKEND_URLS:
        data = _fetch_json(f"{url}/metrics")
        if data:
            # Fresh scrape — remember it for the next time this replica is
            # busy and times out.
            _LAST_GOOD[url] = {"ts": time.time(), "data": data}
        else:
            # Scrape failed/timed out. If we have a recent good scrape, the
            # replica is almost certainly just busy generating — reuse it so
            # the replica stays counted and cumulative totals don't dip.
            cached = _LAST_GOOD.get(url)
            if cached and (time.time() - cached["ts"]) < _REPLICA_GRACE_SECONDS:
                data = cached["data"]
            else:
                continue  # genuinely unreachable (or never seen) → omit
        agg["replicas_seen"] += 1
        agg["total_requests"] += data.get("total_requests", 0)
        agg["success"] += data.get("success", 0)
        agg["errors"] += data.get("errors", 0)
        agg["uptime_s"] = max(agg["uptime_s"], data.get("uptime_s", 0))
        # Prefer the on-disk inflight gauge (accurate even mid-generation);
        # fall back to the scraped value if the file isn't there yet.
        _file_inflight = _read_inflight_file(data.get("replica_index"))
        replica_inflight = _file_inflight if _file_inflight is not None else data.get("inflight", 0)
        replica_capacity = data.get("generate_concurrency", 1)
        agg["inflight"] += replica_inflight
        agg["generate_capacity"] += replica_capacity
        # Per-GPU rollup — fold this replica's totals into its GPU bucket.
        # Default to NVIDIA L40S when missing so historical /metrics without
        # gpu_name (pre-this-feature) don't show up as "unknown".
        gpu = data.get("gpu_name") or "NVIDIA L40S"
        # Per-replica record — keep the gpu_name + cap so the dashboard's
        # multi-GPU health card can render "L40S · 1/1 busy" style rows
        # and the queue calc can subtract per-replica.
        agg["per_replica"].append({
            "url": url,
            "gpu_name": gpu,
            "inflight": replica_inflight,
            "capacity": replica_capacity,
            "uptime_s": data.get("uptime_s", 0),
            "total_requests": data.get("total_requests", 0),
            "replica_index": data.get("replica_index"),
        })
        g = agg["by_gpu"][gpu]
        g["count"] += data.get("total_requests", 0)
        g["success"] += data.get("success", 0)
        g["errors"] += data.get("errors", 0)
        g["duration_ms_total"] += data.get("total_duration_ms", 0)
        g["replicas"] += 1
        for shape, b in data.get("by_shape", {}).items():
            agg["by_shape"][shape]["count"] += b.get("count", 0)
            agg["by_shape"][shape]["duration_ms_total"] += b.get("duration_ms_total", 0)
        for v_name, v_data in (data.get("by_variant") or {}).items():
            agg["by_variant"][v_name]["count"] += v_data.get("count", 0)
            agg["by_variant"][v_name]["duration_ms_total"] += v_data.get("duration_ms_total", 0)
            agg["by_variant"][v_name]["queue_ms_total"] += v_data.get("queue_ms_total", 0)
        # Per-day merge: when we go multi-replica, each replica returns its
        # own _by_day → we union them here (sum counters, union unique_ips).
        for date, d in data.get("by_day", {}).items():
            existing = agg["by_day"].setdefault(date, {
                "requests": 0, "success": 0, "errors": 0,
                "by_shape": defaultdict(lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}),
                "by_hour": [0] * 24,
                "unique_ips": set(),
                "by_gpu": defaultdict(lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}),
                "by_variant": defaultdict(lambda: {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0}),
                "queue_ms_total": 0,
            })
            existing["requests"] += d.get("requests", 0)
            existing["success"] += d.get("success", 0)
            existing["errors"] += d.get("errors", 0)
            existing["queue_ms_total"] += d.get("queue_ms_total", 0)
            for shape, b in d.get("by_shape", {}).items():
                existing["by_shape"][shape]["count"] += b.get("count", 0)
                existing["by_shape"][shape]["duration_ms_total"] += b.get("duration_ms_total", 0)
                existing["by_shape"][shape]["queue_ms_total"] += b.get("queue_ms_total", 0)
            for i, c in enumerate(d.get("by_hour") or [0] * 24):
                if i < 24:
                    existing["by_hour"][i] += c
            for h in d.get("unique_ips", []) or []:
                existing["unique_ips"].add(h)
            for g_name, g_data in (d.get("by_gpu") or {}).items():
                existing["by_gpu"][g_name]["count"] += g_data.get("count", 0)
                existing["by_gpu"][g_name]["duration_ms_total"] += g_data.get("duration_ms_total", 0)
                existing["by_gpu"][g_name]["queue_ms_total"] += g_data.get("queue_ms_total", 0)
            for v_name, v_data in (d.get("by_variant") or {}).items():
                existing["by_variant"][v_name]["count"] += v_data.get("count", 0)
                existing["by_variant"][v_name]["duration_ms_total"] += v_data.get("duration_ms_total", 0)
                existing["by_variant"][v_name]["queue_ms_total"] += v_data.get("queue_ms_total", 0)
        agg["recent"].extend(data.get("recent", []))
        agg["ip_pepper"] = agg["ip_pepper"] or data.get("ip_pepper")

    agg["recent"].sort(key=lambda r: r.get("ts", 0))
    agg["recent"] = agg["recent"][-2000:]
    return agg


def fetch_gpu_stats() -> dict:
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit",
                "--format=csv,noheader,nounits",
            ],
            timeout=2,
        ).decode()
    except Exception as exc:
        return {"ts": int(time.time()), "gpus": [], "error": str(exc)}

    def _maybe_int(s: str) -> int | None:
        s = s.strip()
        return int(s) if s.isdigit() else None

    def _maybe_float(s: str) -> float | None:
        try:
            return float(s.strip())
        except ValueError:
            return None

    gpus = []
    for line in out.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 8:
            continue
        gpus.append({
            "index": int(parts[0]),
            "name": parts[1],
            "util_pct": _maybe_int(parts[2]),
            "memory_used_mb": _maybe_int(parts[3]),
            "memory_total_mb": _maybe_int(parts[4]),
            "temp_c": _maybe_int(parts[5]),
            "power_w": _maybe_float(parts[6]),
            "power_limit_w": _maybe_float(parts[7]),
        })
    return {"ts": int(time.time()), "gpus": gpus}


def build_analytics(backend_data: dict) -> dict:
    """The JSON the dashboard polls. Derived from /metrics so they stay in sync."""
    now = int(time.time())
    today = time.strftime("%Y-%m-%d", time.gmtime(now))

    by_shape_total = {}
    for shape, b in backend_data["by_shape"].items():
        avg = b["duration_ms_total"] // b["count"] if b["count"] else 0
        by_shape_total[shape] = {"count": b["count"], "duration_ms_avg": avg}

    # Latency stats derived from the last 50 requests only — same set the
    # dashboard renders in its Recent Requests table. Keeps the latency
    # numbers reactive to current load rather than smoothed by old data.
    recent_window = backend_data["recent"][-50:]
    recent_by_shape_acc: dict[str, dict] = {}
    for r in recent_window:
        s = r.get("shape") or "unknown"
        d = recent_by_shape_acc.setdefault(s, {"count": 0, "duration_ms_total": 0, "queue_ms_total": 0})
        d["count"] += 1
        d["duration_ms_total"] += int(r.get("duration_ms") or 0)
        d["queue_ms_total"] += int(r.get("queue_ms") or 0)

    recent_by_shape = {}
    for s, b in recent_by_shape_acc.items():
        recent_by_shape[s] = {
            "count": b["count"],
            "duration_ms_avg": b["duration_ms_total"] // b["count"] if b["count"] else 0,
            "queue_ms_avg": b["queue_ms_total"] // b["count"] if b["count"] else 0,
        }
    recent_count_total = sum(b["count"] for b in recent_by_shape_acc.values())
    recent_duration_total = sum(b["duration_ms_total"] for b in recent_by_shape_acc.values())
    recent_avg_latency_ms = recent_duration_total // recent_count_total if recent_count_total else 0

    today_bucket = backend_data["by_day"].get(today, {})
    today_unique_set = today_bucket.get("unique_ips", set())
    today_unique = len(today_unique_set if isinstance(today_unique_set, set) else list(today_unique_set))

    # Today-only mirrors of by_shape_total and by_gpu_out. Same shape so the
    # dashboard can render them with the same table helpers; only the scope
    # differs (cumulative vs reset-at-UTC-midnight). Useful for spotting
    # today's tier mix or shape distribution at a glance vs the all-time avg
    # which smooths over the full history. queue_ms_avg is included so the
    # tables can show how queueing pressure is distributed.
    by_shape_today = {}
    for shape, b in (today_bucket.get("by_shape") or {}).items():
        c = b.get("count", 0)
        by_shape_today[shape] = {
            "count": c,
            "duration_ms_avg": (b.get("duration_ms_total", 0) // c) if c else 0,
            "queue_ms_avg": (b.get("queue_ms_total", 0) // c) if c else 0,
        }
    by_gpu_today = {}
    for gpu_name, b in (today_bucket.get("by_gpu") or {}).items():
        c = b.get("count", 0)
        by_gpu_today[gpu_name] = {
            "count": c,
            "duration_ms_avg": (b.get("duration_ms_total", 0) // c) if c else 0,
            "queue_ms_avg": (b.get("queue_ms_total", 0) // c) if c else 0,
        }
    # by_variant slices: cumulative (across all of by_day history) + today.
    # Today's view drives the new Variant tile in the dashboard summary row.
    by_variant_total = {}
    for v_name, b in backend_data["by_variant"].items():
        c = b.get("count", 0)
        by_variant_total[v_name] = {
            "count": c,
            "duration_ms_avg": (b.get("duration_ms_total", 0) // c) if c else 0,
            "queue_ms_avg": (b.get("queue_ms_total", 0) // c) if c else 0,
        }
    by_variant_today = {}
    for v_name, b in (today_bucket.get("by_variant") or {}).items():
        c = b.get("count", 0)
        by_variant_today[v_name] = {
            "count": c,
            "duration_ms_avg": (b.get("duration_ms_total", 0) // c) if c else 0,
            "queue_ms_avg": (b.get("queue_ms_total", 0) // c) if c else 0,
        }
    # Today's overall avg queue, summed across all shapes/gpus. Surfaced as
    # a single number in the Pending tile subtitle on the dashboard.
    today_count = today_bucket.get("requests", 0)
    today_avg_queue_ms = (today_bucket.get("queue_ms_total", 0) // today_count) if today_count else 0

    def _summary_for_last(n_days: int) -> dict:
        days = sorted(backend_data["by_day"].keys())[-n_days:]
        req = sum(backend_data["by_day"][d].get("requests", 0) for d in days)
        uniques: set = set()
        for d in days:
            ips = backend_data["by_day"][d].get("unique_ips", set())
            uniques.update(ips if isinstance(ips, set) else list(ips))
        return {"requests": req, "unique_users": len(uniques)}

    # Include per-GPU counts on each day so the dashboard can stack the daily
    # chart by GPU. Each day's by_gpu dict only carries GPUs that actually
    # served traffic that day, so the dashboard derives the union of all GPU
    # names client-side and fills missing days with 0. duration_ms_total is
    # surfaced too so a future "stacked latency view" doesn't need new fields.
    requests_by_day = [
        {
            "date": d,
            "count": backend_data["by_day"][d].get("requests", 0),
            "by_gpu": {
                g_name: {
                    "count": g.get("count", 0),
                    "duration_ms_total": g.get("duration_ms_total", 0),
                }
                for g_name, g in (backend_data["by_day"][d].get("by_gpu") or {}).items()
            },
        }
        for d in sorted(backend_data["by_day"].keys())[-30:]
    ]
    requests_by_hour = list(today_bucket.get("by_hour", [0] * 24))

    # Overall average latency, derived from by_shape (since duration totals
    # live there, not in the cumulative counter).
    total_duration_ms = sum(b["duration_ms_total"] for b in backend_data["by_shape"].values())
    total_durations_count = sum(b["count"] for b in backend_data["by_shape"].values())
    avg_latency_ms = total_duration_ms // total_durations_count if total_durations_count else 0

    # Queue depth = whatever is in-flight beyond GPU-running capacity. Has
    # to be summed PER REPLICA: if 4 are queued on replica 0 and replica 1
    # is idle, naive sum(inflight) - sum(capacity) = max(0, 4-2) = 2 hides
    # the fact that replica 0 has a 3-deep queue while replica 1 idles.
    # Per-replica max(0, inflight-capacity) correctly attributes the queue.
    per_replica = backend_data.get("per_replica", [])
    inflight = sum(r["inflight"] for r in per_replica) if per_replica else backend_data.get("inflight", 0)
    capacity = sum(r["capacity"] for r in per_replica) if per_replica else (
        backend_data.get("generate_capacity", 0) or backend_data.get("replicas_seen", 1)
    )
    queue_depth = sum(max(0, r["inflight"] - r["capacity"]) for r in per_replica)
    running = sum(min(r["inflight"], r["capacity"]) for r in per_replica) if per_replica else min(inflight, capacity)

    # Per-GPU breakdown for the bottom-of-dashboard "By GPU" card. Count,
    # success/error split, avg latency per GPU model. Useful for spotting
    # variance between tiers (e.g. L40S vs T4) during benchmarking.
    by_gpu_out = {}
    for gpu_name, b in backend_data["by_gpu"].items():
        c = b["count"]
        by_gpu_out[gpu_name] = {
            "count": c,
            "success": b["success"],
            "errors": b["errors"],
            "duration_ms_avg": b["duration_ms_total"] // c if c else 0,
            "duration_ms_total": b["duration_ms_total"],
            "replicas": b["replicas"],
        }

    return {
        "updated_at": now,
        "uptime_s": backend_data.get("uptime_s", 0),
        "persistent_storage": PERSISTENT_STORAGE,
        "state_dir": STATE_DIR,
        "replicas_seen": backend_data.get("replicas_seen", 0),
        # entrypoint.sh sets BACKEND_URLS once per boot, so this is the
        # number we *expect* to see — diff against replicas_seen tells the
        # dashboard "1 replica is unhealthy" vs "2 of 2 happy".
        "replicas_expected": len(BACKEND_URLS),
        "per_replica": backend_data.get("per_replica", []),
        "inflight": inflight,
        "running": running,
        "queue_depth": queue_depth,
        "capacity": capacity,
        "today_avg_queue_ms": today_avg_queue_ms,
        "summary_total": {
            "requests": backend_data["total_requests"],
            "success": backend_data["success"],
            "errors": backend_data["errors"],
        },
        "summary_today": {
            "requests": today_bucket.get("requests", 0),
            "unique_users": today_unique,
        },
        "summary_7d": _summary_for_last(7),
        "summary_30d": _summary_for_last(30),
        "avg_latency_ms": avg_latency_ms,
        "by_shape": by_shape_total,
        "by_shape_today": by_shape_today,
        "by_gpu": by_gpu_out,
        "by_gpu_today": by_gpu_today,
        "by_variant": by_variant_total,
        "by_variant_today": by_variant_today,
        "recent_by_shape": recent_by_shape,
        "recent_avg_latency_ms": recent_avg_latency_ms,
        "recent_count": recent_count_total,
        "requests_by_hour": requests_by_hour,
        "requests_by_day": requests_by_day,
        "recent": backend_data["recent"][-100:],
    }


def _atomic_write(path: str, payload: dict, indent: int | None = None) -> None:
    """Write JSON atomically. Falls back to direct overwrite if rename fails
    (some FUSE-backed mounts don't support rename within a dir)."""
    text = json.dumps(payload, indent=indent, sort_keys=indent is not None)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError as exc:
        print(f"[metrics_pusher] atomic rename failed for {path} ({exc}); writing in place", flush=True)
        try:
            with open(path, "w") as f:
                f.write(text)
        except OSError as exc2:
            print(f"[metrics_pusher] direct write also failed for {path} ({exc2})", flush=True)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def write_state(backend_data: dict) -> None:
    """Snapshot for boot-recovery. Includes per-day so the app can resume
    counter buckets for in-flight days."""
    by_day_out = {}
    for date, d in backend_data["by_day"].items():
        ips = d["unique_ips"]
        by_day_out[date] = {
            "requests": d["requests"],
            "success": d["success"],
            "errors": d["errors"],
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
            "unique_ips": sorted(ips) if isinstance(ips, set) else list(ips),
            "by_gpu": {
                g: {
                    "count": v["count"],
                    "duration_ms_total": v["duration_ms_total"],
                    "queue_ms_total": v.get("queue_ms_total", 0),
                }
                for g, v in (d.get("by_gpu") or {}).items()
            },
            "by_variant": {
                v: {
                    "count": b["count"],
                    "duration_ms_total": b["duration_ms_total"],
                    "queue_ms_total": b.get("queue_ms_total", 0),
                }
                for v, b in (d.get("by_variant") or {}).items()
            },
        }
    payload = {
        "total_requests": backend_data["total_requests"],
        "success": backend_data["success"],
        "errors": backend_data["errors"],
        "by_shape": {
            shape: {"count": b["count"], "duration_ms_total": b["duration_ms_total"]}
            for shape, b in backend_data["by_shape"].items()
        },
        "by_variant": {
            v: {
                "count": b["count"],
                "duration_ms_total": b["duration_ms_total"],
                "queue_ms_total": b.get("queue_ms_total", 0),
            }
            for v, b in backend_data["by_variant"].items()
        },
        "by_day": by_day_out,
        "recent": backend_data["recent"][-100:],
        "ip_pepper": backend_data.get("ip_pepper"),
        "saved_at": int(time.time()),
    }
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
    except OSError as exc:
        print(f"[metrics_pusher] mkdir {STATE_DIR} failed ({exc}); skipping state write", flush=True)
        return
    _atomic_write(STATE_PATH, payload)


def write_daily_archives(backend_data: dict) -> None:
    """One JSON file per UTC date. Today's file gets rewritten each tick; past
    days only on a restart that reloads their bucket from state.json."""
    if not backend_data["by_day"]:
        return
    try:
        os.makedirs(DAILY_DIR, exist_ok=True)
    except OSError as exc:
        print(f"[metrics_pusher] mkdir {DAILY_DIR} failed ({exc}); skipping daily writes", flush=True)
        return
    for date, d in backend_data["by_day"].items():
        by_shape_out = {}
        for shape, b in d["by_shape"].items():
            c = b["count"]
            by_shape_out[shape] = {
                "count": c,
                "duration_ms_total": b["duration_ms_total"],
                "duration_ms_avg": b["duration_ms_total"] // c if c else 0,
                "queue_ms_total": b.get("queue_ms_total", 0),
                "queue_ms_avg": b.get("queue_ms_total", 0) // c if c else 0,
            }
        by_gpu_out = {}
        for g_name, g in (d.get("by_gpu") or {}).items():
            c = g["count"]
            by_gpu_out[g_name] = {
                "count": c,
                "duration_ms_total": g["duration_ms_total"],
                "duration_ms_avg": g["duration_ms_total"] // c if c else 0,
                "queue_ms_total": g.get("queue_ms_total", 0),
                "queue_ms_avg": g.get("queue_ms_total", 0) // c if c else 0,
            }
        by_variant_out = {}
        for v_name, v in (d.get("by_variant") or {}).items():
            c = v["count"]
            by_variant_out[v_name] = {
                "count": c,
                "duration_ms_total": v["duration_ms_total"],
                "duration_ms_avg": v["duration_ms_total"] // c if c else 0,
                "queue_ms_total": v.get("queue_ms_total", 0),
                "queue_ms_avg": v.get("queue_ms_total", 0) // c if c else 0,
            }
        ips = d["unique_ips"]
        day_req = d["requests"]
        day_queue_total = d.get("queue_ms_total", 0)
        payload = {
            "date": date,
            "updated_at": int(time.time()),
            "requests": day_req,
            "success": d["success"],
            "errors": d["errors"],
            "queue_ms_total": day_queue_total,
            "queue_ms_avg": day_queue_total // day_req if day_req else 0,
            "unique_users": len(ips) if isinstance(ips, set) else len(list(ips)),
            "by_shape": by_shape_out,
            "by_hour": list(d["by_hour"]),
            "by_gpu": by_gpu_out,
            "by_variant": by_variant_out,
        }
        _atomic_write(os.path.join(DAILY_DIR, f"{date}.json"), payload, indent=2)


def main() -> None:
    print(
        f"[metrics_pusher] backends={BACKEND_URLS} interval={INTERVAL}s "
        f"state_dir={STATE_DIR} persistent_storage={PERSISTENT_STORAGE}",
        flush=True,
    )
    tick = 0
    consecutive_zero = 0
    while True:
        try:
            backend_data = fetch_backend_metrics()
            gpu_data = fetch_gpu_stats()
            # nvidia-smi runs locally and is independent of backend health,
            # so always refresh GPU stats.
            _atomic_write(GPU_PATH, gpu_data)

            if backend_data["replicas_seen"] == 0:
                # NO replicas answered /metrics this tick — usually means
                # they're all saturated. DON'T overwrite analytics.json
                # with zero-everywhere defaults; keep the prior file so
                # the dashboard stays meaningful. Updated_at age will
                # naturally drift to indicate staleness.
                consecutive_zero += 1
                print(
                    f"[metrics_pusher] tick {tick}: no replicas responded "
                    f"(consecutive={consecutive_zero}); keeping prior analytics.json",
                    flush=True,
                )
            else:
                if consecutive_zero > 0:
                    print(f"[metrics_pusher] backends recovered after {consecutive_zero} miss(es)", flush=True)
                consecutive_zero = 0
                analytics = build_analytics(backend_data)
                _atomic_write(ANALYTICS_PATH, analytics)
                if tick % STATE_WRITE_EVERY_N_TICKS == 0:
                    write_state(backend_data)
                    write_daily_archives(backend_data)
        except Exception as exc:
            print(f"[metrics_pusher] tick error: {exc}", flush=True)
        tick += 1
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
