# dflash-server

DFlash speculative decoding server wrapper. [z-lab-ai/dflash](https://github.com/z-lab-ai/dflash) projesini VLLM üzerinde çalıştırmak için tasarlanmıştır. NVIDIA L40S (48 GB VRAM) için optimize edilmiştir.

---

## 📋 Gereksinimler

- **Python**: ≥ 3.11
- **uv**: ≥ 0.4.0 ([Kurulum Rehberi](https://docs.astral.sh/uv/getting-started/installation/))
- **İşletim Sistemi**: Linux (önerilen), macOS/Windows deneysel
- **GPU**: NVIDIA L40S veya benzeri Ada Lovelace mimarisi (48 GB VRAM önerilir)
- **CUDA**: ≥ 12.1 (NVIDIA sürücüleri güncel olmalı)

---

## 🚀 Hızlı Başlangıç

### 1. Depoyu Klonlayın ve Dizine Girin

```bash
git clone https://github.com/z-lab-ai/dflash.git
cd dflash
```

### 2. Bağımlılıkları Kurun (uv ile)

```bash
# uv ile sanal ortam oluştur ve bağımlılıkları yükle
uv sync
```

> 💡 `uv sync` komutu otomatik olarak `.venv/` dizininde sanal ortam oluşturur ve `pyproject.toml`'daki bağımlılıkları yükler.

### 3. DFlash CLI'yi Hazırlayın

```bash
# dflash komutunu kullanılabilir hale getir
dflash install
```

> Bu adım, dflash repo'sunu klonlar, modelleri indirir ve çalışma ortamını hazırlar.

### 4. Server'ı Başlatın

```bash
# VLLM server'ı başlat (arka planda çalışır)
dflash run
```

Server başladığında aşağıdaki çıktıyı göreceksiniz:
```
Starting vLLM server …
Log: /path/to/dflash/logs/vllm_dflash_qwen35_35b_a3b.log
Model started. PID=12345
Monitor: tail -f /path/to/dflash/logs/vllm_dflash_qwen35_35b_a3b.log
```

### 5. Server Durumunu Kontrol Edin

```bash
dflash status
# Çıktı: Status: running  (PID=12345)
```

### 6. Server'ı Durdurun

```bash
dflash stop
```

---

## 🔧 Sanal Ortamı Manuel Aktive Etme (İsteğe Bağlı)

`dflash` CLI komutları `uv run` üzerinden çalıştığı için sanal ortamı manuel aktive etmeniz genellikle gerekmez. Ancak geliştirme yapacaksanız:

```bash
# Linux/macOS
source .venv/bin/activate

# Windows (PowerShell)
.venv\Scripts\Activate.ps1

# Windows (CMD)
.venv\Scripts\activate.bat
```

Aktivasyon sonrası doğrudan Python komutlarıyla da çalışabilirsiniz:
```bash
# Örnek: dflash.py'yi doğrudan çalıştırma
python dflash.py run
```

---

## ⚙️ Yapılandırma (Environment Değişkenleri)

Tüm ayarlar `dflash.py` içindeki `DEFAULTS` sözlüğünden gelir. Environment değişkenleri ile bu değerleri geçersiz kılabilirsiniz:

| Değişken | Varsayılan | Açıklama |
|----------|------------|----------|
| `BASE_MODEL` | `Qwen/Qwen3.5