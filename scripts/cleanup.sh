#!/usr/bin/env bash
# Emergency disk cleanup for the Art Bridge VM.
# Run via SSH when the disk is full and CI/CD deployments are blocked:
#
#   ssh ubuntu@<vm> 'bash /home/ubuntu/rp9/infra/scripts/cleanup.sh'
#
set -e

echo "=== Disk before cleanup ==="
df -h /

echo ""
echo "=== Docker disk usage ==="
sudo docker system df

echo ""
echo "=== Removing stopped containers ==="
sudo docker container prune -f

echo ""
echo "=== Removing ALL unused images (including build stages such as gradle:8.10-jdk21) ==="
sudo docker image prune -a -f

echo ""
echo "=== Removing ALL BuildKit cache ==="
sudo docker builder prune -a -f

echo ""
echo "=== Removing unused Docker networks ==="
sudo docker network prune -f

echo ""
echo "=== Rotating system journal logs (keeping last 100 MB) ==="
sudo journalctl --vacuum-size=100M

echo ""
echo "=== Cleaning APT package cache ==="
sudo apt-get clean

echo ""
echo "=== Disk after cleanup ==="
df -h /

echo ""
echo "=== Docker disk usage after ==="
sudo docker system df
