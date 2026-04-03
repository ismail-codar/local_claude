#!/usr/bin/env bash
set -e

WORKDIR="${HOME}/mnn-gguf-run"
MODEL_DIR="$1"
PROMPT="${2:-Merhaba}"

BUILD_DIR="${WORKDIR}/MNN/build"

########################################
# Find binary
########################################
LLM_DEMO=$(find "$BUILD_DIR" -name "llm_demo" -type f | head -n 1)

if [[ -z "$LLM_DEMO" ]]; then
  echo "llm_demo bulunamadı"
  exit 1
fi

########################################
# Run (background)
########################################
echo "[INFO] Model çalışıyor..."

"$LLM_DEMO" "$MODEL_DIR" "$PROMPT" &
PID=$!

echo $PID > "${WORKDIR}/app.pid"

echo "[OK] PID: $PID"