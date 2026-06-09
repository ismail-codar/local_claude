#!/bin/bash
# Bonsai-Image HF Space entrypoint.
#
# Boot order:
#   1. Download the ternary gemlite model (~3.5 GB) — idempotent.
#   2. Generate /tmp/.htpasswd from $DASHBOARD_KEY for the basic-auth gate.
#   3. Build /tmp/nginx-upstream.conf from `nvidia-smi -L`. One server line
#      per GPU. At N=1 the upstream has one entry; at N>1 we prepend
#      `least_conn;` for variable-duration request routing.
#   4. Spawn one `uvicorn space.app:app` per GPU on consecutive ports
#      (CUDA_VISIBLE_DEVICES pinned). Each worker's lifespan warms the
#      shapes listed in BONSAI_WARMUP_SHAPES.
#   5. Wait for the first worker to be ready, then `next start` on :3000
#      (internal — nginx will expose it on :7860).
#   6. Start metrics_pusher sidecar with a watchdog.
#   7. Exec nginx on :7860 (the one public port HF sees).
#
# Env (HF Space secrets):
#   (no HF_TOKEN needed — model repos are public; any token in env is scrubbed)
#   DASHBOARD_KEY         basic-auth password for /dash-<obfuscated>
#   BONSAI_WARMUP_SHAPES  default "512x512,1024x1024,1248x832"
set -euo pipefail

APP_DIR="${HOME:-/home/user}/app"
cd "$APP_DIR"

export PATH="$APP_DIR/.venv/bin:$PATH"
export HF_HUB_ENABLE_HF_TRANSFER=1

# ── reap orphaned workers from a prior crashed boot ──────────────────────────
# HF can restart this entrypoint inside the SAME container. The processes we
# launch with `&` (uvicorn × N, next, metrics_pusher) and the exec'd nginx are
# NOT torn down when a previous run crashes mid-boot — they survive as orphans
# still holding :8000-800N, :3000, and :7860. The next boot then dies on every
# bind with EADDRINUSE. SIGKILL any leftovers up front so the ports are free.
# On a fresh container these patterns match nothing; `|| true` keeps `set -e`
# happy. (None match this entrypoint's own cmdline, so there's no self-kill.)
echo "==>  reaping any stale processes from a prior boot ..."
pkill -9 -f "uvicorn space.app:app" 2>/dev/null || true
pkill -9 -f "metrics_pusher.py"     2>/dev/null || true
pkill -9 -f "next start"            2>/dev/null || true
pkill -9 -f "next-server"           2>/dev/null || true
pkill -9 -x "nginx"                 2>/dev/null || true
sleep 1

# ── GPU detection (early — needed for cache namespacing + tier-aware warmup) ─
# nvidia-smi might not return data in some odd container states; treat as
# "unknown" rather than crashing so the rest of the boot can still run.
#
# IMPORTANT: take the first line with `awk 'NR==1'`, NOT `head -1`. On a
# multi-GPU box nvidia-smi emits one line per GPU; `head -1` closes the pipe
# after the first line, nvidia-smi gets SIGPIPE writing line 2, and with
# `set -o pipefail` + `set -e` that 141 kills the whole entrypoint. `awk`
# reads to EOF so the writer never sees a closed pipe. (Single-GPU boxes
# only emit one line, which is why this only bit multi-GPU launches.)
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | awk 'NR==1' | xargs)
GPU_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | awk 'NR==1' | tr -d '.')
[ -z "$GPU_NAME" ] && GPU_NAME="unknown"
[ -z "$GPU_CAP" ]  && GPU_CAP="00"
echo "[OK]  GPU: $GPU_NAME (sm_${GPU_CAP})"

# Slow GPUs (T4, older Tesla cards): warm only the two square presets we
# benchmark against (512² and 1024²) and extend the readiness deadline.
# Skipping warmup entirely would shift the multi-minute first-call JIT
# onto the first user request, which corrupts benchmark numbers — better
# to bake it into boot. BONSAI_WARMUP_SHAPES + BACKEND_READY_TIMEOUT can
# be overridden via Space Variables if you want different shapes or a
# longer/shorter deadline.
case "$GPU_NAME" in
    *T4*|*P100*|*V100*|*K80*|*M60*)
        echo "[WARN] $GPU_NAME is slow — warming only 512x512 + 1024x1024."
        echo "       Extending readiness timeout to 30 min for the longer JIT."
        : "${BONSAI_WARMUP_SHAPES:=512x512,1024x1024}"
        : "${BACKEND_READY_TIMEOUT:=1800}"
        export BONSAI_WARMUP_SHAPES BACKEND_READY_TIMEOUT
        ;;
esac

# ── persistent storage detection ─────────────────────────────────────────────
# Try to use /data (a Storage Bucket if mounted) for the model + kernel
# caches + stats. Every filesystem op is wrapped so that if anything fails
# midway — bucket detached mid-build, mkdir denied, symlink races — we
# silently fall back to ephemeral storage and keep going. The dashboard
# banner alerts the user via BONSAI_PERSISTENT_STORAGE.
_setup_persistent() {
    [ -d /data ] && [ -w /data ] || return 1

    # Kernel caches namespaced by compute capability so a tier swap (e.g.
    # L40S sm_89 → T4 sm_75 → back to L40S) doesn't pollute either GPU's
    # autotune configs / Triton kernels.
    _gemlite_dir="/data/cache/gemlite-sm${GPU_CAP}"
    _triton_dir="/data/cache/triton-sm${GPU_CAP}"

    # One-shot migration: if a non-namespaced cache exists from older
    # builds, move it under the current GPU's namespace so we don't lose
    # the pre-existing autotune work.
    if [ -d /data/cache/gemlite ] && [ ! -e "$_gemlite_dir" ]; then
        echo "[INFO] migrating /data/cache/gemlite → gemlite-sm${GPU_CAP}"
        mv /data/cache/gemlite "$_gemlite_dir" 2>/dev/null || true
    fi
    if [ -d /data/cache/triton ] && [ ! -e "$_triton_dir" ]; then
        echo "[INFO] migrating /data/cache/triton → triton-sm${GPU_CAP}"
        mv /data/cache/triton "$_triton_dir" 2>/dev/null || true
    fi

    mkdir -p /data/models "$_gemlite_dir" "$_triton_dir" /data/state /data/state/daily 2>/dev/null || return 1
    rm -rf "$APP_DIR/models" 2>/dev/null || return 1
    ln -s /data/models "$APP_DIR/models" 2>/dev/null || return 1
    mkdir -p "$APP_DIR/outputs" 2>/dev/null || return 1
    rm -rf "$APP_DIR/outputs/.gemlite_cache" "$APP_DIR/outputs/.triton_cache" 2>/dev/null || true
    ln -s "$_gemlite_dir" "$APP_DIR/outputs/.gemlite_cache" 2>/dev/null || return 1
    ln -s "$_triton_dir"  "$APP_DIR/outputs/.triton_cache"  2>/dev/null || return 1
    return 0
}

if _setup_persistent; then
    echo "[OK]  /data Storage Bucket attached — model + caches + counters will persist"
    export BONSAI_STATE_DIR=/data/state
    export BONSAI_PERSISTENT_STORAGE=1
else
    if [ -d /data ]; then
        echo "[WARN] /data is present but couldn't be set up (read-only? quota?). Falling back to ephemeral."
    else
        echo "[WARN] /data not mounted — model, kernel caches, and dashboard"
        echo "       counters will reset on every Space restart. Enable a"
        echo "       Storage Bucket in Space Settings → Storage to fix."
    fi
    export BONSAI_STATE_DIR="$APP_DIR/outputs/.state"
    export BONSAI_PERSISTENT_STORAGE=0
    mkdir -p "$BONSAI_STATE_DIR/daily" 2>/dev/null || true
fi

# ── shared IP-hash pepper across all replicas ────────────────────────────────
# Every replica must hash IPs with the same pepper so unique-user counts
# don't double across replicas. Extract from state.json if present (so the
# pepper survives restarts), else generate a fresh one. Each worker reads
# this via env, regardless of whether it loads cumulative state.
if [ -f "$BONSAI_STATE_DIR/state.json" ]; then
    BONSAI_IP_PEPPER=$(python3 - "$BONSAI_STATE_DIR/state.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("ip_pepper") or "")
except Exception:
    pass
PY
)
fi
if [ -z "${BONSAI_IP_PEPPER:-}" ]; then
    BONSAI_IP_PEPPER=$(python3 -c "import secrets; print(secrets.token_hex(16))")
fi
export BONSAI_IP_PEPPER
# Warm only the two square presets users hit most often (512² and 1024²).
# Other resolutions JIT on first user request and join the on-disk caches
# (/data/cache/{gemlite,triton}-smXX/) organically. The warmup-skip sentinel
# (warmup-done.json next to gemlite autotune) tracks completed (backend,shape)
# pairs across boots, so subsequent boots skip even these two if they're
# already cached.
#
# Why so few shapes: multi-GPU boots collide during warmup — all N workers
# race for /data bandwidth + CPU during the gemlite layer pack, and we've
# seen 4-worker launches hang past BACKEND_READY_TIMEOUT. Two shapes covers
# the common case (most users render at 512² or 1024²) without inflating
# cold-boot wall time.
: "${BONSAI_WARMUP_SHAPES:=512x512,1024x1024}"
export BONSAI_WARMUP_SHAPES

# Binary warmup disabled by default. When enabled, every replica swaps to
# the binary transformer simultaneously after primary warmup — 4 parallel
# 3.5 GB state_dict reads from /data + 4 parallel gemlite layer packs.
# We've seen this hang multi-GPU boots indefinitely. First binary-arm click
# pays a one-time JIT cost (~30s for an unwarmed shape, after which the
# cache covers it forever).
#
# To re-enable on single-GPU rigs where the collision doesn't apply:
#   set Space Variable BONSAI_WARMUP_EXTRA_BACKENDS=bonsai-binary-gemlite
: "${BONSAI_WARMUP_EXTRA_BACKENDS:=}"
export BONSAI_WARMUP_EXTRA_BACKENDS

# Restrict the studio picker to ternary only. With both variants exposed +
# nginx least_conn routing, mixed traffic makes each replica thrash its
# resident transformer (ternary↔binary, ~1s per swap on warm cache). A
# single-variant picker eliminates that — no binary requests, no swaps.
#
# This ONLY controls what the picker offers. Binary weights are still
# downloaded and wired below, so binary stays fully servable via a direct API
# call and re-exposing it in the UI is a one-liner: set this Space Variable to
# "bonsai-ternary,bonsai-binary" (or unset it for the default both). Keeping
# download/wiring independent of picker visibility is deliberate — when the two
# were tied together, hiding binary left its transformer path unset and every
# worker crashed on boot.
: "${BONSAI_SUPPORTED_FAMILIES:=bonsai-ternary}"
export BONSAI_SUPPORTED_FAMILIES

# ── token handling ───────────────────────────────────────────────────────────
# The model repos are PUBLIC now, so no token is needed — download_model.sh
# calls snapshot_download with no `token=` arg. huggingface_hub still AUTO-READS
# HF_TOKEN / HUGGING_FACE_HUB_TOKEN from the environment and sends it on every
# request, and a stale/revoked token there makes the Hub return 401 even on
# public repos (which crashed the boot). So we scrub any token from the env and
# always download anonymously.
echo "[INFO] model repos are public — downloading anonymously (any HF token in env is ignored)"
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN HUGGINGFACEHUB_API_TOKEN BONSAI_TOKEN 2>/dev/null || true

# ── model download / sync ────────────────────────────────────────────────────
# Download BOTH ternary + binary, regardless of which the picker exposes. Each
# repo is ~3.5 GB; first cold boot pulls ~7 GB total, but the Storage Bucket
# (/data/models, symlinked above) keeps them across restarts so later boots
# just etag-check. Shipping binary even while the UI hides it keeps it a
# flip-the-variable away from servable, and guarantees its transformer path
# resolves so GpuPipeline construction can't fail — the picker restriction
# lives entirely in the /backends override, never here.
#
# We *always* invoke download_model.sh on boot (no file-exists guard). Under
# the hood it calls huggingface_hub.snapshot_download with `local_dir` set,
# which HEADs each file in the repo and skips any whose etag matches what's
# already on disk — so cached boots cost ~10-30s of metadata checks instead
# of a full redownload. The upside: pushing new weights to HF auto-propagates
# on the next Space restart without a force flag or manual cache wipe.
MODEL_DIR="$APP_DIR/models/bonsai-image-4B-ternary-gemlite"
BINARY_MODEL_DIR="$APP_DIR/models/bonsai-image-4B-binary-gemlite"
echo "==>  syncing bonsai-image-ternary-4B-gemlite-2bit ..."
./scripts/download_model.sh --model ternary-gemlite
echo "==>  syncing bonsai-image-binary-4B-gemlite-1bit ..."
./scripts/download_model.sh --model binary-gemlite

# ── htpasswd for the dashboard ───────────────────────────────────────────────
# DASHBOARD_KEY is a Space Secret; fall back to a sentinel that prints a
# big warning so missing-secret is obvious in the build log but the Space
# still comes up (useful while iterating).
if [ -n "${DASHBOARD_KEY:-}" ]; then
    HASH=$(openssl passwd -apr1 "$DASHBOARD_KEY")
    printf 'admin:%s\n' "$HASH" > /tmp/.htpasswd
    echo "[OK]  dashboard: auth enabled (user=admin)"
else
    echo "[WARN] DASHBOARD_KEY not set — /dash-... is open with admin:open"
    printf 'admin:$apr1$open$open\n' > /tmp/.htpasswd
fi

# ── nginx scratch dirs ───────────────────────────────────────────────────────
mkdir -p /tmp/nginx-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi

# ── pre-seed dashboard JSON so the page doesn't 502 before first scrape ──────
printf '{"updated_at":null,"persistent_storage":%s,"summary_total":{"requests":0,"success":0,"errors":0},"summary_today":{"requests":0,"unique_users":0},"summary_7d":{"requests":0,"unique_users":0},"by_shape":{},"requests_by_hour":[],"requests_by_day":[],"recent":[]}\n' \
    "$([ "${BONSAI_PERSISTENT_STORAGE:-0}" = "1" ] && echo true || echo false)" \
    > /tmp/analytics.json
echo '{"ts":null,"gpus":[]}' > /tmp/gpu-stats.json

# ── pin model paths once; shared across all workers ──────────────────────────
# backend_gpu/pipeline_gpu.py reads SEPARATE env vars per variant
# (TERNARY_TRANSFORMER_PATH vs BINARY_TRANSFORMER_PATH) and the packed
# transformer subdir name differs per variant (transformer-gemlite-int2
# for ternary, transformer-gemlite-int1 for binary). Glob each variant's
# dir for whichever transformer-gemlite-* it actually ships and assign to
# the right env var. Without the BINARY env var set, the pipeline falls
# back to its hardcoded /root/models/bonsai-binary/ default → PermissionError
# on a non-root container the moment a user picks binary in the UI.
#
# Note: text_encoder + vae + tokenizer are the SAME artifacts across both
# variants (Qwen3-4B-4bit + BFL VAE). Pointing them at the ternary copy
# is fine; binary's copy of these files sits idle on disk after download.
# That's a one-time ~1 GB of duplication on disk for the simplicity of
# letting download_model.sh pull the standard HF layout for each repo.
export MFLUX_STUDIO_GPU_DEFAULT_BACKEND="bonsai-ternary-gemlite"
# `awk 'NR==1'` not `head -1` — same SIGPIPE-under-pipefail reasoning as the
# nvidia-smi calls above: if a model dir ever has >1 transformer-gemlite-*
# match, head closes the pipe early and ls dies 141, killing the script.
_ternary_transformer_dir=$(ls -d "$MODEL_DIR"/transformer-gemlite-* 2>/dev/null | awk 'NR==1')
if [ -z "$_ternary_transformer_dir" ]; then
    echo "[ERR] no transformer-gemlite-* subdir under $MODEL_DIR" >&2
    exit 1
fi
export MFLUX_STUDIO_GPU_TERNARY_TRANSFORMER_PATH="$_ternary_transformer_dir"
# Wire the binary transformer too. GpuPipeline.__init__ validates EVERY
# backend's path up front (binary AND ternary) even though it loads only the
# default one lazily — so this must resolve or every worker dies on boot with
# "binary transformer path is unset". We always download binary above, so the
# glob always finds the real -int1 dir; the picker just hides it from users.
_binary_transformer_dir=$(ls -d "$BINARY_MODEL_DIR"/transformer-gemlite-* 2>/dev/null | awk 'NR==1')
if [ -z "$_binary_transformer_dir" ]; then
    echo "[ERR] no transformer-gemlite-* subdir under $BINARY_MODEL_DIR" >&2
    exit 1
fi
export MFLUX_STUDIO_GPU_BINARY_TRANSFORMER_PATH="$_binary_transformer_dir"
export MFLUX_STUDIO_GPU_TEXT_ENCODER_PATH="$MODEL_DIR/text_encoder-hqq-4bit"
export MFLUX_STUDIO_GPU_VAE_PATH="$MODEL_DIR/vae"
export MFLUX_STUDIO_GPU_TOKENIZER_PATH="$MODEL_DIR/text_encoder-hqq-4bit/tokenizer"

# ── detect GPUs + spawn one uvicorn per device ───────────────────────────────
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l || echo 1)
[ "$GPU_COUNT" -lt 1 ] && GPU_COUNT=1
echo "[OK]  detected $GPU_COUNT GPU(s)"

# Stagger consecutive worker starts. Without this, all N uvicorns hit the
# /data bucket simultaneously, contending for ~5 GB state_dict reads + the
# CPU-bound fp16 cast + gemlite layer conversion. We've seen 4-worker
# launches blow through BACKEND_READY_TIMEOUT this way. Staggering by ~30s
# (a hair more than the single-worker transformer-load wall time observed
# on warm bucket / sm_86) lets each worker get past torch.load + gemlite
# convert before the next starts touching the same files.
WORKER_START_STAGGER_SECONDS="${BONSAI_WORKER_START_STAGGER_SECONDS:-30}"

BACKEND_URLS=""
UPSTREAM_SERVERS=""
for i in $(seq 0 $((GPU_COUNT - 1))); do
    PORT=$((8000 + i))
    # Per-replica GPU name (mixed-GPU rigs are rare but possible — look it
    # up by physical index rather than reuse the top-level GPU_NAME).
    REPLICA_GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader -i "$i" 2>/dev/null | awk 'NR==1' | xargs)
    [ -z "$REPLICA_GPU" ] && REPLICA_GPU="$GPU_NAME"
    echo "==>  starting backend on GPU $i ($REPLICA_GPU) → :$PORT  (warmup: $BONSAI_WARMUP_SHAPES)"
    # BONSAI_REPLICA_INDEX: only replica 0 seeds counters from state.json;
    # replicas 1+ start at 0 and report deltas. metrics_pusher sums them →
    # correct cumulative without N-way inflation.
    # BONSAI_GPU_NAME: surfaced via /metrics so the pusher can aggregate
    # request counts/latencies per GPU model for the dashboard.
    CUDA_VISIBLE_DEVICES=$i BONSAI_REPLICA_INDEX=$i BONSAI_GPU_NAME="$REPLICA_GPU" \
    uvicorn space.app:app \
        --host 127.0.0.1 --port "$PORT" \
        --no-access-log &
    UPSTREAM_SERVERS="${UPSTREAM_SERVERS}    server 127.0.0.1:$PORT;"$'\n'
    [ -n "$BACKEND_URLS" ] && BACKEND_URLS="$BACKEND_URLS,"
    BACKEND_URLS="${BACKEND_URLS}http://127.0.0.1:$PORT"
    # Sleep between consecutive worker starts (skip after the last one).
    # Set BONSAI_WORKER_START_STAGGER_SECONDS=0 to disable if cold-boot
    # wall time matters more than first-boot reliability.
    if [ "$i" -lt "$((GPU_COUNT - 1))" ] && [ "$WORKER_START_STAGGER_SECONDS" -gt 0 ]; then
        echo "  ↳ sleeping ${WORKER_START_STAGGER_SECONDS}s before next worker (avoid /data + CPU contention)"
        sleep "$WORKER_START_STAGGER_SECONDS"
    fi
done

# At N>1 use least_conn (variable-duration requests — see space/nginx.conf).
if [ "$GPU_COUNT" -gt 1 ]; then
    LB_DIRECTIVE="    least_conn;"$'\n'
else
    LB_DIRECTIVE=""
fi
printf 'upstream bonsai_workers {\n%s%s}\n' "$LB_DIRECTIVE" "$UPSTREAM_SERVERS" > /tmp/nginx-upstream.conf
export BACKEND_URLS

# ── wait for backend readiness ───────────────────────────────────────────────
# Workers only answer /backends after lifespan finishes (kernels compiled +
# warmup shapes JITed). We poll the first one as a proxy for "ready enough."
_ready_timeout="${BACKEND_READY_TIMEOUT:-600}"
echo "==>  waiting for backend on :8000 (up to ${_ready_timeout}s) ..."
for i in $(seq 1 "$_ready_timeout"); do
    if curl -fsS -m 2 http://127.0.0.1:8000/backends > /dev/null 2>&1; then
        echo "[OK]  backend ready after ${i}s"
        break
    fi
    sleep 1
    if [ "$i" -eq "$_ready_timeout" ]; then
        echo "[ERR] backend did not come up within ${_ready_timeout}s" >&2
        exit 1
    fi
done

# ── frontend (next start) on internal :3000 ──────────────────────────────────
echo "==>  starting frontend (next start) on :3000"
(cd vendor/image-studio/frontend && exec npm start -- --port 3000 --hostname 127.0.0.1) &

# ── metrics_pusher sidecar (watchdog restart on crash) ───────────────────────
start_metrics_pusher() {
    while true; do
        echo "[watchdog] starting metrics_pusher.py"
        python3 /home/user/app/space/metrics_pusher.py || true
        echo "[watchdog] metrics_pusher.py exited, restarting in 5s"
        sleep 5
    done
}
start_metrics_pusher &

# ── nginx — front everything on :7860 (the HF-exposed port) ──────────────────
echo "==>  nginx on :7860"
exec nginx -c /home/user/app/space/nginx.conf -p /home/user/app/
