# local_claude

---
izle
```sh
# Ağ arayüzlerinin (eth0/ens/enp) anlık RX/TX byte sayaçlarını 2 sn'de bir göster — trafik akışını izle
watch -n 2 "grep -E 'eth0|ens|enp' /proc/net/dev"
# local-ai container'ının disk boyutunu (yazılabilir katman + image) 5 sn'de bir izle
watch -n 5 'docker ps -s --filter name=local-ai --format "{{.Size}}"'
# HuggingFace model önbelleğindeki klasörlerin boyutunu 2 sn'de bir küçükten büyüğe sıralı göster — model indirme ilerlemesini izle
watch -n 2 'du -h --max-depth=1 ~/.cache/huggingface/hub | sort -h'
# Dinlenen (LISTEN) TCP portları arasında vllm süreçlerine ait olanları bul (port + PID)
sudo lsof -Pan -iTCP -sTCP:LISTEN | grep -i vllm
# Çalışan vllm süreçlerini listele; '[v]llm' deseni grep'in kendisini sonuçtan eler
ps aux | grep -i '[v]llm'
# Adında "vllm" geçen tüm süreçleri sonlandır (öldür)
pkill -f "vllm"
pkill -f "llama"
# Boru hattına gelen çıktıdan "vllm" geçen satırları büyük/küçük harf duyarsız filtrele
grep -i vllm

# kill app by prort
kill -9 $(lsof -t -i :3000)
# kill app by prorts
for port in 7999 8000 8001 8002 8003 8004 8005 8006 8007 8008 8009 8010; do
  lsof -t -i :"$port"
done | xargs -r kill -9
```


---
```sh
@'
{
  "model": "Qwen/Qwen3.6-27B-FP8",
  "messages": [
    {
      "role": "user",
      "content": "Merhaba dünya!"
    }
  ]
}
'@ | Set-Content -Encoding utf8 body.json

curl.exe http://10.198.15.173:8000/v1/chat/completions `
    -H "Content-Type: application/json" `
    --data-binary "@body.json"

```
---
```sh
@'
  {
    "model": "Qwen/Qwen3.6-27B-FP8",
    "messages": [
      {
        "role": "user",
        "content": "İstanbul'da hava bugün nasıl?"
      }
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Bir şehrin güncel hava durumunu döner",
          "parameters": {
            "type": "object",
            "properties": {
              "city": {
                "type": "string",
                "description": "Şehir adı, örn. İstanbul"
              }
            },
            "required": ["city"]
          }
        }
      }
    ],
    "tool_choice": "auto"
  }
'@ | Set-Content -Encoding utf8 tool_body.json

curl.exe http://10.198.15.173:8000/v1/chat/completions `
      -H "Content-Type: application/json" `
      --data-binary "@tool_body.json"

```