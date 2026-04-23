#!/usr/bin/env sh
set -eu

echo "=== Local LLM + Chrome DevTools MCP için Qwen3.6-35B-A3B + Multimodal Başlatıcı ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LLAMA_DIR="$ROOT_DIR/llama-cpp-turboquant"
MODEL_DIR="$ROOT_DIR/../models"
LOG_FILE="$ROOT_DIR/llama-server.log"

# LLM server
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8001}"

# Model seçimi: Qwen3.6 multimodal
MODEL_URL="${MODEL_URL:-https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"
MODEL_FILE="${MODEL_FILE:-$MODEL_DIR/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"

# En dengeli projector seçimi
MMPROJ_URL="${MMPROJ_URL:-https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/mmproj-F16.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-$MODEL_DIR/mmproj-F16.gguf}"

# llama.cpp ayarları
CTX_SIZE="${CTX_SIZE:-262144}"
NGL="${NGL:-99}"
REASONING_BUDGET="${REASONING_BUDGET:-4096}"
BATCH_SIZE="${BATCH_SIZE:-512}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"
PARALLEL="${PARALLEL:-2}"
THREADS="${THREADS:-0}"

mkdir -p "$MODEL_DIR"

if [ ! -d "$LLAMA_DIR" ]; then
    echo "❌ llama-cpp-turboquant dizini bulunamadı: $LLAMA_DIR"
    exit 1
fi

if [ ! -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    echo "❌ llama-server bulunamadı veya çalıştırılabilir değil:"
    echo "   $LLAMA_DIR/build/bin/llama-server"
    echo "   Önce llama.cpp/turboquant derlemesini tamamla."
    exit 1
fi

download_with_aria2c() {
    URL="$1"
    OUT_FILE="$2"

    echo "⬇️ İndiriliyor:"
    echo "   $URL"

    aria2c \
        --dir="$MODEL_DIR" \
        --out="$OUT_FILE" \
        --continue=true \
        --max-connection-per-server=16 \
        --split=16 \
        --min-split-size=10M \
        --file-allocation=none \
        "$URL"
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "❌ Gerekli komut bulunamadı: $1"
        exit 1
    fi
}

need_cmd aria2c
need_cmd awk
need_cmd hostname

download_with_aria2c "$MODEL_URL" "$(basename "$MODEL_FILE")"
download_with_aria2c "$MMPROJ_URL" "$(basename "$MMPROJ_FILE")"

cd "$LLAMA_DIR"

echo "🧹 Eski log temizleniyor..."
: > "$LOG_FILE"

echo "🚀 llama-server başlatılıyor..."
nohup ./build/bin/llama-server \
  -m "$MODEL_FILE" \
  --mmproj "$MMPROJ_FILE" \
  --cache-type-k turbo3 \
  --cache-type-v turbo3 \
  -c "$CTX_SIZE" \
  -ngl "$NGL" \
  --flash-attn on \
  --cont-batching \
  -np "$PARALLEL" \
  --host "$HOST" \
  --port "$PORT" \
  --jinja \
  -t "$THREADS" \
  --reasoning-budget "$REASONING_BUDGET" \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size "$UBATCH_SIZE" \
  >"$LOG_FILE" 2>&1 &

SERVER_PID=$!

sleep 2

if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -z "${IP_ADDR:-}" ]; then
        IP_ADDR="127.0.0.1"
    fi

    echo ""
    echo "✅ llama-server arka planda başlatıldı"
    echo "   PID          : $SERVER_PID"
    echo "   Log          : $LOG_FILE"
    echo "   Model        : $MODEL_FILE"
    echo "   MMPROJ       : $MMPROJ_FILE"
    echo "   API Base URL : http://$IP_ADDR:$PORT"
    echo "   Health/UI    : http://$IP_ADDR:$PORT"
    echo ""

    echo "=== chrome-devtools-mcp notları ==="
    echo "chrome-devtools-mcp ayrı bir MCP server'dır; bu script onu başlatmaz."
    echo "MCP istemcinde aşağıdakine benzer şekilde tanımlanır:"
    echo ""
    cat <<EOF
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest"]
    }
  }
}
EOF
    echo ""

    echo "Chrome zaten uzaktan debug açık ve çalışıyorsa, MCP'yi mevcut browser'a bağlayabilirsin:"
    echo ""
    cat <<EOF
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "-y",
        "chrome-devtools-mcp@latest",
        "--browserUrl",
        "http://127.0.0.1:9222"
      ]
    }
  }
}
EOF
    echo ""

    echo "OpenAI uyumlu istemci/ajan için genelde şu endpoint kullanılır:"
    echo "   base_url = http://127.0.0.1:$PORT/v1"
    echo "   model    = $(basename "$MODEL_FILE")"
    echo ""
    echo "Örnek env:"
    echo "   export OPENAI_BASE_URL=http://127.0.0.1:$PORT/v1"
    echo "   export OPENAI_API_KEY=dummy"
    echo ""
    echo "Durdurmak için:"
    echo "   kill $SERVER_PID"
    echo "veya ayrı bir stop.sh kullan."
else
    echo "❌ llama-server başlatılamadı."
    echo "Son loglar:"
    tail -n 50 "$LOG_FILE" || true
    exit 1
fi