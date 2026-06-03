if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

$SUDO apt update
$SUDO apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | $SUDO gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

$SUDO apt update
$SUDO apt install -y caddy

# Sistem genelindeki caddy servisini kullanmıyoruz; config ve loglar PWD'de.
# Port 80 çakışmasını önlemek için systemd servisini durdur/devre dışı bırak.
$SUDO systemctl disable --now caddy 2>/dev/null || true

caddy version
echo "Kurulum tamam. Başlatmak için: ./cli.sh start"
