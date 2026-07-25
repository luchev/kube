#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a K3s master with tinyproxy for IPv6 workers.
# Writes the proxy IP to data/bootstrap-proxy-list.
# Usage: ./bootstrap-master.sh <master-ip>
# Example: ./bootstrap-master.sh 89.167.78.168

IP="${1:?Usage: $0 <master-ip>}"
DATA="$(dirname "$0")/data/bootstrap-proxy-list"

echo "==> Installing K3s server"
ssh "root@$IP" "
  if ! command -v k3s &>/dev/null; then
    curl -sfL https://get.k3s.io | sh -
  fi
"

echo "==> Installing tinyproxy"
ssh "root@$IP" "
  apt-get update -qq && apt-get install -y -qq tinyproxy
  sed -i '/^\s*Allow /d' /etc/tinyproxy/tinyproxy.conf
  systemctl restart tinyproxy
"

echo "==> Detecting master IPv6"
IPV6=$(ssh "root@$IP" "ip -6 addr show scope global | grep -oP '(?<=inet6 )[\da-f:]+' | head -1" || true)
if [ -n "$IPV6" ]; then
  mkdir -p "$(dirname "$DATA")"
  if ! grep -qF "$IPV6" "$DATA" 2>/dev/null; then
    echo "$IPV6" >> "$DATA"
    echo "Added $IPV6 to $DATA"
  else
    echo "$IPV6 already in $DATA"
  fi
else
  echo "No global IPv6 found. Add manually to $DATA."
fi
