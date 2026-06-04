#!/bin/sh
# vLLM server control: start / stop / log
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/vllm-27b.pid"
LOG_FILE="$SCRIPT_DIR/vllm-27b.log"

MODEL="Qwen/Qwen3.6-27B-FP8"
DRAFT_MODEL="z-lab/Qwen3.6-27B-DFlash"
PORT="8000"

start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "vLLM already running (PID $(cat "$PID_FILE"))"
    exit 0
  fi

  echo "Starting vLLM ($MODEL) on port $PORT..."
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../.venv/bin/activate"
  # Reduce CUDA fragmentation (frees the "reserved but unallocated" memory)
  export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
  nohup vllm serve "$MODEL" \
    --speculative-config '{"method": "dflash", "model": "'"$DRAFT_MODEL"'", "num_speculative_tokens": 15}' \
    --attention-backend flash_attn \
    --gpu-memory-utilization 0.95 \
    --max-model-len 8192 \
    --max-num-batched-tokens 8192 \
    --port "$PORT" \
    > "$LOG_FILE" 2>&1 &

  echo $! > "$PID_FILE"
  echo "Started (PID $!). Logs: $LOG_FILE"
}

stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "Not running (no PID file)"
    exit 0
  fi

  PID="$(cat "$PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "Stopping vLLM (PID $PID)..."
    kill "$PID"
    # wait up to 30s for graceful shutdown, then force
    for _ in $(seq 1 30); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo "Force killing..."
      kill -9 "$PID" 2>/dev/null || true
    fi
    echo "Stopped"
  else
    echo "Process $PID not alive; cleaning up"
  fi
  rm -f "$PID_FILE"
}

log() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "No log file at $LOG_FILE"
    exit 1
  fi
  tail -n 255 -f "$LOG_FILE"
}

case "$1" in
  start) start ;;
  stop)  stop ;;
  log)   log ;;
  *)     echo "Usage: $0 {start|stop|log}"; exit 1 ;;
esac
