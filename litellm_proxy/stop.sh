#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.litellm.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "PID dosyasi bulunamadi. Calisan bir surec olmayabilir."
  exit 1
fi

PID="$(cat "$PID_FILE")"

if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "LiteLLM durduruldu. PID: $PID"
else
  echo "Surec zaten calismiyor. PID: $PID"
fi

rm -f "$PID_FILE"