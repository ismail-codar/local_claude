#!/bin/sh
# Bonsai-Image (docker) server control: build / start / stop / log / status
#
# triposplat/cli.sh ile aynı arayüz (start|stop|status|log) + bu space docker
# SDK'lı olduğu için ek bir `build` komutu. TripoSplat doğrudan `python app.py`
# çalıştırıyordu; Bonsai ise nginx + GPU backend'leri olan bir CUDA imajı
# (nvidia/cuda:12.8.0-runtime) içinde :7860'a bind eder. Bu yüzden PID yerine
# docker container yaşam döngüsünü yönetiyoruz.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/bonsai-image.log"

IMAGE="${BONSAI_IMAGE:-bonsai-image:local}"
CONTAINER="${BONSAI_CONTAINER:-bonsai-image}"

# Container içi sabit 7860 (HF Space app_port). Dışarıya bu portu açıyoruz;
# Caddy önünde de çalıştırılabilir (bkz. caddy-server/Caddyfile → :7997).
HOST="${BONSAI_HOST:-0.0.0.0}"
PORT="${BONSAI_PORT:-8011}"

# Dashboard basic-auth parolası ve warmup şekilleri runtime env olarak geçer.
DASHBOARD_KEY="${DASHBOARD_KEY:-bonsai}"
BONSAI_WARMUP_SHAPES="${BONSAI_WARMUP_SHAPES:-512x512,1024x1024}"

is_running() {
  [ -n "$(docker ps -q -f "name=^${CONTAINER}$" 2>/dev/null)" ]
}

exists() {
  [ -n "$(docker ps -aq -f "name=^${CONTAINER}$" 2>/dev/null)" ]
}

build() {
  cd "$SCRIPT_DIR" || exit 1

  # Dockerfile özel GitHub repo'sunu (PrismML-Eng/Bonsai-image-demo) klonlamak
  # için `--mount=type=secret,id=GH_TOKEN` bekler. Token'ı GH_TOKEN env'den ya
  # da bu klasördeki .gh_token dosyasından alıyoruz; layer'a yazılmaz.
  GH_TOKEN_FILE="$SCRIPT_DIR/.gh_token"
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN" > "$GH_TOKEN_FILE.tmp"
    GH_TOKEN_FILE="$GH_TOKEN_FILE.tmp"
  elif [ ! -f "$GH_TOKEN_FILE" ]; then
    echo "HATA: GH_TOKEN bulunamadı." >&2
    echo "  export GH_TOKEN=ghp_xxx   (ya da)   echo ghp_xxx > $SCRIPT_DIR/.gh_token" >&2
    exit 1
  fi

  echo "Bonsai-Image imajı derleniyor → $IMAGE ..."
  # BuildKit secret mount için DOCKER_BUILDKIT=1 şart.
  DOCKER_BUILDKIT=1 docker build \
    --secret id=GH_TOKEN,src="$GH_TOKEN_FILE" \
    -t "$IMAGE" .
  rc=$?

  rm -f "$SCRIPT_DIR/.gh_token.tmp"
  [ "$rc" -eq 0 ] && echo "Derlendi: $IMAGE"
  return "$rc"
}

start() {
  if is_running; then
    echo "Bonsai-Image zaten çalışıyor (container $CONTAINER)."
    exit 0
  fi

  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "İmaj yok ($IMAGE). Önce: $0 build"
    exit 1
  fi

  # Önceki durmuş container varsa temizle (aynı isimle çakışmasın).
  exists && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  echo "Bonsai-Image başlatılıyor → $HOST:$PORT (container :7860) ..."
  # --gpus all: CUDA backend'leri için (nvidia-container-toolkit gerekir).
  docker run -d \
    --name "$CONTAINER" \
    --gpus all \
    -p "$HOST:$PORT:7860" \
    -e DASHBOARD_KEY="$DASHBOARD_KEY" \
    -e BONSAI_WARMUP_SHAPES="$BONSAI_WARMUP_SHAPES" \
    "$IMAGE" >/dev/null

  echo "Başlatıldı (container $CONTAINER). Log: $0 log"
  echo "Model indirme + warmup birkaç dakika sürebilir; hazır olunca :$PORT açılır."
  echo "Caddy üzerinden erişim: http://localhost:7997/"
}

stop() {
  if ! exists; then
    echo "Bonsai-Image çalışmıyor."
    exit 0
  fi

  echo "Bonsai-Image durduruluyor (container $CONTAINER)..."
  docker stop -t 30 "$CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  echo "Durduruldu."
}

status() {
  if is_running; then
    echo "Bonsai-Image çalışıyor (container $CONTAINER) → $HOST:$PORT"
    docker ps -f "name=^${CONTAINER}$" --format '  {{.Status}}  ({{.Ports}})'
  else
    echo "Bonsai-Image çalışmıyor."
  fi
}

log() {
  if ! exists; then
    echo "Container yok: $CONTAINER"
    exit 1
  fi
  # docker logs zaten son satırları + canlı akışı verir; ayrı log dosyası yok.
  docker logs -n 255 -f "$CONTAINER"
}

case "$1" in
  build)  build ;;
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  log)    log ;;
  *)      echo "Kullanım: $0 {build|start|stop|status|log}"; exit 1 ;;
esac
