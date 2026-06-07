#!/bin/sh
# TripoSplat (gradio) server control: start / stop / log / status
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/triposplat.pid"
LOG_FILE="$SCRIPT_DIR/triposplat.log"

# Gradio launch() bu env değişkenlerini okur; app.py'ye dokunmadan kontrol ederiz.
# 0.0.0.0'a (tum arayuzler) bind ediyoruz; ayrica Caddy onunde de calistirilabilir (bkz. caddy-server/Caddyfile).
HOST="${GRADIO_SERVER_NAME:-0.0.0.0}"
PORT="${GRADIO_SERVER_PORT:-8010}"

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
  if is_running; then
    echo "TripoSplat zaten çalışıyor (PID $(cat "$PID_FILE"))."
    exit 0
  fi

  cd "$SCRIPT_DIR" || exit 1

  # Varsa yerel .venv'i aktive et (yoksa sistem python'u kullanılır).
  # uv: Linux/WSL -> .venv/bin, Windows (Git Bash) -> .venv/Scripts
  if [ -f "$SCRIPT_DIR/.venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/.venv/bin/activate"
  elif [ -f "$SCRIPT_DIR/.venv/Scripts/activate" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/.venv/Scripts/activate"
  fi

  echo "TripoSplat başlatılıyor → $HOST:$PORT ..."
  GRADIO_SERVER_NAME="$HOST" \
  GRADIO_SERVER_PORT="$PORT" \
  nohup python app.py > "$LOG_FILE" 2>&1 &

  echo $! > "$PID_FILE"
  echo "Başlatıldı (PID $!). Log: $LOG_FILE"
  echo "Caddy üzerinden erişim: http://localhost:7998/"
}

stop() {
  if ! is_running; then
    echo "TripoSplat çalışmıyor."
    rm -f "$PID_FILE"
    exit 0
  fi

  PID="$(cat "$PID_FILE")"
  echo "TripoSplat durduruluyor (PID $PID)..."
  kill "$PID" 2>/dev/null || true
  # 30s nazik kapanış bekle, sonra zorla
  for _ in $(seq 1 30); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$PID" 2>/dev/null; then
    echo "Zorla kapatılıyor..."
    kill -9 "$PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  echo "Durduruldu."
}

status() {
  if is_running; then
    echo "TripoSplat çalışıyor (PID $(cat "$PID_FILE")) → $HOST:$PORT"
  else
    echo "TripoSplat çalışmıyor."
  fi
}

log() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "Log dosyası yok: $LOG_FILE"
    exit 1
  fi
  tail -n 255 -f "$LOG_FILE"
}

case "$1" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  log)    log ;;
  *)      echo "Kullanım: $0 {start|stop|status|log}"; exit 1 ;;
esac
