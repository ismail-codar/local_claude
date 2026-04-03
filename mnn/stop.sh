#!/usr/bin/env bash

WORKDIR="${HOME}/mnn-gguf-run"
PID_FILE="${WORKDIR}/app.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "PID dosyası yok"
  exit 1
fi

PID=$(cat "$PID_FILE")

if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "[OK] Durduruldu: $PID"
else
  echo "Process zaten çalışmıyor"
fi

rm -f "$PID_FILE"