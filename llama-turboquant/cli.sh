#!/bin/sh
# llama.cpp + TurboQuant + Qwen3.6 MTP server control: start / stop / log
set -e

echo "=== Local LLM + TurboQuant + Qwen3.6 MTP (NVIDIA L40S 48GB) ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# Komut + opsiyonel --env parametresini ayristir.
# Kullanim:
#   ./cli.sh start
#   ./cli.sh start --env /path/to/.env
#   ./cli.sh --env=/path/to/.env start
#   ENV_FILE=/path/.env ./cli.sh start   (env degiskeni ile de olur)
CMD=""
ENV_FILE="${ENV_FILE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --env|-e)   ENV_FILE="$2"; shift 2 ;;
    --env=*)    ENV_FILE="${1#--env=}"; shift ;;
    start|stop|log|clearlog) CMD="$1"; shift ;;
    *)          echo "Bilinmeyen parametre: $1"; echo "Usage: $0 {start|stop|log|clearlog} [--env /path/to/.env]"; exit 1 ;;
  esac
done

# Dizin varsayilanlari .env'den ONCE seed ediliyor; boylece .env icinde
# MODEL_FILE="$MODEL_DIR/foo.gguf" gibi referanslar calisir. .env yine de
# bu degiskenleri override edebilir (sourcing seed'in uzerine yazar).
LLAMA_DIR="${LLAMA_DIR:-$ROOT_DIR/llama-cpp-turboquant}"
MODEL_DIR="${MODEL_DIR:-$ROOT_DIR/../models}"
LOG_FILE="${LOG_FILE:-$ROOT_DIR/llama-server.log}"
PID_FILE="${PID_FILE:-$ROOT_DIR/llama-server.pid}"

# .env yukle (varsa). Parametre/env verilmezse SCRIPT_DIR/.env denenir.
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  echo "Ayarlar yukleniyor: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8001}"

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

MODEL_URL="${MODEL_URL:-https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"
# Not: Unsloth, MTP'li ve MTP'siz repolarda ayni dosya adini kullaniyor.
# Cakismayi onlemek icin yerel adi acikca "-MTP-" ile isaretliyoruz.
MODEL_FILE="${MODEL_FILE:-$MODEL_DIR/Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL.gguf}"

# Multimodal (vision) destegi - opsiyonel.
# 1 = mmproj indir ve --mmproj ile baslat (text + vision)
# 0 = sadece text (varsayilan, en hizli)
# Not: Qwen3.6-35B-A3B-MTP-GGUF repo'sunda mmproj birlikte yayinlaniyor.
ENABLE_MMPROJ="${ENABLE_MMPROJ:-1}"
MMPROJ_URL="${MMPROJ_URL:-https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/mmproj-F16.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-$MODEL_DIR/mmproj-F16.gguf}"

# 48GB L40S icin baslangic ayarlari
CTX_SIZE="${CTX_SIZE:-262144}"
PARALLEL_SLOTS="${PARALLEL_SLOTS:-1}"
GPU_LAYERS="${GPU_LAYERS:-99}"
BATCH_SIZE="${BATCH_SIZE:-1024}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"
THREADS="${THREADS:-0}"

# MTP (speculative decoding):
# 1 = ac (sadece MTP draft katmani olan modellerde, orn. Qwen3.6 MTP)
# 0 = kapat (MTP'siz modeller icin, orn. LFM2.5-8B-A1B)
ENABLE_MTP="${ENABLE_MTP:-1}"
# Resmi llama.cpp guncel ad: draft-mtp
# Bazi TurboQuant fork'lari eski ad olan mtp kullanir.
SPEC_DRAFT_N_MAX="${SPEC_DRAFT_N_MAX:-6}"

# KV cache:
# turbo4 daha kaliteli; 48GB L40S icin uygun.
# Daha fazla bos VRAM / hiz denemesi icin K turbo3, V turbo4 denenebilir.
CACHE_TYPE_K="${CACHE_TYPE_K:-turbo4}"
CACHE_TYPE_V="${CACHE_TYPE_V:-turbo4}"

# Reasoning aktif mi (thinking on/off/auto):
#   auto = chat template'den otomatik tespit (varsayilan llama.cpp davranisi)
#   on   = thinking'i ZORLA ac -> <think> bloklari reasoning olarak ayristirilir
#   off  = thinking kapali
# LFM2.5 gibi template'i standart "enable_thinking" yerine "preserve_thinking"
# kullanan modellerde auto tespiti basarisiz olur (log'da thinking = 0) ve
# <think> etiketleri reasoning_content'e AYRISTIRILAMAZ; ham metin olarak gorunur.
# Bu durumda REASONING=on yap. Bos birakirsan --reasoning hic gecilmez.
REASONING="${REASONING:-}"

# Reasoning butcesi (modelin destekledigi durumda):
# 0 = reasoning kapali/daha hizli, 4096 = dengeli, 8192 = uzun, -1 = sinirsiz
# Bos birakirsan --reasoning-budget hic gecilmez.
REASONING_BUDGET="${REASONING_BUDGET:-4096}"

# Reasoning ayristirma formati:
# <think>...</think> bloklarinin nasil islenecegini belirler.
#   auto     = chat template'e gore otomatik (varsayilan llama.cpp davranisi)
#   deepseek = <think> icerigi reasoning_content'e ayrilir -> Web UI'de
#              katlanabilir "thinking" bolumu, normal cevaptan ayri gosterilir
#   none     = ayristirma yok, <think> etiketleri icerikte DUZ METIN kalir
# Web UI'de ham <think> goruyorsan deepseek kullan.
# Bos birakirsan --reasoning-format hic gecilmez (llama.cpp varsayilani).
REASONING_FORMAT="${REASONING_FORMAT:-deepseek}"

# Sampling varsayilanlari (sunucu varsayilani; istek bunlari override edebilir).
# Bos birakilanlar llama-server'a hic gecilmez (llama.cpp varsayilani kullanilir).
TEMP="${TEMP:-}"
TOP_K="${TOP_K:-}"
TOP_P="${TOP_P:-}"
MIN_P="${MIN_P:-}"
REPEAT_PENALTY="${REPEAT_PENALTY:-}"

# llama-ui (SvelteKit tabanli yeni Web UI, llama.cpp varsayilan olarak acik):
# https://github.com/ggml-org/llama.cpp/discussions/16938
# 1 = acik (varsayilan), 0 = --no-webui ile kapat
ENABLE_WEBUI="${ENABLE_WEBUI:-1}"

# Disa acik (0.0.0.0) calistirildigi icin opsiyonel API anahtari.
# Bos birakirsan --api-key gecilmez.
API_KEY="${API_KEY:-}"

# UI'in slot/istek metriklerini gormesi icin /slots endpoint'i.
# 1 = --slots ekle, 0 = ekleme.
ENABLE_SLOTS="${ENABLE_SLOTS:-1}"

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

start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "llama-server zaten calisiyor (PID $(cat "$PID_FILE"))"
    exit 0
  fi

  mkdir -p "$MODEL_DIR"
  cd "$LLAMA_DIR"

  echo "Model:"
  echo "   $MODEL_URL"
  echo "Dosya:"
  echo "   $MODEL_FILE"

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

  SPEC_TYPE=""
  if [ "$ENABLE_MTP" = "1" ]; then
    # llama.cpp 13 Mayis 2026 civari --spec-type mtp adini draft-mtp olarak degistirdi.
    # Fork eski adla derlenmis olabilir; otomatik sec.
    if ./build/bin/llama-server --help 2>&1 | grep -q "draft-mtp"; then
      SPEC_TYPE="draft-mtp"
    elif ./build/bin/llama-server --help 2>&1 | grep -q "mtp"; then
      SPEC_TYPE="mtp"
    else
      echo "Bu llama-server build'i MTP spec decoding desteklemiyor gibi gorunuyor."
      echo "MTP + TurboQuant destekli fork/build kullandigindan emin ol."
      echo "MTP'siz model kullaniyorsan .env icinde ENABLE_MTP=0 yap."
      exit 1
    fi
    echo "Secilen spec-type: $SPEC_TYPE"
    echo "TurboQuant KV Cache + Context $CTX_SIZE + MTP ile baslatiliyor..."
  else
    echo "MTP kapali (ENABLE_MTP=0)."
    echo "TurboQuant KV Cache + Context $CTX_SIZE ile baslatiliyor..."
  fi

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
  if [ -n "$SPEC_TYPE" ]; then
    set -- "$@" --spec-type "$SPEC_TYPE" --spec-draft-n-max "$SPEC_DRAFT_N_MAX"
  fi
  if [ -n "$REASONING" ]; then
    # --reasoning on/off/auto: thinking'i template tespitinden bagimsiz zorlar.
    # Eski fork'larda bu bayrak olmayabilir; --help ile dogrula.
    if ./build/bin/llama-server --help 2>&1 | grep -q -- "--reasoning "; then
      set -- "$@" --reasoning "$REASONING"
      echo "Reasoning (thinking): $REASONING (zorlandi)"
    else
      echo "UYARI: Bu build --reasoning bayragini desteklemiyor; REASONING=$REASONING atlandi."
      echo "       <think> ayristirma icin guncel llama.cpp/fork gerekebilir."
    fi
  fi
  if [ -n "$REASONING_BUDGET" ]; then
    set -- "$@" --reasoning-budget "$REASONING_BUDGET"
  fi
  if [ -n "$REASONING_FORMAT" ]; then
    set -- "$@" --reasoning-format "$REASONING_FORMAT"
  fi
  if [ -n "$TEMP" ]; then
    set -- "$@" --temp "$TEMP"
  fi
  if [ -n "$TOP_K" ]; then
    set -- "$@" --top-k "$TOP_K"
  fi
  if [ -n "$TOP_P" ]; then
    set -- "$@" --top-p "$TOP_P"
  fi
  if [ -n "$MIN_P" ]; then
    set -- "$@" --min-p "$MIN_P"
  fi
  if [ -n "$REPEAT_PENALTY" ]; then
    set -- "$@" --repeat-penalty "$REPEAT_PENALTY"
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
    -t "$THREADS" \
    --batch-size "$BATCH_SIZE" \
    --ubatch-size "$UBATCH_SIZE" \
    --cache-type-k "$CACHE_TYPE_K" \
    --cache-type-v "$CACHE_TYPE_V" \
    --no-mmap \
    "$@" \
    > "$LOG_FILE" 2>&1 &

  SERVER_PID=$!
  echo "$SERVER_PID" > "$PID_FILE"

  echo ""
  echo "llama-server arka planda baslatildi (PID: $SERVER_PID)"
  echo "Log dosyasi: $LOG_FILE"
  echo "Model dosyasi: $MODEL_FILE"
  echo "Context: $CTX_SIZE"
  echo "Parallel slots: $PARALLEL_SLOTS"
  if [ -n "$SPEC_TYPE" ]; then
    echo "MTP: $SPEC_TYPE, draft-n-max=$SPEC_DRAFT_N_MAX"
  else
    echo "MTP: kapali"
  fi
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
}

stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "Calismiyor (PID dosyasi yok)"
    exit 0
  fi

  PID="$(cat "$PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "llama-server durduruluyor (PID $PID)..."
    kill "$PID"
    # graceful shutdown icin 30s'ye kadar bekle, sonra zorla
    for _ in $(seq 1 30); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo "Zorla durduruluyor..."
      kill -9 "$PID" 2>/dev/null || true
    fi
    echo "Durduruldu"
  else
    echo "Surec $PID canli degil; temizleniyor"
  fi
  rm -f "$PID_FILE"
}

log() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "Log dosyasi yok: $LOG_FILE"
    exit 1
  fi
  tail -n 255 -f "$LOG_FILE"
}

clearlog() {
  if [ ! -f "$LOG_FILE" ]; then
    echo "Log dosyasi yok: $LOG_FILE"
    exit 0
  fi
  : > "$LOG_FILE"
  echo "Log temizlendi: $LOG_FILE"
}

case "$CMD" in
  start)    start ;;
  stop)     stop ;;
  log)      log ;;
  clearlog) clearlog ;;
  *)        echo "Usage: $0 {start|stop|log|clearlog} [--env /path/to/.env]"; exit 1 ;;
esac
