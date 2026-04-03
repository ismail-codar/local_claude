#!/bin/bash
echo "=== llama-server durduruluyor... ==="

# Önce nazikçe durdur (SIGTERM)
pkill -TERM -f "llama-server" || true
sleep 2

# Hala varsa zorla öldür
pkill -KILL -f "llama-server" || true

echo "✅ Tüm llama-server süreçleri durduruldu."