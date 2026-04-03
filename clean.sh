sudo apt clean 
sudo apt autoclean
sudo apt autoremove -y 
rm -rf ~/.cache/*
docker system prune -a --volumes
sudo journalctl --vacuum-time=7d
sudo rm -rf /tmp/*

df -h