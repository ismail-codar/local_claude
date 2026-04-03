#!/bin/sh
set -eu

LLAMA_SERVER="../llama.cpp/llama-cli"
MODEL_PATH="../models/gemma-4-26B-A4B-it-UD-Q6_K.gguf"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8001}"
CONTEXT_SIZE="${CONTEXT_SIZE:-65536}"

PID_FILE="${PID_FILE:-./llama.pid}"
LOG_DIR="${LOG_DIR:-./logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/llama.log}"

mkdir -p "$LOG_DIR"

if [ -f "$LLAMA_SERVER" ]; then
    echo "LLAMA_SERVER bulundu: $LLAMA_SERVER"
else
    echo "LLAMA_SERVER bulunamadi: $LLAMA_SERVER"
fi

if [ -f "$MODEL_PATH" ]; then
    echo "MODEL_PATH bulundu: $MODEL_PATH"
else
    echo "MODEL_PATH bulunamadi: $MODEL_PATH"
fi

if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${OLD_PID:-}" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Server zaten calisiyor. PID: $OLD_PID"
        exit 1
    else
        rm -f "$PID_FILE"
    fi
fi

nohup "$LLAMA_SERVER" \
    -m "$MODEL_PATH" \
    --host "$HOST" \
    --port "$PORT" \
    -c "$CONTEXT_SIZE" \
    -ngl 99 \
    -fa on \
    -np 1 \
    --jinja \
    --metrics \
    --alias "gemma-4-26B-A4B-it-UD-Q6_K" \
    --temp 1.0 \
    --top-p 0.95 \
    --top-k 64 \
    --log-disable \
    >> "$LOG_FILE" 2>&1 &

SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

sleep 1

if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Gemma server baslatildi."
    echo "PID: $SERVER_PID"
    echo "Host: $HOST"
    echo "Port: $PORT"
    echo "Log: $LOG_FILE"
else
    echo "Server baslatilamadi."
    rm -f "$PID_FILE"
    exit 1
fi