```sh
curl http://10.198.15.173:8000/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "embeddinggemma-300m-GGUF",
    "input": "Merhaba dünya"
  }'
```
---
```sh
curl http://10.198.15.173:8000/v1/chat/completions\
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.6-35B-A3B-MTP-GGUF",
    "messages": [
      {
        "role": "user",
        "content": "Merhaba dünya!"
      }
    ]
  }'
```

docker exec -it local-ai bash

/backends/cuda13-vllm/venv/bin/python -c "import vllm; print(vllm.__version__); print(vllm.__file__)"
/backends/cuda13-vllm/venv/bin/python -c "from vllm.transformers_utils.tokenizer import get_tokenizer; print('OK')"