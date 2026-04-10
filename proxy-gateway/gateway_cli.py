#!/usr/bin/env python3
"""
gateway – CLI
─────────────
Kullanım:
  gateway start   [seçenekler]
  gateway stop
  gateway status
  gateway --help

Ortam değişkenleri (ya da .env dosyası):
  LANGFUSE_PUBLIC_KEY
  LANGFUSE_SECRET_KEY
  LANGFUSE_HOST          (varsayılan: https://cloud.langfuse.com)
  LANGFUSE_CURL_LOG      (boş/kapalı, masked, full, true, 1)
  GATEWAY_TARGET_URL     (varsayılan: http://localhost:8001)
  GATEWAY_PORT           (varsayılan: 8010)
"""

import argparse
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

# PID dosyasının konumu
TMP_DIR = Path(tempfile.gettempdir())
PID_FILE = Path(os.getenv("GATEWAY_PID_FILE", str(TMP_DIR / "proxy_gateway.pid")))
LOG_FILE = Path(os.getenv("GATEWAY_LOG_FILE", str(TMP_DIR / "proxy_gateway.log")))


# ──────────────────────────────────────────────
# Yardımcı: .env yükle (python-dotenv gerektirmez)
# ──────────────────────────────────────────────


def _load_dotenv(env_path: Path = Path(".env")):
    if not env_path.exists():
        return
    with env_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


# ──────────────────────────────────────────────
# start komutu
# ──────────────────────────────────────────────


def cmd_start(args):
    _load_dotenv()

    if PID_FILE.exists():
        pid = PID_FILE.read_text().strip()
        # İşlem hâlâ çalışıyor mu?
        try:
            os.kill(int(pid), 0)
            print(f"✗  Gateway zaten çalışıyor  (PID {pid})")
            return 1
        except (ProcessLookupError, ValueError):
            PID_FILE.unlink(missing_ok=True)

    target = args.target or os.getenv("GATEWAY_TARGET_URL", "http://localhost:8001")
    port = args.port or int(os.getenv("GATEWAY_PORT", "8010"))
    lf_pub = args.lf_public_key or os.getenv("LANGFUSE_PUBLIC_KEY", "")
    lf_sec = args.lf_secret_key or os.getenv("LANGFUSE_SECRET_KEY", "")
    lf_host = args.lf_host or os.getenv("LANGFUSE_HOST", "https://cloud.langfuse.com")
    lf_curl_log = os.getenv("LANGFUSE_CURL_LOG", "")
    verbose = args.verbose

    # Çalışacak Python betiği
    runner_src = _make_runner(
        target=target,
        port=port,
        lf_pub=lf_pub,
        lf_sec=lf_sec,
        lf_host=lf_host,
        lf_curl_log=lf_curl_log,
        verbose=verbose,
    )
    runner_path = Path("/tmp/_gateway_runner.py")
    runner_path.write_text(runner_src)

    if args.foreground:
        # Ön planda çalıştır (Ctrl+C ile dur)
        print(f"▶  Gateway başlatılıyor  :{port} → {target}")
        _print_config(port, target, lf_host, lf_pub, lf_curl_log, verbose)
        os.execv(sys.executable, [sys.executable, str(runner_path)])
    else:
        # Arka planda (daemon) çalıştır
        with open(LOG_FILE, "a") as log:
            proc = subprocess.Popen(
                [sys.executable, str(runner_path)],
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        PID_FILE.write_text(str(proc.pid))
        print(f"▶  Gateway başlatıldı    PID={proc.pid}")
        _print_config(port, target, lf_host, lf_pub, lf_curl_log, verbose)
        print(f"   Log → {LOG_FILE}")
    return 0


# ──────────────────────────────────────────────
# stop komutu
# ──────────────────────────────────────────────


def cmd_stop(_args):
    if not PID_FILE.exists():
        print("✗  Gateway çalışmıyor (PID dosyası bulunamadı)")
        return 1

    pid_str = PID_FILE.read_text().strip()
    try:
        pid = int(pid_str)
        os.kill(pid, signal.SIGTERM)
        PID_FILE.unlink(missing_ok=True)
        print(f"■  Gateway durduruldu  (PID {pid})")
        return 0
    except (ValueError, ProcessLookupError):
        print(f"✗  PID {pid_str} bulunamadı, PID dosyası temizlendi")
        PID_FILE.unlink(missing_ok=True)
        return 1
    except PermissionError:
        print(f"✗  PID {pid_str} için yetki yok")
        return 1


# ──────────────────────────────────────────────
# status komutu
# ──────────────────────────────────────────────


def cmd_status(_args):
    if not PID_FILE.exists():
        print("●  Gateway çalışmıyor")
        return 1
    pid_str = PID_FILE.read_text().strip()
    try:
        pid = int(pid_str)
        os.kill(pid, 0)
        print(f"●  Gateway çalışıyor  PID={pid}")
        print(f"   Log → {LOG_FILE}")
        return 0
    except (ProcessLookupError, ValueError):
        print(f"●  Gateway çalışmıyor (stale PID {pid_str})")
        PID_FILE.unlink(missing_ok=True)
        return 1


# ──────────────────────────────────────────────
# Yardımcılar
# ──────────────────────────────────────────────


def _print_config(port, target, lf_host, lf_pub, lf_curl_log, verbose):
    lf_status = f"✓ {lf_host}" if lf_pub else "✗ devre dışı (LANGFUSE_PUBLIC_KEY yok)"
    print(f"   Proxy   :  :{port} → {target}")
    print(f"   Langfuse: {lf_status}")

    if lf_pub:
        curl_status = lf_curl_log or "kapalı"
        print(f"   LF Curl :  {curl_status}")

    if verbose:
        print("   Verbose :  açık")


def _make_runner(target, port, lf_pub, lf_sec, lf_host, lf_curl_log, verbose) -> str:
    """Uvicorn'u başlatan küçük bir Python betiği oluştur."""
    return textwrap.dedent(f"""\
        import sys, os
        # Bu dosyanın yanındaki proxy_gateway modülünü bul
        _this = os.path.dirname(os.path.abspath(__file__))
        # Kurulum dizinini de ara
        _install = os.path.join(os.path.dirname(os.path.abspath(
            sys.modules.get('__spec__', type('', (), {{'origin': __file__}})()).origin or __file__
        )), '..')
        for _p in [_this, os.path.expanduser('~/.local/lib/gateway')]:
            if _p not in sys.path:
                sys.path.insert(0, _p)

        from proxy_gateway import create_app
        import uvicorn

        app = create_app(
            target_url={target!r},
            langfuse_public_key={lf_pub!r},
            langfuse_secret_key={lf_sec!r},
            langfuse_host={lf_host!r},
            langfuse_curl_log={lf_curl_log!r},
            verbose={verbose!r},
        )

        uvicorn.run(app, host="0.0.0.0", port={port}, log_level="warning")
    """)


# ──────────────────────────────────────────────
# Argparse
# ──────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="gateway",
        description="FastAPI proxy/gateway  :8010 → :8001  +  Langfuse loglama",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Örnekler:
              gateway start
              gateway start --port 8010 --target http://localhost:8001 --verbose
              gateway start --lf-public-key pk-xxx --lf-secret-key sk-xxx
              gateway start --foreground
              gateway stop
              gateway status
        """),
    )
    sub = parser.add_subparsers(dest="command", metavar="KOMUT")

    # ── start ──
    p_start = sub.add_parser("start", help="Gateway'i başlat")
    p_start.add_argument(
        "--port",
        type=int,
        default=None,
        metavar="PORT",
        help="Dinlenecek port (varsayılan: 8010 / GATEWAY_PORT)",
    )
    p_start.add_argument(
        "--target",
        default=None,
        metavar="URL",
        help="Hedef URL (varsayılan: http://localhost:8001 / GATEWAY_TARGET_URL)",
    )
    p_start.add_argument(
        "--lf-public-key",
        dest="lf_public_key",
        default=None,
        metavar="KEY",
        help="Langfuse public key (ya da LANGFUSE_PUBLIC_KEY)",
    )
    p_start.add_argument(
        "--lf-secret-key",
        dest="lf_secret_key",
        default=None,
        metavar="KEY",
        help="Langfuse secret key (ya da LANGFUSE_SECRET_KEY)",
    )
    p_start.add_argument(
        "--lf-host",
        dest="lf_host",
        default=None,
        metavar="URL",
        help="Langfuse host (varsayılan: https://cloud.langfuse.com)",
    )
    p_start.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Her isteği stdout'a yazdır",
    )
    p_start.add_argument(
        "--foreground",
        "-f",
        action="store_true",
        help="Arka planda değil, ön planda çalıştır",
    )

    # ── stop ──
    sub.add_parser("stop", help="Çalışan gateway'i durdur")

    # ── status ──
    sub.add_parser("status", help="Gateway durumunu göster")

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "start":
        sys.exit(cmd_start(args))
    elif args.command == "stop":
        sys.exit(cmd_stop(args))
    elif args.command == "status":
        sys.exit(cmd_status(args))
    else:
        parser.print_help()
        sys.exit(0)


if __name__ == "__main__":
    main()
