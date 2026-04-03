#!/usr/bin/env bash
set -e

########################################
# Config
########################################
MODEL_GGUF="${1:-models/model.gguf}"
WORKDIR="${HOME}/mnn-gguf-run"
MNN_REPO="https://github.com/alibaba/MNN.git"
THREADS="$(nproc || echo 8)"
USE_CUDA="1"

########################################
# Paths
########################################
MODEL_GGUF="$(realpath "$MODEL_GGUF")"
mkdir -p "$WORKDIR"

MNN_DIR="${WORKDIR}/MNN"
BUILD_DIR="${MNN_DIR}/build"
OUT_DIR="${WORKDIR}/converted"
MODEL_NAME="$(basename "$MODEL_GGUF" .gguf)"
MODEL_OUT_DIR="${OUT_DIR}/${MODEL_NAME}"

########################################
# Checks
########################################
command -v git >/dev/null || { echo "git yok"; exit 1; }
command -v cmake >/dev/null || { echo "cmake yok"; exit 1; }
command -v python3 >/dev/null || { echo "python3 yok"; exit 1; }

########################################
# Clone
########################################
if [[ ! -d "${MNN_DIR}/.git" ]]; then
  git clone --depth 1 "$MNN_REPO" "$MNN_DIR"
fi

########################################
# Python deps
########################################
python3 -m pip install -U pip
python3 -m pip install transformers sentencepiece protobuf numpy safetensors

########################################
# Build
########################################
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake .. -DMNN_BUILD_LLM=ON -DMNN_CUDA=${USE_CUDA}
cmake --build . -- -j"${THREADS}"

########################################
# Convert
########################################
GGUF2MNN=$(find "$MNN_DIR" -name "gguf2mnn.py" | head -n 1)

if [[ -z "$GGUF2MNN" ]]; then
  echo "gguf2mnn.py bulunamadı"
  exit 1
fi

rm -rf "$MODEL_OUT_DIR"
mkdir -p "$MODEL_OUT_DIR"

python3 "$GGUF2MNN" \
  --path "$MODEL_GGUF" \
  --out "$MODEL_OUT_DIR"

echo "[OK] Kurulum tamam"
echo "Model: $MODEL_OUT_DIR"