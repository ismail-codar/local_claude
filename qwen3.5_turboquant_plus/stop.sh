#!/bin/sh
set -eu

PID_FILE="${PID_FILE:-./qwen-server.pid}"

if [ ! -f "$PID_FILE" ]; then
    echo "PID dosyasi yok. Server zaten kapali olabilir."
    exit 0
fi

PID="$(cat "$PID_FILE" 2>/dev/null || true)"

if [ -z "${PID:-}" ]; then
    echo "PID dosyasi bos. Temizleniyor."
    rm -f "$PID_FILE"
    exit 0
fi

if ! kill -0 "$PID" 2>/dev/null; then
    echo "Process calismiyor. Eski PID dosyasi siliniyor."
    rm -f "$PID_FILE"
    exit 0
fi

kill "$PID"

for _ in 1 2 3 4 5 6 7 8 9 10; do
    if kill -0 "$PID" 2>/dev/null; then
        sleep 1
    else
        rm -f "$PID_FILE"
        echo "Qwen server durduruldu."
        exit 0
    fi
done

kill -9 "$PID" 2>/dev/null || true
rm -f "$PID_FILE"
echo "Qwen server zorla durduruldu."