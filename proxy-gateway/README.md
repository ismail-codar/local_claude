# proxy-gateway

`:8010` → `:8001` şeffaf proxy + [Langfuse](https://cloud.langfuse.com) loglama.

## Kurulum

```bash
pip install -e .
# ya da doğrudan:
pip install fastapi uvicorn[standard] httpx
```

## Yapılandırma

```bash
cp .env.example .env
# .env dosyasını düzenle
```

ya da CLI argümanlarıyla:

```bash
gateway start \
  --port 8010 \
  --target http://localhost:8001 \
  --lf-public-key pk-lf-xxx \
  --lf-secret-key sk-lf-xxx

gateway start --foreground --verbose
```

## Kullanım

```bash
# Arka planda başlat (daemon)
gateway start

# Ön planda başlat (Ctrl+C ile dur)
gateway start --foreground

# Verbose mod
gateway start --verbose --foreground

# Durdur
gateway stop

# Durum
gateway status
```

## Nasıl çalışır?

```
İstemci → :8010 (Gateway)  ──────→  :8001 (Hedef)
                      ↓
               Langfuse Cloud
```

1. Gelen istek `:8010`'da yakalanır.
2. Tüm başlıklar, metod, path ve body **eksiksiz** `:8001`'e iletilir.
3. Streaming (`"stream": true`) istekler SSE olarak chunk-by-chunk proxy edilir.
4. İstek + yanıt çifti arka planda Langfuse'a **generation** olarak gönderilir.
5. Yanıt istemciye döndürülür (gecikme eklenmez).

## Langfuse Entegrasyonu

Her proxy isteği için Langfuse'a şunlar loglanır:

| Alan | İçerik |
|------|--------|
| `name` | `METHOD /path` |
| `model` | Request body'deki `model` alanı |
| `input` | `messages` dizisi veya tüm request body |
| `output` | Response body (`choices` veya ham) |
| `usage` | `prompt_tokens`, `completion_tokens`, `total_tokens` |
| `metadata` | status_code, duration_ms, port bilgileri |

OpenAI API formatı dışındaki istekler de ham JSON olarak loglanır.
