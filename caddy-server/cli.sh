#!/bin/sh
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Her şey PWD (script klasörü) içinde
CADDYFILE="$SCRIPT_DIR/Caddyfile"
ACCESS_LOG="$SCRIPT_DIR/access.log"   # Caddyfile içindeki 'output file access.log'
RUN_LOG="$SCRIPT_DIR/caddy.log"       # caddy çalışma zamanı stdout/stderr (hatalar dahil)
PID_FILE="$SCRIPT_DIR/caddy.pid"

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
    if is_running; then
        echo "Caddy zaten çalışıyor (PID $(cat "$PID_FILE"))."
        return
    fi
    if [ ! -f "$CADDYFILE" ]; then
        echo "Caddyfile bulunamadı: $CADDYFILE" >&2
        exit 1
    fi
    cd "$SCRIPT_DIR" || exit 1
    $SUDO caddy validate --config "$CADDYFILE" || exit 1
    # Alt kabuk kendi PID'ini yazar, sonra caddy'yi exec ile yerine koyar
    # => PID_FILE gerçek caddy sürecini gösterir (sudo ile bile).
    $SUDO sh -c "echo \$\$ > '$PID_FILE'; exec caddy run --config '$CADDYFILE' >> '$RUN_LOG' 2>&1" &
    sleep 1
    if is_running; then
        echo "Caddy başlatıldı (PID $(cat "$PID_FILE"))."
        echo "  Çalışma logu: $RUN_LOG"
        echo "  Erişim logu : $ACCESS_LOG"
    else
        echo "Caddy başlatılamadı. Log: $RUN_LOG" >&2
        $SUDO tail -n 30 "$RUN_LOG" 2>/dev/null
        exit 1
    fi
}

stop() {
    if ! is_running; then
        echo "Caddy çalışmıyor."
        rm -f "$PID_FILE"
        return
    fi
    pid="$(cat "$PID_FILE")"
    $SUDO kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5; do
        is_running || break
        sleep 1
    done
    if is_running; then
        $SUDO kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
    echo "Caddy durduruldu."
}

status() {
    if is_running; then
        echo "Caddy çalışıyor (PID $(cat "$PID_FILE"))."
    else
        echo "Caddy çalışmıyor."
    fi
}

refresh() {
    if [ ! -f "$CADDYFILE" ]; then
        echo "Caddyfile bulunamadı: $CADDYFILE" >&2
        exit 1
    fi
    cd "$SCRIPT_DIR" || exit 1
    $SUDO caddy validate --config "$CADDYFILE" || exit 1
    if is_running; then
        # Çalışan süreci yeni config ile yumuşak yeniden yükle
        $SUDO kill -USR1 "$(cat "$PID_FILE")" 2>/dev/null \
            && echo "Caddy reload sinyali gönderildi (SIGUSR1)." \
            || { echo "Reload başarısız, yeniden başlatılıyor..."; stop; start; }
    else
        echo "Caddy çalışmıyor, başlatılıyor..."
        start
    fi
}

log() {
    echo "Hangi log türünü görmek istersiniz?"
    echo "  1) çalışma logu / hatalar ($RUN_LOG)"
    echo "  2) access log              ($ACCESS_LOG)"
    echo "  3) çalışma logunu canlı izle (tail -f)"
    read -rp "Seçim [1-3]: " choice

    case "$choice" in
        1)
            if [ -f "$RUN_LOG" ]; then
                $SUDO tail -n 200 "$RUN_LOG"
            else
                echo "Çalışma logu bulunamadı: $RUN_LOG"
            fi
            ;;
        2)
            if [ -f "$ACCESS_LOG" ]; then
                $SUDO tail -n 200 "$ACCESS_LOG"
            else
                echo "Access log bulunamadı: $ACCESS_LOG"
                echo "Caddyfile içinde 'log' direktifi tanımlı mı kontrol edin."
            fi
            ;;
        3)
            $SUDO tail -f "$RUN_LOG"
            ;;
        *)
            echo "Geçersiz seçim: $choice" >&2
            exit 1
            ;;
    esac
}

usage() {
    cat <<EOF
Kullanım: $0 <komut>

Tüm config ve loglar bu klasörde tutulur: $SCRIPT_DIR

Komutlar:
  start    Caddy'yi yerel Caddyfile ile başlatır (arka planda)
  stop     Caddy'yi durdurur
  status   Çalışma durumunu gösterir
  refresh  Caddyfile'ı doğrular ve çalışan süreci reload eder
  log      Log türünü sorar ve gösterir
EOF
}

cmd="${1:-}"
case "$cmd" in
    start)   start ;;
    stop)    stop ;;
    status)  status ;;
    refresh) refresh ;;
    log)     log ;;
    ""|-h|--help) usage ;;
    *)
        echo "Bilinmeyen komut: $cmd" >&2
        usage
        exit 1
        ;;
esac
