#!/usr/bin/env bash
set -e

########################################
# Defaults
########################################
MODEL_GGUF="models/gemma-4-26B-A4B-it-UD-Q6_K.gguf"
WORKDIR="${HOME}/mnn-gguf-run"
MNN_REPO="https://github.com/alibaba/MNN.git"
MNN_BRANCH="master"
PROMPT="Merhaba, kendini tanit."
THREADS="$(nproc || echo 8)"
CTX_LEN="4096"
FORCE_REBUILD="0"
KEEP_BUILD="1"
USE_CUDA="1"

PID_FILE=""
MNN_DIR=""
BUILD_DIR=""
OUT_DIR=""
MODEL_NAME=""
MODEL_OUT_DIR=""
CONFIG_JSON=""

########################################
# Helpers
########################################
log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

err() {
  echo "[ERROR] $*" >&2
}

usage() {
  cat <<EOF
Kullanim:
  bash $(basename "$0") <komut> [secenekler]

Komutlar:
  install               MNN klonla, derle, GGUF -> MNN cevir
  run                   Cevrilmis modeli calistir
  stop                  Calisan sureci durdur
  status                Calisan sureci goster
  help                  Yardim

Genel secenekler:
  --model PATH          GGUF dosya yolu
                        Varsayilan: ${MODEL_GGUF}

  --workdir DIR         Calisma klasoru
                        Varsayilan: ${WORKDIR}

  --branch NAME         MNN branch/tag
                        Varsayilan: ${MNN_BRANCH}

  --threads N           Derleme thread sayisi
                        Varsayilan: ${THREADS}

  --ctx N               Context length
                        Varsayilan: ${CTX_LEN}

  --prompt TEXT         Prompt
                        Varsayilan: ${PROMPT}

  --force-rebuild       Build klasorunu silip bastan derler
  --no-cuda             CUDA yerine CPU kullanir
  --cleanup-build       Is bitince build klasorunu siler
  -h, --help            Yardim

Ornekler:
  bash $(basename "$0") install --model models/model.gguf
  bash $(basename "$0") run --model models/model.gguf --prompt "Merhaba"
  bash $(basename "$0") stop
  bash $(basename "$0") status
EOF
}

resolve_paths() {
  mkdir -p "$WORKDIR"
  WORKDIR="$(realpath "$WORKDIR")"

  MNN_DIR="${WORKDIR}/MNN"
  BUILD_DIR="${MNN_DIR}/build"
  OUT_DIR="${WORKDIR}/converted"

  if [[ -n "${MODEL_GGUF:-}" ]]; then
    MODEL_GGUF="$(realpath "$MODEL_GGUF")"
    MODEL_NAME="$(basename "$MODEL_GGUF" .gguf)"
    MODEL_OUT_DIR="${OUT_DIR}/${MODEL_NAME}"
    CONFIG_JSON="${MODEL_OUT_DIR}/config.json"
  fi

  PID_FILE="${WORKDIR}/app.pid"
}

find_gguf2mnn() {
  local p
  for p in \
    "${MNN_DIR}/transformers/llm/export/gguf2mnn.py" \
    "${MNN_DIR}/transformers/llm/gguf2mnn.py" \
    "${MNN_DIR}/tools/convert/gguf2mnn.py" \
    "${MNN_DIR}/llm/gguf2mnn.py"
  do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

find_llm_demo() {
  local p
  for p in \
    "${BUILD_DIR}/llm_demo" \
    "${BUILD_DIR}/bin/llm_demo" \
    "${BUILD_DIR}/tools/llm_demo" \
    "${BUILD_DIR}/llm/llm_demo"
  do
    if [[ -x "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

patch_config() {
  if [[ -f "$CONFIG_JSON" ]]; then
    log "config.json backend ayari guncelleniyor"
    python3 - "$CONFIG_JSON" "$USE_CUDA" "$CTX_LEN" <<'PY'
import json, sys
cfg_path = sys.argv[1]
use_cuda = sys.argv[2] == "1"
ctx_len = int(sys.argv[3])

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

cfg["backend_type"] = "cuda" if use_cuda else "cpu"
cfg["max_new_tokens"] = cfg.get("max_new_tokens", 512)
cfg["max_input_length"] = ctx_len

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)

print(f"[INFO] backend_type={cfg['backend_type']}, max_input_length={cfg['max_input_length']}")
PY
  else
    warn "config.json bulunamadigi icin backend patch atlandi"
  fi
}

########################################
# Commands
########################################
cmd_install() {
  resolve_paths

  if [[ ! -f "$MODEL_GGUF" ]]; then
    err "GGUF dosyasi bulunamadi: $MODEL_GGUF"
    exit 1
  fi

  command -v git >/dev/null 2>&1 || { err "git kurulu degil"; exit 1; }
  command -v cmake >/dev/null 2>&1 || { err "cmake kurulu degil"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { err "python3 kurulu degil"; exit 1; }

  if [[ "$USE_CUDA" == "1" ]]; then
    command -v nvcc >/dev/null 2>&1 || {
      err "CUDA istendi ama nvcc bulunamadi. CUDA toolkit kur ya da --no-cuda kullan."
      exit 1
    }
  fi

  if [[ ! -d "${MNN_DIR}/.git" ]]; then
    log "MNN klonlaniyor: ${MNN_REPO}"
    git clone --depth 1 --branch "$MNN_BRANCH" "$MNN_REPO" "$MNN_DIR"
  else
    log "MNN zaten var: ${MNN_DIR}"
  fi

  log "Python bagimliliklari kontrol ediliyor"
  python3 -m pip install -U pip >/dev/null 2>&1 || true
  python3 -m pip install transformers sentencepiece protobuf numpy safetensors >/dev/null 2>&1 || true

  if [[ "$FORCE_REBUILD" == "1" && -d "$BUILD_DIR" ]]; then
    log "Build klasoru temizleniyor"
    rm -rf "$BUILD_DIR"
  fi

  mkdir -p "$BUILD_DIR"
  mkdir -p "$OUT_DIR"

  log "MNN derleniyor"
  pushd "$BUILD_DIR" >/dev/null

  CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DMNN_BUILD_LLM=ON
    -DMNN_BUILD_SHARED_LIBS=ON
  )

  if [[ "$USE_CUDA" == "1" ]]; then
    CMAKE_ARGS+=(-DMNN_CUDA=ON)
  else
    CMAKE_ARGS+=(-DMNN_CUDA=OFF)
  fi

  cmake .. "${CMAKE_ARGS[@]}"
  cmake --build . -- -j"${THREADS}"

  popd >/dev/null

  GGUF2MNN="$(find_gguf2mnn || true)"
  if [[ -z "$GGUF2MNN" ]]; then
    err "gguf2mnn.py bulunamadi. MNN repo yapisi degismis olabilir."
    exit 2
  fi

  log "Conversion script bulundu: $GGUF2MNN"

  rm -rf "$MODEL_OUT_DIR"
  mkdir -p "$MODEL_OUT_DIR"

  log "GGUF MNN formatina cevriliyor"
  set +e
  python3 "$GGUF2MNN" --path "$MODEL_GGUF" --out "$MODEL_OUT_DIR"
  CONVERT_RC=$?
  set -e

  if [[ "$CONVERT_RC" -ne 0 ]]; then
    err "GGUF -> MNN donusumu basarisiz oldu"
    exit 3
  fi

  if [[ ! -f "$CONFIG_JSON" ]]; then
    warn "config.json beklenen yerde yok, uretilen dosyalar:"
    find "$MODEL_OUT_DIR" -maxdepth 2 -type f | sed 's/^/  /'
  fi

  patch_config

  if [[ "$KEEP_BUILD" == "0" ]]; then
    log "Build klasoru temizleniyor"
    rm -rf "$BUILD_DIR"
  fi

  log "Tamamlandi"
  log "Cevrilmis model klasoru: $MODEL_OUT_DIR"
}

cmd_run() {
  resolve_paths

  if [[ ! -d "$MODEL_OUT_DIR" ]]; then
    err "Cevrilmis model klasoru yok: $MODEL_OUT_DIR"
    err "Once install calistir:"
    err "  bash $(basename "$0") install --model $MODEL_GGUF"
    exit 1
  fi

  LLM_DEMO="$(find_llm_demo || true)"
  if [[ -z "$LLM_DEMO" ]]; then
    err "llm_demo binary bulunamadi"
    exit 2
  fi

  if [[ -f "$PID_FILE" ]]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
      err "Zaten calisan bir surec var. PID=$OLD_PID"
      exit 3
    else
      rm -f "$PID_FILE"
    fi
  fi

  log "Model calistiriliyor"
  echo
  echo "========== PROMPT =========="
  echo "$PROMPT"
  echo "============================"
  echo

  nohup "$LLM_DEMO" "$MODEL_OUT_DIR" "$PROMPT" > "${WORKDIR}/run.log" 2>&1 &
  RUN_PID=$!
  echo "$RUN_PID" > "$PID_FILE"

  log "Calisti. PID: $RUN_PID"
  log "Log dosyasi: ${WORKDIR}/run.log"
}

cmd_stop() {
  resolve_paths

  if [[ ! -f "$PID_FILE" ]]; then
    warn "PID dosyasi yok. Calisan surec kaydi bulunamadi."
    exit 0
  fi

  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -z "$PID" ]]; then
    warn "PID bos. Dosya temizleniyor."
    rm -f "$PID_FILE"
    exit 0
  fi

  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    log "Surec durduruldu. PID: $PID"
  else
    warn "Surec zaten calismiyor. PID: $PID"
  fi

  rm -f "$PID_FILE"
}

cmd_status() {
  resolve_paths

  if [[ ! -f "$PID_FILE" ]]; then
    echo "Durum: calismiyor"
    exit 0
  fi

  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    echo "Durum: calisiyor (PID: $PID)"
    echo "Log: ${WORKDIR}/run.log"
  else
    echo "Durum: calismiyor (stale pid dosyasi)"
  fi
}

########################################
# Parse command
########################################
COMMAND="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL_GGUF="$2"
      shift 2
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --prompt)
      PROMPT="$2"
      shift 2
      ;;
    --threads)
      THREADS="$2"
      shift 2
      ;;
    --ctx)
      CTX_LEN="$2"
      shift 2
      ;;
    --branch)
      MNN_BRANCH="$2"
      shift 2
      ;;
    --force-rebuild)
      FORCE_REBUILD="1"
      shift
      ;;
    --no-cuda)
      USE_CUDA="0"
      shift
      ;;
    --cleanup-build)
      KEEP_BUILD="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Bilinmeyen arguman: $1"
      usage
      exit 1
      ;;
  esac
done

########################################
# Dispatch
########################################
case "$COMMAND" in
  install)
    cmd_install
    ;;
  run)
    cmd_run
    ;;
  stop)
    cmd_stop
    ;;
  status)
    cmd_status
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    err "Bilinmeyen komut: $COMMAND"
    usage
    exit 1
    ;;
esac