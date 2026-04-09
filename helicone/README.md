# LiteLLM Proxy

LiteLLM proxy server kurulumu.

## .env
```sh
HELICONE_API_KEY=sk-helicone-...
```

## Kullanim
```sh
uv init
uv venv
uv sync
sh start.sh
```

## Test
```sh
curl http://127.0.0.1:8010/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer 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" \
  -d '{
    "model": "Wrench-35B-A3B-Q4_K_M-GGUF.gguf",
    "messages": [
      {"role": "user", "content": "Merhaba"}
    ]
  }'
```

## İzleme
lsof -i :8010