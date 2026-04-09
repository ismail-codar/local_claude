echo "curl -s http://127.0.0.1:4040/api/tunnels"
nohup ngrok http 8010 >/dev/null 2>&1 &