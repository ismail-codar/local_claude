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
# Boru hattına gelen çıktıdan "vllm" geçen satırları büyük/küçük harf duyarsız filtrele
grep -i vllm
```
