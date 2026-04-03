#!/bin/sh

# TurboQuant+ 64K Context Server for Qwen3.5-35B-A3B-Q4_K_M on NVIDIA L40S
# POSIX sh uyumlu sürüm

# =========================
# Configuration
# =========================

MODEL_DIR="${MODEL_DIR:-../models}"
MODEL_FILE="${MODEL_FILE:-Qwen3.5-35B-A3B-Q4_K_M.gguf}"
MODEL_PATH="${MODEL_PATH:-$MODEL_DIR/$MODEL_FILE}"
HF_MODEL_URL="${HF_MODEL_URL:-https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF/resolve/main/Qwen3.5-35B-A3B-Q4_K_M.gguf}"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-../llama-cpp-turboquant-cuda}"
PORT="${PORT:-8001}"
HOST="${HOST:-0.0.0.0}"
CONTEXT_SIZE="${CONTEXT_SIZE:-65536}"

CUDA_REQUIRED_VERSION="${CUDA_REQUIRED_VERSION:-13.0}"
CUDA_STRICT_VERSION="${CUDA_STRICT_VERSION:-0}"

echo "=== TurboQuant+ 64K Context Server ==="
echo "Model: $MODEL_PATH"
echo "Source: $HF_MODEL_URL"
echo "Context: $CONTEXT_SIZE tokens"
echo "Hardware target: NVIDIA L40S (48GB VRAM)"
echo "Required CUDA version: $CUDA_REQUIRED_VERSION (strict=$CUDA_STRICT_VERSION)"
echo ""

mkdir -p "$MODEL_DIR"

# =========================
# Helpers
# =========================
get_nvcc_version() {
    nvcc --version | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
}

try_add_cuda_to_path() {
    for d in \
        /usr/local/cuda \
        /usr/local/cuda-13.0 \
        /usr/local/cuda-12.9 \
        /usr/local/cuda-12.8 \
        /usr/local/cuda-12.7 \
        /usr/local/cuda-12.6 \
        /opt/cuda \
        /opt/nvidia/cuda
    do
        if [ -x "$d/bin/nvcc" ]; then
            PATH="$d/bin:$PATH"
            export PATH

            if [ -d "$d/lib64" ]; then
                if [ -n "${LD_LIBRARY_PATH:-}" ]; then
                    LD_LIBRARY_PATH="$d/lib64:$LD_LIBRARY_PATH"
                else
                    LD_LIBRARY_PATH="$d/lib64"
                fi
                export LD_LIBRARY_PATH
            fi

            echo "Auto-detected CUDA toolkit at: $d"
            return 0
        fi
    done

    return 1
}

# =========================
# Validate GPU
# =========================
echo "Checking NVIDIA driver and GPU visibility..."
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not found. NVIDIA driver may not be installed correctly."
    exit 1
fi

if ! nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi failed. GPU is not accessible."
    exit 1
fi

echo "GPU(s) detected:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
echo ""

# =========================
# Validate CUDA toolkit
# =========================
echo "Checking CUDA toolkit..."

# Driver tarafındaki CUDA version (nvidia-smi'den)
CUDA_DRIVER_VERSION=`nvidia-smi | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -n 1`

if [ -n "$CUDA_DRIVER_VERSION" ]; then
    echo "Driver CUDA version (from nvidia-smi): $CUDA_DRIVER_VERSION"
else
    echo "WARNING: Could not detect CUDA version from nvidia-smi"
fi

if ! command -v nvcc >/dev/null 2>&1; then
    echo "nvcc not found in PATH, trying common CUDA install locations..."
    try_add_cuda_to_path
fi

if ! command -v nvcc >/dev/null 2>&1; then
    echo "ERROR: nvcc not found in PATH and not found in common CUDA install locations."
    echo ""
    echo "Fix options:"
    echo "  1) Install CUDA Toolkit"
    echo "  2) Or add existing install to PATH manually:"
    echo "     export PATH=/usr/local/cuda/bin:\$PATH"
    echo "     export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH"
    echo ""
    echo "Useful checks:"
    echo "  ls -ld /usr/local/cuda*"
    echo "  find /usr/local -name nvcc 2>/dev/null"
    echo "  find /opt -name nvcc 2>/dev/null"
    exit 1
fi

NVCC_PATH=`command -v nvcc`
CUDA_FOUND_VERSION=`get_nvcc_version`

if [ -z "$CUDA_FOUND_VERSION" ]; then
    echo "ERROR: Could not parse CUDA version from nvcc."
    echo "nvcc path: $NVCC_PATH"
    nvcc --version || true
    exit 1
fi

echo "nvcc path: $NVCC_PATH"
echo "Detected CUDA version: $CUDA_FOUND_VERSION"

if [ "$CUDA_STRICT_VERSION" = "1" ]; then
    if [ "$CUDA_FOUND_VERSION" != "$CUDA_REQUIRED_VERSION" ]; then
        echo "ERROR: CUDA version mismatch."
        echo "Expected: $CUDA_REQUIRED_VERSION"
        echo "Found:    $CUDA_FOUND_VERSION"
        echo "Disable exact version enforcement with:"
        echo "  export CUDA_STRICT_VERSION=0"
        exit 1
    fi
else
    echo "Strict CUDA version check disabled; continuing."
fi

echo ""

# =========================
# Build llama.cpp
# =========================
if [ ! -f "$LLAMA_CPP_DIR/build/bin/llama-server" ]; then
    echo "Building llama.cpp with TurboQuant+ CUDA support..."

    if [ ! -d "$LLAMA_CPP_DIR" ]; then
        git clone https://github.com/spiritbuun/llama-cpp-turboquant-cuda.git "$LLAMA_CPP_DIR"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to clone llama.cpp repository."
            exit 1
        fi
    fi

    cd "$LLAMA_CPP_DIR" || exit 1
    git checkout feature/turboquant-kv-cache

    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_COMPILER="$NVCC_PATH"

    if [ $? -ne 0 ]; then
        echo "ERROR: CMake configure failed."
        exit 1
    fi

    cmake --build build -j"$(nproc)"
    if [ $? -ne 0 ]; then
        echo "ERROR: Build failed."
        exit 1
    fi

    cd - >/dev/null 2>&1 || exit 1
    echo "Build completed!"
fi

# =========================
# Download model if missing
# =========================
if [ ! -f "$MODEL_PATH" ]; then
    echo "Model not found locally."
    echo "Downloading model to: $MODEL_PATH"

    if command -v aria2c >/dev/null 2>&1; then
        echo "Using aria2c..."
        if [ -n "$HF_TOKEN" ]; then
            aria2c \
                --continue=true \
                --max-connection-per-server=16 \
                --split=16 \
                --min-split-size=10M \
                --header="Authorization: Bearer $HF_TOKEN" \
                --dir="$MODEL_DIR" \
                --out="$MODEL_FILE" \
                "$HF_MODEL_URL"
        else
            aria2c \
                --continue=true \
                --max-connection-per-server=16 \
                --split=16 \
                --min-split-size=10M \
                --dir="$MODEL_DIR" \
                --out="$MODEL_FILE" \
                "$HF_MODEL_URL"
        fi

    elif command -v wget >/dev/null 2>&1; then
        echo "aria2c not found, falling back to wget..."
        if [ -n "$HF_TOKEN" ]; then
            wget -c --header="Authorization: Bearer $HF_TOKEN" -O "$MODEL_PATH" "$HF_MODEL_URL"
        else
            wget -c -O "$MODEL_PATH" "$HF_MODEL_URL"
        fi

    elif command -v curl >/dev/null 2>&1; then
        echo "aria2c/wget not found, falling back to curl..."
        if [ -n "$HF_TOKEN" ]; then
            curl -L -C - -H "Authorization: Bearer $HF_TOKEN" -o "$MODEL_PATH" "$HF_MODEL_URL"
        else
            curl -L -C - -o "$MODEL_PATH" "$HF_MODEL_URL"
        fi

    else
        echo "ERROR: aria2c, wget or curl is required for downloading the model."
        exit 1
    fi

    if [ $? -ne 0 ]; then
        echo "ERROR: Model download failed."
        exit 1
    fi

    echo "Model download completed!"
fi

# =========================
# Verify model exists
# =========================
if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: Model file not found at $MODEL_PATH"
    exit 1
fi

# =========================
# Start server
# =========================
echo "Starting server with optimal 64K context configuration..."
echo "Cache Strategy: turbo4"
echo "Features: Sparse V enabled, Flash Attention, OpenAI API"
echo ""

exec "$LLAMA_CPP_DIR/build/bin/llama-server" \
    -m "$MODEL_PATH" \
    --host "$HOST" \
    --port "$PORT" \
    -c "$CONTEXT_SIZE" \
    -ngl 99 \
    -fa on \
    --cache-type-k turbo4 \
    --cache-type-v turbo4 \
    -np 1 \
    --jinja \
    --metrics \
    --alias "Qwen3.5-35B-A3B-Q4_K_M-64K" \
    -ub 8192 \
    --log-disable