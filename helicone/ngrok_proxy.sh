echo " curl http://localhost:4040/api/tunnels"
nohup ngrok http 7999 >/dev/null 2>&1 &