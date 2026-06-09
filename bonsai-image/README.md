---
title: Bonsai Image GPU
emoji: 🎨
colorFrom: green
colorTo: blue
sdk: docker
app_port: 7860
suggested_hardware: l40sx1
pinned: true
short_description: Run Bonsai-Image-4B models on GPU
models:
  - prism-ml/bonsai-image-ternary-4B-mlx-2bit
  - prism-ml/bonsai-image-ternary-4B-gemlite-2bit
  - prism-ml/bonsai-image-ternary-4B-unpacked
  - prism-ml/bonsai-image-binary-4B-mlx-1bit
  - prism-ml/bonsai-image-binary-4B-gemlite-1bit
  - prism-ml/bonsai-image-binary-4B-unpacked
---

# Bonsai Image Demo

- Ternary (1.58-bit)
- Binary (1-bit)

## Privacy

- **We do not log prompts or generated images.** Generation runs in-process and outputs are streamed back over HTTPS.
- The studio UI keeps your prompt history **in your browser's local storage only**. Clearing your browser cache erases it.
- Please do not submit sensitive, private, or confidential content in your prompts.

## Fair Use

Shared demo, shared across all visitors. Heavy load may queue requests. Please avoid bursts of automated traffic so everyone can try it.

---

## Yerel Kurulum ve Çalıştırma (docker + cli.sh)

Bu space **docker SDK**'lıdır (gradio değil): bir CUDA imajı derler, içinde
nginx + GPU backend'leri `:7860`'a bind eder. Bu yüzden `cli.sh` `python app.py`
yerine **docker container** yaşam döngüsünü yönetir (`triposplat/cli.sh` ile aynı
`start|stop|status|log` arayüzü + ek `build`).

### Ön koşullar
- Docker + **nvidia-container-toolkit** (GPU geçişi için `--gpus all`).
- Özel repo erişimi için bir **GitHub token** (`GH_TOKEN`). Dockerfile, derleme
  sırasında `github.com/PrismML-Eng/Bonsai-image-demo` reposunu BuildKit secret
  mount ile klonlar; token imaj layer'ına yazılmaz.

```sh
# 1) Bu klasöre geç
cd bonsai-image

# 2) GitHub token'ı ver (ikisinden biri)
export GH_TOKEN=ghp_xxx
# echo ghp_xxx > .gh_token        # alternatif: .gitignore'da, commit'lenmez

# 3) İmajı derle (model build sırasında inmez; ilk başlangıçta iner — SKIP_DOWNLOAD=1)
./cli.sh build

# 4) Başlat (GPU'lu container; model indirme + warmup birkaç dk sürer)
./cli.sh start

# Log'u canlı izle
./cli.sh log

# Durum / durdurma
./cli.sh status
./cli.sh stop
```

Container içeride `:7860`'a bind eder; host'ta varsayılan **`:8011`** portuna
maplenir. Dışarıdan erişim Caddy üzerinden:
`caddy-server/cli.sh refresh` çalıştırıldıktan sonra **http://localhost:7997/**

### Override edilebilir env değişkenleri
| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `BONSAI_PORT` | `8011` | Host port (`:7860`'a maplenir) |
| `BONSAI_HOST` | `0.0.0.0` | Bind adresi |
| `BONSAI_IMAGE` | `bonsai-image:local` | Docker imaj etiketi |
| `BONSAI_CONTAINER` | `bonsai-image` | Container adı |
| `DASHBOARD_KEY` | `bonsai` | Dashboard basic-auth parolası |
| `BONSAI_WARMUP_SHAPES` | `512x512,1024x1024` | Boot'ta warmlanan çözünürlükler |
| `GH_TOKEN` | — | Build için GitHub token (ya da `.gh_token`) |

> Not: `app_port: 7860` HF Space tarafında geçerlidir; yerelde container içi
> port aynı kalır, sadece host map'i `BONSAI_PORT` ile değişir.
