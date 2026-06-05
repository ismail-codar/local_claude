#!/bin/sh
# llama.cpp / beellama.cpp server control: start / stop / log / clearlog / install
set -e

echo "=== Local LLM + TurboQuant / DFlash / MTP server ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# Komut + opsiyonel --env parametresini ayristir.
# Kullanim:
#   ./cli.sh start
#   ./cli.sh start --env /path/to/.env
#   ./cli.sh --env /path/to/.env start
#   ./cli.sh --env=/path/to/.env start
#   ENV_FILE=/path/.env ./cli.sh start

CMD=""
ENV_FILE="${ENV_FILE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --env|-e)
      ENV_FILE="$2"
      shift 2
      ;;
    --env=*)
      ENV_FILE="${1#--env=}"
      shift
      ;;
    start|stop|log|clearlog|install)
      CMD="$1"
      shift
      ;;
    *)
      echo "Bilinmeyen parametre: $1"
      echo "Usage: $0 {start|stop|log|clearlog|install} [--env /path/to/.env]"
      exit 1
      ;;
  esac
done

# Dizin varsayilanlari .env'den ONCE seed ediliyor.
# Boylece .env icinde MODEL_FILE="$MODEL_DIR/foo.gguf" gibi referanslar calisir.
LLAMA_DIR="${LLAMA_DIR:-$ROOT_DIR/llama-cpp-turboquant}"
MODEL_DIR="${MODEL_DIR:-$ROOT_DIR/../models}"
LOG_FILE="${LOG_FILE:-$ROOT_DIR/llama-server.log}"
PID_FILE="${PID_FILE:-$ROOT_DIR/llama-server.pid}"

# install komutu icin repo ayarlari env ile override edilebilir.
INSTALL_REPO_URL="${INSTALL_REPO_URL:-https://github.com/TheTom/llama-cpp-turboquant.git}"
INSTALL_BRANCH="${INSTALL_BRANCH:-feature/turboquant-kv-cache}"
CUDA_ARCH="${CUDA_ARCH:-89}"

# .env yukle.
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [ -f "$ENV_FILE" ]; then
  echo "Ayarlar yukleniyor: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# --- Genel varsayilanlar ---
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8001}"

MODEL_URL="${MODEL_URL:-https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"
MODEL_FILE="${MODEL_FILE:-$MODEL_DIR/Qwen3.6-35B-A3B-MTP-UD-Q5_K_XL.gguf}"

ENABLE_MMPROJ="${ENABLE_MMPROJ:-1}"
MMPROJ_URL="${MMPROJ_URL:-https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/mmproj-F16.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-$MODEL_DIR/mmproj-F16.gguf}"

CTX_SIZE="${CTX_SIZE:-262144}"
PARALLEL_SLOTS="${PARALLEL_SLOTS:-1}"
GPU_LAYERS="${GPU_LAYERS:-99}"
BATCH_SIZE="${BATCH_SIZE:-1024}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"
THREADS="${THREADS:-0}"

# Prompt cache kontrolu.
# Bos birakilirsa llama-server varsayilani kullanilir.
# 0 verilirse --cache-ram 0 ile prompt cache kapatilir.
CACHE_RAM="${CACHE_RAM:-}"

# Speculative decoding secenekleri.
ENABLE_MTP="${ENABLE_MTP:-1}"
ENABLE_DFLASH="${ENABLE_DFLASH:-0}"
SPEC_DRAFT_N_MAX="${SPEC_DRAFT_N_MAX:-6}"

DRAFT_MODEL_URL="${DRAFT_MODEL_URL:-}"
DRAFT_MODEL_FILE="${DRAFT_MODEL_FILE:-}"
SPEC_DRAFT_NGL="${SPEC_DRAFT_NGL:-99}"
SPEC_DFLASH_CROSS_CTX="${SPEC_DFLASH_CROSS_CTX:-1024}"
SPEC_DRAFT_DEVICE="${SPEC_DRAFT_DEVICE:-}"

# KV cache.
CACHE_TYPE_K="${CACHE_TYPE_K:-turbo4}"
CACHE_TYPE_V="${CACHE_TYPE_V:-turbo4}"

# Reasoning.
# Eski surumde bos REASONING_BUDGET 4096'ya donuyordu.
# Bu surumde sadece env/dosyada deger varsa flag gecilir.
REASONING="${REASONING:-}"
REASONING_BUDGET="${REASONING_BUDGET:-}"
REASONING_FORMAT="${REASONING_FORMAT:-}"

# Chat template.
CHAT_TEMPLATE_FILE="${CHAT_TEMPLATE_FILE:-}"

# Sampling.
TEMP="${TEMP:-}"
TOP_K="${TOP_K:-}"
TOP_P="${TOP_P:-}"
MIN_P="${MIN_P:-}"
REPEAT_PENALTY="${REPEAT_PENALTY:-}"

# Web UI / API.
ENABLE_WEBUI="${ENABLE_WEBUI:-1}"
ENABLE_SLOTS="${ENABLE_SLOTS:-1}"
API_KEY="${API_KEY:-}"

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

check_flag_supported() {
  _flag="$1"
  ./build/bin/llama-server --help 2>&1 | grep -q -- "$_flag"
}

start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "llama-server zaten calisiyor (PID $(cat "$PID_FILE"))"
    exit 0
  fi

  mkdir -p "$MODEL_DIR"

  if [ ! -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    echo "HATA: llama-server bulunamadi: $LLAMA_DIR/build/bin/llama-server"
    echo "Once kurulum yapin: $0 --env <env-dosyasi> install"
    exit 1
  fi

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

  if [ "$ENABLE_DFLASH" = "1" ]; then
    if [ -z "$DRAFT_MODEL_FILE" ]; then
      echo "HATA: ENABLE_DFLASH=1 ama DRAFT_MODEL_FILE bos."
      exit 1
    fi

    if [ ! -f "$DRAFT_MODEL_FILE" ]; then
      if [ -z "$DRAFT_MODEL_URL" ]; then
        echo "HATA: DFlash draft modeli yok ve DRAFT_MODEL_URL bos: $DRAFT_MODEL_FILE"
        exit 1
      fi

      echo "DFlash draft modeli indiriliyor:"
      echo "   $DRAFT_MODEL_URL"
      download_with_aria2c "$DRAFT_MODEL_URL" "$(basename "$DRAFT_MODEL_FILE")"
    else
      echo "DFlash draft modeli zaten var, indirme atlandi."
    fi
  fi

  if [ ! -x ./build/bin/llama-server ]; then
    echo "llama-server bulunamadi veya executable degil:"
    echo "   ./build/bin/llama-server"
    exit 1
  fi

  if [ "$ENABLE_MTP" = "1" ] && [ "$ENABLE_DFLASH" = "1" ]; then
    echo "HATA: ENABLE_MTP ve ENABLE_DFLASH ayni anda 1 olamaz; birini secin."
    exit 1
  fi

  SPEC_TYPE=""

  if [ "$ENABLE_DFLASH" = "1" ]; then
    if ! check_flag_supported "--spec-dflash-cross-ctx"; then
      echo "Bu llama-server build'i DFlash spec decoding desteklemiyor gibi gorunuyor."
      echo "DFlash destekli fork/build kullandigindan emin ol: beellama.cpp."
      echo "DFlash'siz model kullaniyorsan .env icinde ENABLE_DFLASH=0 yap."
      exit 1
    fi

    SPEC_TYPE="dflash"
    echo "Secilen spec-type: dflash"
    echo "DFlash + Context $CTX_SIZE ile baslatiliyor..."
  elif [ "$ENABLE_MTP" = "1" ]; then
    if ./build/bin/llama-server --help 2>&1 | grep -q "draft-mtp"; then
      SPEC_TYPE="draft-mtp"
    elif ./build/bin/llama-server --help 2>&1 | grep -q "mtp"; then
      SPEC_TYPE="mtp"
    else
      echo "Bu llama-server build'i MTP spec decoding desteklemiyor gibi gorunuyor."
      echo "MTP'siz model kullaniyorsan .env icinde ENABLE_MTP=0 yap."
      exit 1
    fi

    echo "Secilen spec-type: $SPEC_TYPE"
    echo "Context $CTX_SIZE + MTP ile baslatiliyor..."
  else
    echo "Spec decoding kapali."
    echo "Context $CTX_SIZE ile baslatiliyor..."
  fi

  : > "$LOG_FILE"

  # Opsiyonel bayraklar.
  # POSIX sh uyumu icin dizi yerine set -- kullaniyoruz.
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

  if [ -n "$CACHE_RAM" ]; then
    if check_flag_supported "--cache-ram"; then
      set -- "$@" --cache-ram "$CACHE_RAM"
      echo "Prompt cache RAM: $CACHE_RAM"
    else
      echo "UYARI: Bu build --cache-ram desteklemiyor; CACHE_RAM=$CACHE_RAM atlandi."
    fi
  fi

  if [ "$SPEC_TYPE" = "dflash" ]; then
    set -- "$@" \
      --spec-type dflash \
      --spec-draft-model "$DRAFT_MODEL_FILE" \
      --spec-draft-ngl "$SPEC_DRAFT_NGL" \
      --spec-dflash-cross-ctx "$SPEC_DFLASH_CROSS_CTX"

    if [ -n "$SPEC_DRAFT_DEVICE" ]; then
      if check_flag_supported "--spec-draft-device"; then
        set -- "$@" --spec-draft-device "$SPEC_DRAFT_DEVICE"
      else
        echo "UYARI: Bu build --spec-draft-device desteklemiyor; SPEC_DRAFT_DEVICE=$SPEC_DRAFT_DEVICE atlandi."
      fi
    fi
  elif [ -n "$SPEC_TYPE" ]; then
    set -- "$@" \
      --spec-type "$SPEC_TYPE" \
      --spec-draft-n-max "$SPEC_DRAFT_N_MAX"
  fi

  if [ -n "$REASONING" ]; then
    if check_flag_supported "--reasoning "; then
      set -- "$@" --reasoning "$REASONING"
      echo "Reasoning: $REASONING"
    else
      echo "UYARI: Bu build --reasoning bayragini desteklemiyor; REASONING=$REASONING atlandi."
    fi
  fi

  if [ -n "$REASONING_BUDGET" ]; then
    if check_flag_supported "--reasoning-budget"; then
      set -- "$@" --reasoning-budget "$REASONING_BUDGET"
      echo "Reasoning budget: $REASONING_BUDGET"
    else
      echo "UYARI: Bu build --reasoning-budget desteklemiyor; REASONING_BUDGET=$REASONING_BUDGET atlandi."
    fi
  fi

  if [ -n "$REASONING_FORMAT" ]; then
    if check_flag_supported "--reasoning-format"; then
      set -- "$@" --reasoning-format "$REASONING_FORMAT"
      echo "Reasoning format: $REASONING_FORMAT"
    else
      echo "UYARI: Bu build --reasoning-format desteklemiyor; REASONING_FORMAT=$REASONING_FORMAT atlandi."
    fi
  fi

  if [ -n "$CHAT_TEMPLATE_FILE" ]; then
    if [ ! -f "$CHAT_TEMPLATE_FILE" ]; then
      echo "Chat template dosyasi bulunamadi: $CHAT_TEMPLATE_FILE"
      exit 1
    fi

    set -- "$@" --chat-template-file "$CHAT_TEMPLATE_FILE"
    echo "Ozel chat template: $CHAT_TEMPLATE_FILE"
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

  echo ""
  echo "llama-server baslatiliyor..."
  echo "Binary: ./build/bin/llama-server"
  echo "Log: $LOG_FILE"
  echo ""

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
  echo "Batch: $BATCH_SIZE"
  echo "UBatch: $UBATCH_SIZE"
  echo "KV cache: K=$CACHE_TYPE_K, V=$CACHE_TYPE_V"

  if [ -n "$CACHE_RAM" ]; then
    echo "Prompt cache RAM: $CACHE_RAM"
  else
    echo "Prompt cache RAM: llama-server varsayilani"
  fi

  if [ "$SPEC_TYPE" = "dflash" ]; then
    echo "Spec decoding: DFlash"
    echo "Draft model: $DRAFT_MODEL_FILE"
    echo "Draft NGL: $SPEC_DRAFT_NGL"
    echo "DFlash cross-ctx: $SPEC_DFLASH_CROSS_CTX"
    if [ -n "$SPEC_DRAFT_DEVICE" ]; then
      echo "Draft device: $SPEC_DRAFT_DEVICE"
    fi
  elif [ -n "$SPEC_TYPE" ]; then
    echo "Spec decoding: $SPEC_TYPE"
    echo "Draft n-max: $SPEC_DRAFT_N_MAX"
  else
    echo "Spec decoding: kapali"
  fi

  if [ "$ENABLE_MMPROJ" = "1" ]; then
    echo "Multimodal: aktif (mmproj=$MMPROJ_FILE)"
  else
    echo "Multimodal: kapali"
  fi

  if [ "$ENABLE_WEBUI" = "0" ]; then
    echo "Web UI: kapali"
  else
    echo "Web UI: http://$(hostname -I | awk '{print $1}'):$PORT"
  fi

  if [ -n "$API_KEY" ]; then
    echo "API key korumasi: aktif"
  else
    echo "API key korumasi: kapali"
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

install() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "llama-server calisiyor, once durduruluyor..."
    stop
  fi

  echo "=== llama.cpp / beellama.cpp kurulumu (CUDA arch $CUDA_ARCH) ==="
  echo "Repo:   $INSTALL_REPO_URL"
  echo "Branch: $INSTALL_BRANCH"
  echo "Hedef:  $LLAMA_DIR"

  if ! command -v git >/dev/null 2>&1; then
    echo "git bulunamadi. Once git kur."
    exit 1
  fi

  if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake bulunamadi. Once cmake kur."
    exit 1
  fi

  if ! command -v nvcc >/dev/null 2>&1; then
    echo "UYARI: nvcc bulunamadi. CUDA kurulu degilse derleme basarisiz olabilir."
  fi

  if [ -e "$LLAMA_DIR" ]; then
    echo "Varolan kurulum siliniyor: $LLAMA_DIR"
    rm -rf "$LLAMA_DIR"
  fi

  echo "Repo klonlaniyor..."
  git clone "$INSTALL_REPO_URL" "$LLAMA_DIR"

  cd "$LLAMA_DIR"
  git fetch --all
  git checkout "$INSTALL_BRANCH"
  git pull --ff-only origin "$INSTALL_BRANCH" || true

  echo "Derleme basliyor..."
  rm -rf build

  cmake -B build \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DLLAMA_CURL=ON \
    -DLLAMA_OPENSSL=ON \
    -DCMAKE_BUILD_TYPE=Release

  cmake --build build --config Release -j"$(nproc)"

  if [ ! -x ./build/bin/llama-server ]; then
    echo "HATA: derleme bitti ama ./build/bin/llama-server bulunamadi."
    exit 1
  fi

  echo "=== Kurulum tamamlandi ==="
  echo "Binary: $LLAMA_DIR/build/bin/llama-server"
  echo "Baslatmak icin: $0 --env <env-dosyasi> start"
}

case "$CMD" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  log)
    log
    ;;
  clearlog)
    clearlog
    ;;
  install)
    install
    ;;
  *)
    echo "Usage: $0 {start|stop|log|clearlog|install} [--env /path/to/.env]"
    exit 1
    ;;
esac