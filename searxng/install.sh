curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Create the environment and configuration directories
mkdir -p ./searxng/core-config/
cd ./searxng/

# Fetch the latest compose template
curl -fsSL \
    -O https://raw.githubusercontent.com/searxng/searxng/master/container/docker-compose.yml \
    -O https://raw.githubusercontent.com/searxng/searxng/master/container/.env.example

cp -i .env.example .env

# nano or your preferred text editor...
# nano .env # port 8002

docker compose up -d
docker compose down

# core-config/setting.yml
# search:
#   formats:
#     - html
#     - json

# curl 'http://localhost:8080/search?q=test&format=json'