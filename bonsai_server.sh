#!/bin/sh

# Bonsai-8B Server Script
# Uses PrismML's llama.cpp + Bonsai-8B GGUF model
# POSIX sh compatible

# =========================
# Configuration
# =========================

HF_TOKEN="${HF_TOKEN:-}"

MODEL_DIR="${MODEL_DIR:-./models}"
MODEL_FILE="${MODEL_FILE:-Bonsai-8B.gguf}"
MODEL_PATH="${MODEL_PATH:-$MODEL_DIR/$MODEL_FILE}"
HF_MODEL_URL="${HF_MODEL_URL:-https://huggingface.co/prism-ml/Bonsai-8B-gguf/resolve/main/Bonsai-8B.gguf}"

LLAMA_CPP_REPO="${LLAMA_CPP_REPO:-https://github.com/PrismML-Eng/llama.cpp}"
LLAMA_CPP_BRANCH="${LLAMA_CPP_BRANCH:-}"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-./llama-cpp-prism}"
PORT="${PORT:-8002}"
HOST="${HOST:-0.0.0.0}"
CONTEXT_SIZE="${CONTEXT_SIZE:-32768}"

GPU_LAYERS="${GPU_LAYERS:-99}"

echo "=== Bonsai-8B Server ==="
echo "Model: $MODEL_PATH"
echo "Source: $HF_MODEL_URL"
echo "Context: $CONTEXT_SIZE tokens"
echo "GPU offload: $GPU_LAYERS layers"
echo ""

mkdir -p "$MODEL_DIR"

# =========================
# Helpers
# =========================
get_nvcc_version() {
    nvcc --version | sed -n 's/.*release \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
}

get_total_vram_mb() {
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1 | tr -d ' '
}

try_add_cuda_to_path() {
    for d in \
        /usr/local/cuda \
        /usr/local/cuda-12.9 \
        /usr/local/cuda-12.8 \
        /usr/local/cuda-12.7 \
        /usr/local/cuda-12.6 \
        /usr/local/cuda-12.5 \
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
    echo "ERROR: nvidia-smi not found. NVIDIA driver may not be installed."
    echo "Continuing in CPU-only mode (will be slow)."
    GPU_AVAILABLE=0
elif ! nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi failed. GPU is not accessible."
    echo "Continuing in CPU-only mode (will be slow)."
    GPU_AVAILABLE=0
else
    GPU_AVAILABLE=1
    echo "GPU detected:"
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    TOTAL_VRAM=$(get_total_vram_mb)
    echo "Total VRAM: ${TOTAL_VRAM} MB"

    # Fallback to CPU if VRAM is less than 1024 MB
    if [ "$TOTAL_VRAM" -lt 1024 ] 2>/dev/null; then
        echo "WARNING: GPU has less than 1GB VRAM (detected: ${TOTAL_VRAM} MB)."
        echo "Falling back to CPU-only mode."
        GPU_AVAILABLE=0
    fi

    echo ""
fi

# =========================
# Validate CUDA toolkit
# =========================
NVCC_PATH=""
if [ "$GPU_AVAILABLE" = "1" ]; then
    echo "Checking CUDA toolkit..."

    if ! command -v nvcc >/dev/null 2>&1; then
        echo "nvcc not in PATH, trying common CUDA install locations..."
        try_add_cuda_to_path
    fi

    if command -v nvcc >/dev/null 2>&1; then
        NVCC_PATH=$(command -v nvcc)
        CUDA_VERSION=$(get_nvcc_version)
        echo "nvcc path: $NVCC_PATH"
        echo "Detected CUDA version: $CUDA_VERSION"
    else
        echo "WARNING: nvcc not found."
        echo "Continuing with CPU-only build."
        GPU_AVAILABLE=0
    fi
    echo ""
fi

# =========================
# Build llama.cpp
# =========================
if [ ! -f "$LLAMA_CPP_DIR/build/bin/llama-server" ]; then
    echo "Building llama.cpp..."

    if [ ! -d "$LLAMA_CPP_DIR" ]; then
        git clone "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to clone llama.cpp repository."
            exit 1
        fi
    fi

    cd "$LLAMA_CPP_DIR" || exit 1

    if [ -n "$LLAMA_CPP_BRANCH" ]; then
        git checkout "$LLAMA_CPP_BRANCH"
    fi

    if [ "$GPU_AVAILABLE" = "1" ] && [ -n "$NVCC_PATH" ]; then
        echo "Building with CUDA support (nvcc: $NVCC_PATH)"
        cmake -B build \
            -DGGML_CUDA=ON \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_CUDA_COMPILER="$NVCC_PATH"
    else
        echo "Building CPU-only version"
        cmake -B build \
            -DCMAKE_BUILD_TYPE=Release
    fi

    if [ $? -ne 0 ]; then
        echo "ERROR: CMake configure failed."
        exit 1
    fi

    NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    cmake --build build -j"$NPROC"
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

    elif command -v curl >/dev/null 2>&1; then
        echo "Using curl..."
        if [ -n "$HF_TOKEN" ]; then
            curl -L -C - -H "Authorization: Bearer $HF_TOKEN" -o "$MODEL_PATH" "$HF_MODEL_URL"
        else
            curl -L -C - -o "$MODEL_PATH" "$HF_MODEL_URL"
        fi

    elif command -v wget >/dev/null 2>&1; then
        echo "Using wget..."
        if [ -n "$HF_TOKEN" ]; then
            wget --continue --header="Authorization: Bearer $HF_TOKEN" -O "$MODEL_PATH" "$HF_MODEL_URL"
        else
            wget --continue -O "$MODEL_PATH" "$HF_MODEL_URL"
        fi

    else
        echo "ERROR: aria2c, curl, or wget is required for downloading the model."
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
echo "Starting Bonsai-8B server..."
echo "Context window: $CONTEXT_SIZE"
echo "Flash Attention: enabled"
echo "OpenAI-compatible API: enabled"
echo ""

exec "$LLAMA_CPP_DIR/build/bin/llama-server" \
    -m "$MODEL_PATH" \
    --host "$HOST" \
    --port "$PORT" \
    -c "$CONTEXT_SIZE" \
    -ngl "$GPU_LAYERS" \
    -fa on \
    --jinja \
    --metrics \
    --alias "Bonsai-8B" \
    --log-disable
