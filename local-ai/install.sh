docker run -ti --name local-ai \
  -p 8000:8080 \
  --gpus all \
  -v "$PWD/:/models" \
  -v "$PWD/data:/data" \
  localai/localai:latest-gpu-nvidia-cuda-13