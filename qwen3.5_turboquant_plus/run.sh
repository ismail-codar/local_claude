#!/bin/sh
set -eu

MODEL_PATH="${MODEL_PATH:-../models/Qwen3.5-35B-A3B-Q4_K_M.gguf}"
LLAMA_SERVER="${LLAMA_SERVER:-../llama-cpp-turboquant-cuda/build/bin/llama-server}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8001}"
CONTEXT_SIZE="${CONTEXT_SIZE:-65536}"

PID_FILE="${PID_FILE:-./qwen-server.pid}"
LOG_DIR="${LOG_DIR:-./logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/qwen-server.log}"

mkdir -p "$LOG_DIR"

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
    --cache-type-k turbo4 \
    --cache-type-v turbo4 \
    -np 1 \
    --jinja \
    --metrics \
    --alias "Qwen3.5-35B-A3B-Q4_K_M-64K" \
    -ub 8192 \
    --log-disable \
    >> "$LOG_FILE" 2>&1 &

SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

sleep 1

if kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Qwen server baslatildi."
    echo "PID: $SERVER_PID"
    echo "Log: $LOG_FILE"
else
    echo "Server baslatilamadi."
    rm -f "$PID_FILE"
    exit 1
fi