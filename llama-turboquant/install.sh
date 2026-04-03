#!/bin/bash
set -e

echo "=== llama-cpp-turboquant + TurboQuant (CUDA 13.0) Kurulumu Başlıyor ==="

# Gerekli sistem paketleri
sudo apt update
sudo apt install -y \
  build-essential \
  cmake \
  git \
  python3 \
  python3-pip \
  curl \
  libssl-dev

# CUDA 13.0 zaten kurulu varsayıyoruz (nvcc --version ile kontrol et)
if ! command -v nvcc >/dev/null 2>&1; then
    echo "UYARI: nvcc bulunamadı! CUDA 13.0 kurulu olduğundan emin olun."
    echo "Kurulum: https://developer.nvidia.com/cuda-13-0-download-archive"
fi

# Repo klonlama (en güncel TurboQuant branch)
if [ ! -d "llama-cpp-turboquant" ]; then
    echo "Repo klonlanıyor..."
    git clone https://github.com/TheTom/llama-cpp-turboquant.git
fi

cd llama-cpp-turboquant
git fetch --all
git checkout feature/turboquant-kv-cache
git pull

# Build klasörü temizle ve CUDA + HTTPS desteği ile derle (L40S için uygun arch)
echo "Derleme başlıyor..."
rm -rf build

cmake -B build \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  -DLLAMA_CURL=ON \
  -DLLAMA_OPENSSL=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j"$(nproc)"

echo "=== Kurulum tamamlandı! ==="
echo "Binary'ler: ./build/bin/llama-server ve ./build/bin/llama-cli"
echo "Not: Hugging Face üzerinden model indirmek için HTTPS/OpenSSL desteği etkinleştirildi."
cd ..