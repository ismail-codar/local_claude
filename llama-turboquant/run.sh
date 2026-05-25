#!/bin/sh
set -e

echo "=== Local LLM + TurboQuant + Qwen3.6 MTP (NVIDIA L40S 48GB) ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LLAMA_DIR="$ROOT_DIR/llama-cpp-turboquant"
MODEL_DIR="$ROOT_DIR/../models"
LOG_FILE="$ROOT_DIR/llama-server.log"

HOST="0.0.0.0"
PORT="8001"

# L40S 48GB icin onerilen:
# - UD-Q5_K_XL: kalite/VRAM dengesi iyi, 27.2 GB
# - 256K context + TurboQuant KV cache
# - MTP/speculative decoding aktif
#
# Daha hizli / daha serin alternatif:
#   Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
#
# Daha kaliteli ama VRAM daha sikisik:
#   Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf

MODEL_URL="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
# Not: Unsloth, MTP'li ve MTP'siz repolarda ayni dosya adini kullaniyor.
# Cakismayi onlemek icin yerel adi acikca "-MTP-" ile isaretliyoruz.
MODEL_FILE="$MODEL_DIR/Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL.gguf"

# Multimodal (vision) destegi - opsiyonel.
# 1 = mmproj indir ve --mmproj ile baslat (text + vision)
# 0 = sadece text (varsayilan, en hizli)
# Not: Qwen3.6-35B-A3B-MTP-GGUF repo'sunda mmproj birlikte yayinlaniyor.
ENABLE_MMPROJ=1
MMPROJ_URL="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/mmproj-F16.gguf"
MMPROJ_FILE="$MODEL_DIR/mmproj-F16.gguf"

# 48GB L40S icin baslangic ayarlari
CTX_SIZE=262144
PARALLEL_SLOTS=1
GPU_LAYERS=99
BATCH_SIZE=1024
UBATCH_SIZE=512
THREADS=0

# MTP:
# Resmi llama.cpp guncel ad: draft-mtp
# Bazi TurboQuant fork'lari eski ad olan mtp kullanir.
SPEC_DRAFT_N_MAX=6

# KV cache:
# turbo4 daha kaliteli; 48GB L40S icin uygun.
# Daha fazla bos VRAM / hiz denemesi icin K turbo3, V turbo4 denenebilir.
CACHE_TYPE_K="turbo4"
CACHE_TYPE_V="turbo4"

# Qwen reasoning butcesi:
# 0 = reasoning kapali/daha hizli
# 4096 = dengeli
# 8192 = uzun dusunme icin
REASONING_BUDGET=4096

# llama-ui (SvelteKit tabanli yeni Web UI, llama.cpp varsayilan olarak acik):
# https://github.com/ggml-org/llama.cpp/discussions/16938
# 1 = acik (varsayilan), 0 = --no-webui ile kapat
ENABLE_WEBUI=1

# Disa acik (0.0.0.0) calistirildigi icin opsiyonel API anahtari.
# Bos birakirsan --api-key gecilmez.
API_KEY=""

# UI'in slot/istek metriklerini gormesi icin /slots endpoint'i.
# 1 = --slots ekle, 0 = ekleme.
ENABLE_SLOTS=1

mkdir -p "$MODEL_DIR"
cd "$LLAMA_DIR"

echo "Model:"
echo "   $MODEL_URL"
echo "Dosya:"
echo "   $MODEL_FILE"

download_with_aria2c() {
    _url="$1"
    _out="$2"
    if ! command -v aria2c >/dev/null 2>&1; then
        echo "aria2c bulunamadi. Kur:"
        echo "   Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y aria2"
        exit 1
    fi
    aria2c \
        --dir="$MODEL_DIR" \
        --out="$_out" \
        --continue=true \
        --max-connection-per-server=16 \
        --split=16 \
        --min-split-size=10M \
        --file-allocation=none \
        "$_url"
}

if [ ! -f "$MODEL_FILE" ]; then
    echo "Model indiriliyor..."
    download_with_aria2c "$MODEL_URL" "$(basename "$MODEL_FILE")"
else
    echo "Model zaten var, indirme atlandi."
fi

if [ "$ENABLE_MMPROJ" = "1" ]; then
    if [ ! -f "$MMPROJ_FILE" ]; then
        echo "mmproj indiriliyor:"
        echo "   $MMPROJ_URL"
        download_with_aria2c "$MMPROJ_URL" "$(basename "$MMPROJ_FILE")"
    else
        echo "mmproj zaten var, indirme atlandi."
    fi
fi

if [ ! -x ./build/bin/llama-server ]; then
    echo "llama-server bulunamadi veya executable degil:"
    echo "   ./build/bin/llama-server"
    exit 1
fi

# llama.cpp 13 Mayis 2026 civari --spec-type mtp adini draft-mtp olarak degistirdi.
# Fork eski adla derlenmis olabilir; otomatik sec.
if ./build/bin/llama-server --help 2>&1 | grep -q "draft-mtp"; then
    SPEC_TYPE="draft-mtp"
elif ./build/bin/llama-server --help 2>&1 | grep -q "mtp"; then
    SPEC_TYPE="mtp"
else
    echo "Bu llama-server build'i MTP spec decoding desteklemiyor gibi gorunuyor."
    echo "MTP + TurboQuant destekli fork/build kullandigindan emin ol."
    exit 1
fi

echo "Secilen spec-type: $SPEC_TYPE"
echo "TurboQuant KV Cache + 256K Context + MTP ile baslatiliyor..."

: > "$LOG_FILE"

# Opsiyonel bayraklar (dizi yerine konumsal parametrelerle, POSIX sh uyumlu)
set --
if [ "$ENABLE_WEBUI" = "0" ]; then
    set -- "$@" --no-webui
fi
if [ "$ENABLE_SLOTS" = "1" ]; then
    set -- "$@" --slots
fi
if [ -n "$API_KEY" ]; then
    set -- "$@" --api-key "$API_KEY"
fi
if [ "$ENABLE_MMPROJ" = "1" ]; then
    set -- "$@" --mmproj "$MMPROJ_FILE"
fi

nohup ./build/bin/llama-server \
  -m "$MODEL_FILE" \
  -ngl "$GPU_LAYERS" \
  -c "$CTX_SIZE" \
  --flash-attn on \
  --cont-batching \
  -np "$PARALLEL_SLOTS" \
  --host "$HOST" \
  --port "$PORT" \
  --jinja \
  --chat-template-file chat_template.jinja \
  -t "$THREADS" \
  --batch-size "$BATCH_SIZE" \
  --ubatch-size "$UBATCH_SIZE" \
  --cache-type-k "$CACHE_TYPE_K" \
  --cache-type-v "$CACHE_TYPE_V" \
  --spec-type "$SPEC_TYPE" \
  --spec-draft-n-max "$SPEC_DRAFT_N_MAX" \
  --reasoning-budget "$REASONING_BUDGET" \
  --no-mmap \
  "$@" \
  > "$LOG_FILE" 2>&1 &

SERVER_PID=$!

echo ""
echo "llama-server arka planda baslatildi (PID: $SERVER_PID)"
echo "Log dosyasi: $LOG_FILE"
echo "Model dosyasi: $MODEL_FILE"
echo "Context: $CTX_SIZE"
echo "Parallel slots: $PARALLEL_SLOTS"
echo "MTP: $SPEC_TYPE, draft-n-max=$SPEC_DRAFT_N_MAX"
echo "KV cache: K=$CACHE_TYPE_K, V=$CACHE_TYPE_V"
if [ "$ENABLE_MMPROJ" = "1" ]; then
    echo "Multimodal: aktif (mmproj=$MMPROJ_FILE)"
else
    echo "Multimodal: kapali (ENABLE_MMPROJ=1 ile ac)"
fi
if [ "$ENABLE_WEBUI" = "0" ]; then
    echo "Web UI (llama-ui): KAPALI (--no-webui)"
else
    echo "Web UI (llama-ui): http://$(hostname -I | awk '{print $1}'):$PORT"
fi
if [ -n "$API_KEY" ]; then
    echo "API key korumasi: aktif (Authorization: Bearer <API_KEY>)"
fi
echo ""
echo "Log takip:"
echo "   tail -f $LOG_FILE"
echo ""
echo "Durdurmak icin: ./stop.sh"