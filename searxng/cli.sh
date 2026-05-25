#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/searxng-mcp.pid"
LOG_FILE="$SCRIPT_DIR/searxng-mcp.log"

start_service() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Already running (PID: $(cat "$PID_FILE"))"
        return 1
    fi
    nohup env SEARXNG_URL=http://127.0.0.1:8002 npx -y mcp-proxy --port 3333 --host 0.0.0.0 -- npx -y mcp-searxng > "$LOG_FILE" 2>&1 &
    PID=$!
    echo "$PID" > "$PID_FILE"
    echo "Started (PID: $PID), log: $LOG_FILE"
}

stop_service() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Not running"
        return 1
    fi
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        pkill -P "$PID" 2>/dev/null
        kill "$PID" 2>/dev/null
        sleep 1
        kill -9 "$PID" 2>/dev/null
        rm -f "$PID_FILE"
        echo "Stopped (PID: $PID)"
    else
        rm -f "$PID_FILE"
        echo "Not running (stale PID file removed)"
    fi
}

show_log() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "No log file found at $LOG_FILE"
        return 1
    fi
    tail -f "$LOG_FILE"
}

case "$1" in
    --start)
        start_service
        ;;
    --stop)
        stop_service
        ;;
    --log)
        show_log
        ;;
    *)
        echo "Usage: $0 {--start|--stop|--log}"
        exit 1
        ;;
esac
