#!/usr/bin/env bash
set -euo pipefail
set -a

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PID_FILE="$SCRIPT_DIR/.litellm.pid"

if [ -f "$ENV_FILE" ]; then
  . "$ENV_FILE"
else
  echo "Hata: .env dosyasi bulunamadi: $ENV_FILE"
  exit 1
fi

set +a

: "${LANGFUSE_SECRET_KEY:?LANGFUSE_SECRET_KEY tanimli degil}"
: "${LANGFUSE_PUBLIC_KEY:?LANGFUSE_PUBLIC_KEY tanimli degil}"
: "${LANGFUSE_BASE_URL:?LANGFUSE_BASE_URL tanimli degil}"

if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE")"
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "LiteLLM zaten calisiyor. PID: $OLD_PID"
    exit 1
  else
    rm -f "$PID_FILE"
  fi
fi

cd "$SCRIPT_DIR"

uv run litellm --config config.yaml --port 8010 &
PID=$!

echo "$PID" > "$PID_FILE"
echo "LiteLLM baslatildi. PID: $PID"

wait "$PID"