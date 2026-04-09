#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
PID_FILE="$SCRIPT_DIR/.litellm.pid"
LOG_FILE="$SCRIPT_DIR/litellm.log"

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
else
  echo "Hata: .env dosyasi bulunamadi: $ENV_FILE" >&2
  exit 1
fi

: "${HELICONE_API_KEY:?HELICONE_API_KEY tanimli degil}"

if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  if [ -n "${OLD_PID:-}" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "LiteLLM zaten calisiyor. PID: $OLD_PID"
    exit 1
  else
    rm -f "$PID_FILE"
  fi
fi

cd "$SCRIPT_DIR"

: > "$LOG_FILE"

PYTHONUNBUFFERED=1 LITELLM_LOG=DEBUG \
nohup uv run litellm --config config.yaml --port 8010 --detailed_debug \
>> "$LOG_FILE" 2>&1 &

PID=$!
echo "$PID" > "$PID_FILE"
sleep 1

if kill -0 "$PID" 2>/dev/null; then
  echo "LiteLLM baslatildi. PID: $PID | Log: $LOG_FILE"
else
  echo "LiteLLM baslatilamadi. Log kontrol et: $LOG_FILE" >&2
  rm -f "$PID_FILE"
  exit 1
fi