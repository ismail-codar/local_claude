---
title: TripoSplat
emoji: 👁
colorFrom: purple
colorTo: blue
sdk: gradio
sdk_version: 6.15.2
python_version: '3.12'
app_file: app.py
pinned: false
license: mit
---

Check out the configuration reference at https://huggingface.co/docs/hub/spaces-config-reference

---

## uv ile Yerel Kurulum ve Çalıştırma

Aşağıdaki komutlar sırayla bu klasörde (`triposplat/`) çalıştırılır.

```sh
# 1) Bu klasöre geç
cd triposplat

# 2) Python 3.12 ile sanal ortam oluştur (.venv)
uv venv --python 3.12

# 3) Ortamı aktive et
source .venv/bin/activate        # Linux / WSL
# . .venv/Scripts/activate       # Windows (Git Bash) — yukarıdaki yerine

# 4) requirements.txt bağımlılıklarını kur
uv pip install -r requirements.txt

# 5) Checkpoint indirme için CLI (app.py içinde "hf download" çağrılır)
#    Not: ZeroGPU'ya ait `spaces` paketi YEREL GPU'da gerekmez; app.py kurulu
#    değilse @spaces.GPU dekoratörünü otomatik no-op'a düşürür.
uv pip install "huggingface_hub[cli]"

# 6) GPU için CUDA'lı torch (CUDA 12.4 örneği; sürücüne göre cu121/cu118 seç)
uv pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124

# 7) Sunucuyu başlat (checkpoint'ler ilk açılışta ckpts/ altına otomatik iner)
./cli.sh start

# Log'u canlı izle
./cli.sh log

# Durum / durdurma
./cli.sh status
./cli.sh stop
```

Uygulama `127.0.0.1:7860`'a bind eder. Dışarıdan erişim Caddy üzerinden:
`caddy-server/cli.sh refresh` çalıştırıldıktan sonra **http://localhost:7998/**

> Not: Activate etmeden `uv run python app.py` ile de çalıştırılabilir; ancak
> `cli.sh` arka plan/PID yönetimi sağladığı için yukarıdaki akış önerilir.

