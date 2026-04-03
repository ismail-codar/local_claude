#!/usr/bin/env bash

PID_FILE="llama.pid"

if [[ -f "$PID_FILE" ]]; then
    PID="$(cat "$PID_FILE")"

    if ps -p "$PID" > /dev/null 2>&1; then
        echo "Process durduruluyor. PID: $PID"
        kill "$PID"

        for i in {1..10}; do
            if ps -p "$PID" > /dev/null 2>&1; then
                sleep 1
            else
                break
            fi
        done

        if ps -p "$PID" > /dev/null 2>&1; then
            echo "Normal kapatmadi, zorla kapatiliyor. PID: $PID"
            kill -9 "$PID"
        fi

        rm -f "$PID_FILE"
        echo "Durduruldu."
    else
        echo "PID dosyasi var ama process calismiyor. Temizleniyor."
        rm -f "$PID_FILE"
    fi
else
    echo "PID dosyasi bulunamadi. Process aranacak..."

    PIDS="$(pgrep -f 'llama.cpp/llama-cli.*gemma-4-26B-A4B-it-UD-Q6_K.gguf' || true)"

    if [[ -z "$PIDS" ]]; then
        echo "Calisan uygun process bulunamadi."
        exit 1
    fi

    echo "Bulunan PID'ler: $PIDS"
    kill $PIDS
    echo "Durduruldu."
fi