```sh
curl http://10.198.15.173:8000/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "embeddinggemma-300m-GGUF",
    "input": "Merhaba dünya"
  }'
```