# llama.cpp + Gemma 4 12B-it + Gemma 4 12B-it-assistant speculative decoding server
#
# Usage:
#   ./gemma12-server.sh start
#   ./gemma12-server.sh stop
#   ./gemma12-server.sh restart
#   ./gemma12-server.sh status
#   ./gemma12-server.sh log
#
# Example:
#   MODEL_URL="https://huggingface.co/<org>/<repo>/resolve/main/gemma-4-12B-it-Q5_K_M.gguf" \
#   DRAFT_URL="https://huggingface.co/<org>/<repo>/resolve/main/gemma-4-12B-it-assistant-Q4_K_M.gguf" \
#   ./gemma12-server.sh start
#
# Public network example:
#   HOST=0.0.0.0 LLAMA_API_KEY="change-me" ./gemma12-server.sh start

echo "=== Local LLM Server: Gemma 4 12B-it + Speculative Decoding ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

LLAMA_DIR="${LLAMA_DIR:-$ROOT_DIR/llama-cpp-turboquant}"
MODEL_DIR="${MODEL_DIR:-$ROOT_DIR/../models}"

LOG_FILE="${LOG_FILE:-$ROOT_DIR/gemma12-server.log}"
PID_FILE="${PID_FILE:-$ROOT_DIR/gemma12-server.pid}"

LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$LLAMA_DIR/build/bin/llama-server}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8003}"
API_KEY="${LLAMA_API_KEY:-}"

MODEL_URL="${MODEL_URL:-https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q8_K_XL.gguf}"
MODEL_FILE="${MODEL_FILE:-$MODEL_DIR/gemma-4-12b-it-UD-Q8_K_XL.gguf}"

DRAFT_URL="${DRAFT_URL:-https://huggingface.co/colefuoco00/gemma-4-12B-it-assistant-GGUF/resolve/main/gemma-4-12B-it-assistant-Q8_0.gguf}"
DRAFT_FILE="${DRAFT_FILE:-$MODEL_DIR/gemma-4-12B-it-assistant-Q8_0.gguf}"

ENABLE_MMPROJ="${ENABLE_MMPROJ:-0}"
MMPROJ_URL="${MMPROJ_URL:-}"
MMPROJ_FILE="${MMPROJ_FILE:-$MODEL_DIR/gemma-4-12B-it-mmproj-F16.gguf}"

CTX_SIZE="${CTX_SIZE:-131072}"
PARALLEL_SLOTS="${PARALLEL_SLOTS:-1}"

GPU_LAYERS="${GPU_LAYERS:-99}"
GPU_LAYERS_DRAFT="${GPU_LAYERS_DRAFT:-99}"

BATCH_SIZE="${BATCH_SIZE:-1024}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"
THREADS="${THREADS:-0}"

ENABLE_SPEC="${ENABLE_SPEC:-0}"
SPEC_TYPE="${SPEC_TYPE:-draft-simple}"
DRAFT_MAX="${DRAFT_MAX:-8}"
DRAFT_MIN="${DRAFT_MIN:-0}"
DRAFT_P_MIN="${DRAFT_P_MIN:-0.50}"

CACHE_TYPE_K="${CACHE_TYPE_K:-q4_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q4_0}"

ENABLE_WEBUI="${ENABLE_WEBUI:-1}"
ENABLE_SLOTS="${ENABLE_SLOTS:-1}"

fail() {
  echo "HATA: $*" >&2
  exit 1
}

info() {
  echo "$*"
}

require_command() {
  _cmd="$1"
  command -v "$_cmd" >/dev/null 2>&1 || fail "$_cmd bulunamadi."
}

download_with_aria2c() {
  _url="$1"
  _out_file="$2"

  [ -n "$_url" ] || fail "Indirme URL'i bos. Lokal dosya yoksa ilgili URL degiskenini doldur."

  require_command aria2c

  mkdir -p "$MODEL_DIR"

  aria2c \
    --dir="$MODEL_DIR" \
    --out="$(basename "$_out_file")" \
    --continue=true \
    --max-connection-per-server=16 \
    --split=16 \
    --min-split-size=10M \
    --file-allocation=none \
    "$_url"
}

ensure_file_or_download() {
  _label="$1"
  _file="$2"
  _url="$3"

  info ""
  info "$_label:"
  info "  Dosya: $_file"

  if [ -f "$_file" ]; then
    info "  Var, indirme atlandi."
    return 0
  fi

  info "  Dosya yok."

  if [ -z "$_url" ]; then
    fail "$_label bulunamadi ve URL bos: $_file"
  fi

  info "  Indiriliyor: $_url"
  download_with_aria2c "$_url" "$_file"

  [ -f "$_file" ] || fail "$_label indirildi gorunuyor ama dosya bulunamadi: $_file"
}

server_supports() {
  _needle="$1"
  "$LLAMA_SERVER_BIN" --help 2>&1 | grep -q -- "$_needle"
}

validate_environment() {
  [ -d "$LLAMA_DIR" ] || fail "LLAMA_DIR bulunamadi: $LLAMA_DIR"
  [ -x "$LLAMA_SERVER_BIN" ] || fail "llama-server bulunamadi veya executable degil: $LLAMA_SERVER_BIN"

  if [ "$ENABLE_SPEC" = "1" ]; then
    server_supports "--spec-type" || fail "Bu llama-server build'i --spec-type desteklemiyor. llama.cpp'i guncelle."
    server_supports "--spec-draft-n-max" || fail "Bu llama-server build'i --spec-draft-n-max desteklemiyor. llama.cpp'i guncelle."
    server_supports "--spec-draft-n-min" || fail "Bu llama-server build'i --spec-draft-n-min desteklemiyor. llama.cpp'i guncelle."
    server_supports "--spec-draft-p-min" || fail "Bu llama-server build'i --spec-draft-p-min desteklemiyor. llama.cpp'i guncelle."
  fi
  server_supports "--cache-type-k" || fail "Bu llama-server build'i --cache-type-k desteklemiyor."

  if [ "$CACHE_TYPE_K" = "turbo4" ] || [ "$CACHE_TYPE_V" = "turbo4" ]; then
    if ! "$LLAMA_SERVER_BIN" --help 2>&1 | grep -qi "turbo4"; then
      fail "turbo4 secildi ama bu llama-server build'i turbo4 destekli gorunmuyor."
    fi
  fi
}

read_pid() {
  if [ -f "$PID_FILE" ]; then
    cat "$PID_FILE"
  else
    echo ""
  fi
}

is_running_pid() {
  _pid="$1"
  [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null
}

cleanup_stale_pid() {
  _pid="$(read_pid)"
  if [ -n "$_pid" ] && ! is_running_pid "$_pid"; then
    info "Stale PID dosyasi temizleniyor: $PID_FILE"
    rm -f "$PID_FILE"
  fi
}

print_summary() {
  info ""
  info "Ayar ozeti:"
  info "  LLAMA_DIR:        $LLAMA_DIR"
  info "  Server bin:       $LLAMA_SERVER_BIN"
  info "  Host/Port:        $HOST:$PORT"
  info "  Ana model:        $MODEL_FILE"
  if [ "$ENABLE_SPEC" = "1" ]; then
    info "  Draft model:      $DRAFT_FILE"
  else
    info "  Draft model:      kapali (speculative off)"
  fi
  info "  Context:          $CTX_SIZE"
  info "  Parallel slots:   $PARALLEL_SLOTS"
  info "  GPU layers:       $GPU_LAYERS"
  info "  Batch/ubatch:     $BATCH_SIZE/$UBATCH_SIZE"
  info "  Threads:          $THREADS"
  info "  KV cache K/V:     $CACHE_TYPE_K/$CACHE_TYPE_V"
  if [ "$ENABLE_SPEC" = "1" ]; then
    info "  Draft GPU layers: $GPU_LAYERS_DRAFT"
    info "  Spec type:        $SPEC_TYPE"
    info "  Draft max/min:    $DRAFT_MAX/$DRAFT_MIN"
    info "  Draft p-min:      $DRAFT_P_MIN"
  fi

  if [ "$ENABLE_WEBUI" = "1" ]; then
    info "  Web UI:           acik"
  else
    info "  Web UI:           kapali"
  fi

  if [ "$ENABLE_SLOTS" = "1" ]; then
    info "  Slots endpoint:   acik"
  else
    info "  Slots endpoint:   kapali"
  fi

  if [ "$ENABLE_MMPROJ" = "1" ]; then
    info "  Multimodal:       acik ($MMPROJ_FILE)"
  else
    info "  Multimodal:       kapali"
  fi

  if [ -n "$API_KEY" ]; then
    info "  API key:          aktif"
  else
    info "  API key:          kapali"
  fi
}

start() {
  cleanup_stale_pid

  _existing_pid="$(read_pid)"
  if is_running_pid "$_existing_pid"; then
    info "gemma12-server zaten calisiyor. PID: $_existing_pid"
    exit 0
  fi

  validate_environment

  mkdir -p "$MODEL_DIR"

  ensure_file_or_download "Ana model GGUF" "$MODEL_FILE" "$MODEL_URL"

  if [ "$ENABLE_SPEC" = "1" ]; then
    ensure_file_or_download "Draft/assistant model GGUF" "$DRAFT_FILE" "$DRAFT_URL"
  fi

  if [ "$ENABLE_MMPROJ" = "1" ]; then
    ensure_file_or_download "MMProj GGUF" "$MMPROJ_FILE" "$MMPROJ_URL"
  fi

  : > "$LOG_FILE"

  print_summary

  info ""
  info "Sunucu baslatiliyor..."

  cd "$LLAMA_DIR"

  set -- \
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
    --no-mmap

  if [ "$ENABLE_SPEC" = "1" ]; then
    set -- "$@" \
      --spec-type "$SPEC_TYPE" \
      -md "$DRAFT_FILE" \
      -ngld "$GPU_LAYERS_DRAFT" \
      --spec-draft-n-max "$DRAFT_MAX" \
      --spec-draft-n-min "$DRAFT_MIN" \
      --spec-draft-p-min "$DRAFT_P_MIN"
  fi

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

  nohup "$LLAMA_SERVER_BIN" "$@" > "$LOG_FILE" 2>&1 &

  SERVER_PID=$!
  echo "$SERVER_PID" > "$PID_FILE"

  sleep 2

  if ! is_running_pid "$SERVER_PID"; then
    info ""
    info "Sunucu baslatilamadi. Son loglar:"
    tail -n 120 "$LOG_FILE" || true
    rm -f "$PID_FILE"
    exit 1
  fi

  info ""
  info "gemma12-server baslatildi. PID: $SERVER_PID"
  info "Log: $LOG_FILE"
  info "Endpoint: http://$HOST:$PORT"

  if [ "$ENABLE_WEBUI" = "1" ]; then
    info "Web UI: http://$HOST:$PORT"
  fi

  info ""
  info "Log izlemek icin:"
  info "  $0 log"
}

stop() {
  _pid="$(read_pid)"

  if [ -z "$_pid" ]; then
    info "Calismiyor. PID dosyasi yok."
    exit 0
  fi

  if ! is_running_pid "$_pid"; then
    info "Surec canli degil. PID dosyasi temizleniyor: $_pid"
    rm -f "$PID_FILE"
    exit 0
  fi

  info "gemma12-server durduruluyor. PID: $_pid"
  kill "$_pid" 2>/dev/null || true

  i=0
  while [ "$i" -lt 30 ]; do
    if ! is_running_pid "$_pid"; then
      break
    fi
    sleep 1
    i=$((i + 1))
  done

  if is_running_pid "$_pid"; then
    info "Graceful shutdown basarisiz. Zorla durduruluyor..."
    kill -9 "$_pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  info "Durduruldu."
}

restart() {
  stop || true
  start
}

status() {
  _pid="$(read_pid)"

  if [ -z "$_pid" ]; then
    info "Durum: calismiyor. PID dosyasi yok."
    exit 0
  fi

  if is_running_pid "$_pid"; then
    info "Durum: calisiyor. PID: $_pid"
    info "Endpoint: http://$HOST:$PORT"
    info "Log: $LOG_FILE"
  else
    info "Durum: calismiyor. Stale PID temizleniyor: $_pid"
    rm -f "$PID_FILE"
  fi
}

log() {
  if [ ! -f "$LOG_FILE" ]; then
    fail "Log dosyasi yok: $LOG_FILE"
  fi

  tail -n 255 -f "$LOG_FILE"
}

case "${1:-}" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    restart
    ;;
  status)
    status
    ;;
  log)
    log
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|log}"
    exit 1
    ;;
esac