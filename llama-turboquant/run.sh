#!/bin/sh
set -e

echo "=== Local LLM + TurboQuant (L40S 48GB - aria2c indir + models'ten çalıştır) ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LLAMA_DIR="$ROOT_DIR/llama-cpp-turboquant"
MODEL_DIR="$ROOT_DIR/../models"
LOG_FILE="$ROOT_DIR/llama-server.log"

# TODO https://github.com/ggml-org/llama.cpp/blob/master/models/templates/google-gemma-4-31B-it-interleaved.jinja

# 115 token/saniye
# MODEL_URL="https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf"
# MODEL_FILE="$MODEL_DIR/gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf"

# 125 token/saniye
# MODEL_URL="https://huggingface.co/mudler/gemma-4-26B-A4B-it-APEX-GGUF/resolve/main/gemma-4-26B-A4B-APEX-Quality.gguf"
# MODEL_FILE="$MODEL_DIR/gemma-4-26B-A4B-APEX-Quality.gguf"

# 35 token/saniye
# MODEL_URL="https://huggingface.co/Jackrong/Qwopus3.5-27B-v3-GGUF/resolve/main/Qwopus3.5-27B-v3-Q4_K_M.gguf"
# MODEL_FILE="$MODEL_DIR/Qwopus3.5-27B-v3-Q4_K_M.gguf"

# 105 token/saniye
# MODEL_URL="https://huggingface.co/Jackrong/Gemopus-4-26B-A4B-it-GGUF/resolve/main/Gemopus-4-26B-A4B-it-Preview-Q8_0.gguf"
# MODEL_FILE="$MODEL_DIR/Gemopus-4-26B-A4B-it-Preview-Q8_0.gguf"

# 122 token/saniye
# MODEL_URL="https://huggingface.co/Jiunsong/supergemma4-26b-uncensored-gguf-v2/resolve/main/supergemma4-26b-uncensored-fast-v2-Q4_K_M.gguf"
# MODEL_FILE="$MODEL_DIR/supergemma4-26b-uncensored-fast-v2-Q4_K_M.gguf"

# 138 token/saniye
MODEL_URL="https://huggingface.co/ClankLabs/Wrench-35B-A3B-Q4_K_M-GGUF/resolve/main/Wrench-35B-A3B-Q4_K_M-GGUF.gguf"
MODEL_FILE="$MODEL_DIR/Wrench-35B-A3B-Q4_K_M-GGUF.gguf"

# 122 token/saniye
MODEL_URL="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
MODEL_FILE="$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"


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

echo "TurboQuant KV Cache + 256K Context ile arka planda başlatılıyor..."

: > "$LOG_FILE"

# nohup ./build/bin/llama-server \
#   -m "$MODEL_FILE" \
#   --cache-type-k turbo3 \
#   --cache-type-v turbo3 \
#   -c 262144 \
#   -ngl 99 \
#   --flash-attn on \
#   --cont-batching \
#   -np 4 \
#   --host 0.0.0.0 \
#   --port 8001 \
#   --jinja \
#   -t 0 \
#   --no-mmap \
#   --reasoning-budget 0 \
#   > "$LOG_FILE" 2>&1 &

# nohup ./build/bin/llama-server \
#   -m "$MODEL_FILE" \
#   --cache-type-k turbo3 \
#   --cache-type-v turbo3 \
#   -c 262144 \
#   -ngl 99 \
#   --flash-attn on \
#   --cont-batching \
#   -np 4 \
#   --host 0.0.0.0 \
#   --port 8001 \
#   --jinja \
#   -t 0 \
#   --no-mmap \
#   --reasoning-budget 4096 \
#   >/dev/null 2>&1 &

nohup ./build/bin/llama-server \
  -m "$MODEL_FILE" \
  --cache-type-k turbo3 \
  --cache-type-v turbo3 \
  -c 262144 \
  -ngl 99 \
  --flash-attn on \
  --cont-batching \
  -np 2 \
  --host 0.0.0.0 \
  --port 8001 \
  --jinja \
  -t 0 \
  --reasoning-budget 16384 \
  --batch-size 512 \
  --ubatch-size 512 \
  >/dev/null 2>&1 &

SERVER_PID=$!

echo ""
echo "🚀 llama-server arka planda başlatıldı (PID: $SERVER_PID)"
echo "📝 Log dosyası: $LOG_FILE"
echo "📦 Model dosyası: $MODEL_FILE"
echo "🌐 Web arayüzü: http://$(hostname -I | awk '{print $1}'):8001"
echo ""
echo "Durdurmak için: ./stop.sh"