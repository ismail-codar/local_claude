#!/bin/sh
set -e

echo "=== Qwopus3.5-27B-v3 + TurboQuant (L40S 48GB - aria2c indir + ../models'ten çalıştır) ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LLAMA_DIR="$ROOT_DIR/llama-cpp-turboquant"
MODEL_DIR="$ROOT_DIR/../models"
LOG_FILE="$ROOT_DIR/llama-server.log"

MODEL_URL="https://huggingface.co/mradermacher/Qwopus3.5-27B-v3-i1-GGUF/resolve/main/Qwopus3.5-27B-v3.i1-Q4_K_M.gguf"
MODEL_FILE="$MODEL_DIR/Qwopus3.5-27B-v3.i1-Q4_K_M.gguf"

mkdir -p "$MODEL_DIR"
cd "$LLAMA_DIR"

if [ -f "$MODEL_FILE" ]; then
    echo "✅ Model zaten mevcut: $MODEL_FILE"
else
    echo "⬇️ Model indiriliyor:"
    echo "   $MODEL_URL"

    if command -v aria2c >/dev/null 2>&1; then
        aria2c \
          --dir="$MODEL_DIR" \
          --out="$(basename "$MODEL_FILE")" \
          --continue=true \
          --max-connection-per-server=16 \
          --split=16 \
          --min-split-size=10M \
          --file-allocation=none \
          "$MODEL_URL"
    else
        echo "❌ aria2c bulunamadı. Kur:"
        echo "   Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y aria2"
        exit 1
    fi
fi

echo "TurboQuant KV Cache + 256K Context ile arka planda başlatılıyor..."

: > "$LOG_FILE"

nohup ./build/bin/llama-server \
  -m "$MODEL_FILE" \
  --cache-type-k turbo3 \
  --cache-type-v turbo3 \
  -c 262144 \
  -ngl 99 \
  --flash-attn on \
  --cont-batching \
  -np 4 \
  --host 0.0.0.0 \
  --port 8001 \
  --jinja \
  -t 0 \
  --no-mmap \
  --reasoning-budget 0 \
  > "$LOG_FILE" 2>&1 &

SERVER_PID=$!

echo ""
echo "🚀 llama-server arka planda başlatıldı (PID: $SERVER_PID)"
echo "📝 Log dosyası: $LOG_FILE"
echo "📦 Model dosyası: $MODEL_FILE"
echo "🌐 Web arayüzü: http://$(hostname -I | awk '{print $1}'):8001"
echo ""
echo "Canlı log izlemek için: tail -f \"$LOG_FILE\""
echo "Durdurmak için: kill $SERVER_PID"
echo ""

sleep 1
tail -f "$LOG_FILE" || true