#!/bin/sh
set -e 
echo "=== Local LLM + TurboQuant (L40S 48GB - aria2c indir + models'ten çalıştır) ==="
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LLAMA_DIR="$ROOT_DIR/llama.cpp"
MODEL_DIR="$ROOT_DIR/../models"
LOG_FILE="$ROOT_DIR/llama-server.log"
 
MODEL_URL="https://huggingface.co/Jiunsong/supergemma4-26b-abliterated-multimodal-gguf-4bit/resolve/main/supergemma4-26b-abliterated-multimodal-Q4_K_M.gguf"
MODEL_FILE="$MODEL_DIR/supergemma4-26b-abliterated-multimodal-Q4_K_M.gguf"

MMPROJ_URL="https://huggingface.co/Jiunsong/supergemma4-26b-abliterated-multimodal-gguf-4bit/resolve/main/mmproj-supergemma4-26b-abliterated-multimodal-f16.gguf"
MMPROJ_FILE="$MODEL_DIR/mmproj-supergemma4-26b-abliterated-multimodal-f16.gguf"

mkdir -p "$MODEL_DIR"
cd "$LLAMA_DIR"

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

echo "⬇️ mmproj indiriliyor:"
echo "   $MMPROJ_URL"
aria2c \
    --dir="$MODEL_DIR" \
    --out="$(basename "$MMPROJ_FILE")" \
    --continue=true \
    --max-connection-per-server=16 \
    --split=16 \
    --min-split-size=10M \
    --file-allocation=none \
    "$MMPROJ_URL"

echo "TurboQuant KV Cache + 256K Context + Multimodal ile arka planda başlatılıyor..."
: > "$LOG_FILE"

nohup ./build/bin/llama-server \
  -m "$MODEL_FILE" \
  --mmproj "$MMPROJ_FILE" \
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
  --reasoning-budget 4096 \
  >/dev/null 2>&1 &

SERVER_PID=$!
echo ""
echo "🚀 llama-server arka planda başlatıldı (PID: $SERVER_PID)"
echo "📝 Log dosyası: $LOG_FILE"
echo "📦 Model dosyası: $MODEL_FILE"
echo "🖼️ mmproj dosyası: $MMPROJ_FILE"
echo "🌐 Web arayüzü: http://$(hostname -I | awk '{print $1}'):8001"
echo ""
echo "Durdurmak için: ./stop.sh"