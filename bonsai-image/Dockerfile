# syntax=docker/dockerfile:1.6
# CUDA 12.8 runtime — gemlite/Triton kernels JIT against the runtime ptxas
# that comes with this image; no need for the larger -devel variant.
FROM nvidia/cuda:12.8.0-runtime-ubuntu22.04

# ── system deps ──────────────────────────────────────────────────────────────
# build-essential is needed because some sdists (gemlite among them) compile C
# extensions at install time. python3 is the host interpreter that bootstraps
# uv; uv then provisions its own pinned interpreter for the venv. nginx fronts
# everything on :7860 (frontend, backend API, dashboard). procps gives us pkill,
# which entrypoint.sh uses to reap orphaned workers from a prior crashed boot.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git build-essential python3 python3-venv \
        libgomp1 libssl3 nginx openssl procps \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R 1000:1000 /var/lib/nginx /var/log/nginx /run

# Non-root user: HF Spaces convention is uid 1000.
RUN useradd -m -u 1000 user
USER user
ENV HOME=/home/user PATH="/home/user/.local/bin:$PATH"

# uv (Python venv + package manager). The demo's setup.sh assumes it's on PATH.
RUN curl -fsSL https://astral.sh/uv/install.sh | sh

WORKDIR /home/user/app

# ── clone + run setup.sh in one RUN so GH_TOKEN never lands in a layer ───────
# GH_TOKEN is supplied by `--mount=type=secret`; the secret file is only
# visible during this single RUN and is not stored in the image.
# SKIP_DOWNLOAD=1 keeps setup.sh from pulling the 3.5 GB model at build time
# — entrypoint.sh handles that at boot so a Space restart doesn't have to
# rebuild the image.
RUN --mount=type=secret,id=GH_TOKEN,uid=1000,required=true \
    git config --global credential.helper '!f() { echo "username=oauth2"; echo "password=$(cat /run/secrets/GH_TOKEN)"; }; f' \
    && git clone https://github.com/PrismML-Eng/Bonsai-image-demo.git . \
    && SKIP_DOWNLOAD=1 BONSAI_PACKAGE_MIN_AGE_DAYS=0 ./setup.sh \
    && git config --global --unset credential.helper

# ── pre-build the Next.js frontend ───────────────────────────────────────────
# Baking the build into the image so the first browser visit doesn't pay
# `npm install + next build` (~2 min) on top of model load. NEXT_PUBLIC_*
# vars are inlined at build time and don't change at runtime, so the
# backend URL (always loopback inside this container) is baked too.
#
# NEXT_PUBLIC_BACKEND_URL points at NGINX (:7860), NOT a single backend
# replica (:8000). The studio's /api/generate route proxies to
# `${NEXT_PUBLIC_BACKEND_URL}/generate`; sending that to :8000 pins ALL UI
# traffic to replica 0 and bypasses nginx's least_conn upstream entirely
# (only direct /generate + /backends calls were getting balanced). Routing
# through :7860 hits the `location ~ ^/(generate|...)` block, which
# load-balances across every replica (8000..800N). The extra loopback hop
# (next → nginx → backend) is ~1ms.
#
# Demo-only patch: strip the "Batch of 4" mode from the studio's mode picker.
# On a shared GPU under launch load, one batch click ties up a generation
# slot for 4× as long. We do this with a `sed` on the cloned source (NOT in
# the image-studio repo) so the upstream stays untouched. The `! grep` guard
# fails the build loudly if upstream renames the option and the sed misses —
# otherwise batch would silently come back on the next rebuild.
RUN cd vendor/image-studio/frontend \
    && sed -i '/{ value: "batch", label: "Batch of 4" },/d' components/studio-client.tsx \
    && ! grep -q 'Batch of 4' components/studio-client.tsx \
    && echo "[patch] removed Batch-of-4 mode from studio UI" \
    && PATH="$HOME/app/.venv/bin:$PATH" \
       NEXT_PUBLIC_BACKEND_URL=http://127.0.0.1:7860 \
       npm install --no-audit --no-fund \
    && PATH="$HOME/app/.venv/bin:$PATH" \
       NEXT_PUBLIC_BACKEND_URL=http://127.0.0.1:7860 \
       npm run build

# ── Space-local files ────────────────────────────────────────────────────────
# All Space-specific code lives under space/ (Python package + sidecar +
# dashboard + nginx config + entrypoint). The demo's own code stays at the
# repo root (cloned earlier) so the two namespaces don't collide.
COPY --chown=user space/ /home/user/app/space/
RUN chmod +x /home/user/app/space/entrypoint.sh

EXPOSE 7860

CMD ["/home/user/app/space/entrypoint.sh"]
