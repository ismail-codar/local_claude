#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PID_FILE="$SCRIPT_DIR/.litellm.pid"
PORT=8010

if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null || true)
else
  PID=""
fi

STOPPED=0

if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
  kill "$PID" 2>/dev/null || true
  STOPPED=1
  sleep 1
fi

PORT_PIDS=$(lsof -t -i :"$PORT" 2>/dev/null || true)

if [ -n "$PORT_PIDS" ]; then
  echo "$PORT_PIDS" | xargs kill 2>/dev/null || true
  STOPPED=1
  sleep 1

  REMAINING=$(lsof -t -i :"$PORT" 2>/dev/null || true)
  if [ -n "$REMAINING" ]; then
    echo "$REMAINING" | xargs kill -9 2>/dev/null || true
  fi
fi

rm -f "$PID_FILE"

if [ "$STOPPED" -eq 1 ]; then
  echo "LiteLLM durduruldu."
else
  echo "Surec zaten calismiyor."
fi