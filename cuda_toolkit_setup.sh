#!/bin/sh
# cuda_toolkit_setup.sh
# Ubuntu 22.04 / 24.04 için NVIDIA CUDA Toolkit kurulumu
# Varsayılan paket: cuda-toolkit-13-0
#
# Kullanım:
#   sh ./cuda_toolkit_setup.sh
#
# Opsiyonel env değişkenleri:
#   CUDA_PKG=cuda-toolkit-13-0 sh ./cuda_toolkit_setup.sh
#   INSTALL_RECOMMENDS=0 sh ./cuda_toolkit_setup.sh
#   SKIP_PURGE=1 sh ./cuda_toolkit_setup.sh

set -eu

CUDA_PKG="${CUDA_PKG:-cuda-toolkit-13-0}"
INSTALL_RECOMMENDS="${INSTALL_RECOMMENDS:-0}"
SKIP_PURGE="${SKIP_PURGE:-1}"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

cleanup_file_if_exists() {
    if [ -f "$1" ]; then
        rm -f "$1"
    fi
}

require_root_or_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        need_cmd sudo
        SUDO="sudo"
    fi
}

detect_ubuntu_version() {
    if [ ! -r /etc/os-release ]; then
        fail "/etc/os-release not found; unsupported system"
    fi

    . /etc/os-release

    if [ "${ID:-}" != "ubuntu" ]; then
        fail "This script supports Ubuntu only. Detected ID=${ID:-unknown}"
    fi

    case "${VERSION_ID:-}" in
        22.04)
            UBUNTU_VER="2204"
            ;;
        24.04)
            UBUNTU_VER="2404"
            ;;
        *)
            fail "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Supported: 22.04, 24.04"
            ;;
    esac
}

check_gpu_and_driver() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        log "NVIDIA GPU/driver detected:"
        nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || true
        if nvidia-smi >/dev/null 2>&1; then
            CUDA_DRIVER_VERSION="$(nvidia-smi | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -n 1)"
            if [ -n "${CUDA_DRIVER_VERSION:-}" ]; then
                log "Driver-reported CUDA version: $CUDA_DRIVER_VERSION"
            fi
        fi
    else
        log "WARNING: nvidia-smi not found. Continuing, but CUDA runtime use may fail until driver is present."
    fi
}

optional_purge_old_cuda() {
    if [ "$SKIP_PURGE" = "1" ]; then
        log "Skipping old CUDA purge (SKIP_PURGE=1)."
        return 0
    fi

    log "Purging old CUDA-related packages..."
    $SUDO apt-get remove --purge -y \
        "cuda-*" \
        "libcublas-*" \
        "libcufft-*" \
        "libcurand-*" \
        "libcusolver-*" \
        "libcusparse-*" \
        "libnpp-*" \
        "libnvjpeg-*" \
        "nsight-*" || true

    $SUDO apt-get autoremove -y || true
}

install_prereqs() {
    log "Installing prerequisites..."
    $SUDO apt-get update
    $SUDO apt-get install -y wget gnupg ca-certificates
}

install_cuda_repo() {
    KEYRING_DEB="cuda-keyring_1.1-1_all.deb"
    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VER}/x86_64/${KEYRING_DEB}"

    log "Adding NVIDIA CUDA repository for Ubuntu ${UBUNTU_VER}..."
    cleanup_file_if_exists "/tmp/${KEYRING_DEB}"
    wget -O "/tmp/${KEYRING_DEB}" "$KEYRING_URL"
    $SUDO dpkg -i "/tmp/${KEYRING_DEB}"
    cleanup_file_if_exists "/tmp/${KEYRING_DEB}"

    $SUDO apt-get update
}

install_cuda_toolkit() {
    log "Installing CUDA package: $CUDA_PKG"
    if [ "$INSTALL_RECOMMENDS" = "1" ]; then
        $SUDO apt-get install -y "$CUDA_PKG"
    else
        $SUDO apt-get install -y --no-install-recommends "$CUDA_PKG"
    fi
}

detect_cuda_root() {
    for d in \
        /usr/local/cuda \
        /usr/local/cuda-13.2 \
        /usr/local/cuda-13.1 \
        /usr/local/cuda-13.0 \
        /usr/local/cuda-12.9 \
        /usr/local/cuda-12.8 \
        /usr/local/cuda-12.7 \
        /usr/local/cuda-12.6 \
        /usr/local/cuda-12.5 \
        /usr/local/cuda-12.4
    do
        if [ -d "$d" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

persist_env() {
    TARGET_RC="${HOME}/.bashrc"

    if [ ! -w "$TARGET_RC" ] && [ -e "$TARGET_RC" ]; then
        log "WARNING: Cannot write to $TARGET_RC; skipping persistent PATH update."
        return 0
    fi

    if [ ! -e "$TARGET_RC" ]; then
        : > "$TARGET_RC"
    fi

    if ! grep -Fq 'export PATH=/usr/local/cuda/bin:$PATH' "$TARGET_RC" 2>/dev/null; then
        printf '\nexport PATH=/usr/local/cuda/bin:$PATH\n' >> "$TARGET_RC"
    fi

    if ! grep -Fq 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' "$TARGET_RC" 2>/dev/null; then
        printf 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH\n' >> "$TARGET_RC"
    fi

    log "Persistent PATH entries appended to $TARGET_RC"
}

verify_install() {
    if command -v nvcc >/dev/null 2>&1; then
        NVCC_BIN="$(command -v nvcc)"
        log "nvcc found in PATH: $NVCC_BIN"
        nvcc --version || true
        return 0
    fi

    CUDA_ROOT="$(detect_cuda_root || true)"
    if [ -n "$CUDA_ROOT" ] && [ -x "$CUDA_ROOT/bin/nvcc" ]; then
        export PATH="$CUDA_ROOT/bin:$PATH"

        if [ -d "$CUDA_ROOT/lib64" ]; then
            if [ -n "${LD_LIBRARY_PATH:-}" ]; then
                export LD_LIBRARY_PATH="$CUDA_ROOT/lib64:$LD_LIBRARY_PATH"
            else
                export LD_LIBRARY_PATH="$CUDA_ROOT/lib64"
            fi
        fi

        log "nvcc found after PATH injection: $CUDA_ROOT/bin/nvcc"
        "$CUDA_ROOT/bin/nvcc" --version || true
        return 0
    fi

    fail "CUDA Toolkit installation finished but nvcc was not found"
}

print_next_steps() {
    CUDA_ROOT="$(detect_cuda_root || true)"

    log ""
    log "=== Installation completed ==="
    if [ -n "$CUDA_ROOT" ]; then
        log "Detected CUDA root: $CUDA_ROOT"
    fi
    log ""
    log "Open a new shell or run:"
    log "  export PATH=/usr/local/cuda/bin:\$PATH"
    log "  export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\$LD_LIBRARY_PATH"
    log ""
    log "Verification commands:"
    log "  which nvcc"
    log "  nvcc --version"
    log "  nvidia-smi"
    log ""
    log "Then retry your server script:"
    log "  sh ./turboquant_plus.sh"
}

grep -qxF 'export PATH=/usr/local/cuda/bin:$PATH' ~/.profile || echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.profile
grep -qxF 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' ~/.profile || echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.profile
. ~/.profile

main() {
    require_root_or_sudo
    detect_ubuntu_version
    check_gpu_and_driver
    optional_purge_old_cuda
    install_prereqs
    install_cuda_repo
    install_cuda_toolkit
    persist_env
    verify_install
    print_next_steps
}

main "$@"