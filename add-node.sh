#!/usr/bin/env bash
set -euo pipefail

# Join a new K3s node (handles IPv6-only nodes via master's tinyproxy).
# Reads proxy from data/bootstrap-proxy-list, fetches token via master's IPv4.
# Usage: ./add-node.sh <new-node-ip> <master-ipv4>
# Example: ./add-node.sh 2a01:4f9:c014:4e9d::2 89.167.78.168

NEW="${1:?Usage: $0 <new-node-ip> <master-ipv4>}"
MASTER_IPV4="${2:?Usage: $0 <new-node-ip> <master-ipv4>}"
PROXY_FILE="$(dirname "$0")/data/bootstrap-proxy-list"

if [ ! -f "$PROXY_FILE" ] || [ ! -s "$PROXY_FILE" ]; then
  echo "Error: $PROXY_FILE empty or missing. Run bootstrap-master.sh first."
  exit 1
fi

MASTER_IPV6=$(head -1 "$PROXY_FILE")
PROXY="http://[$MASTER_IPV6]:8888"

echo "==> Fetching token from master (via IPv4 $MASTER_IPV4)"
TOKEN=$(ssh "root@$MASTER_IPV4" cat /var/lib/rancher/k3s/server/node-token)

echo "==> Installing K3s worker on $NEW"
CMD="
export HTTP_PROXY=$PROXY HTTPS_PROXY=$PROXY NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,$MASTER_IPV6
NODE_IP=\$(ip -4 addr show enp7s0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
if [ -z \"\$NODE_IP\" ]; then NODE_IP=\$(ip -4 addr show eth0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p'); fi
curl -sfL -x $PROXY https://get.k3s.io | K3S_URL=https://[$MASTER_IPV6]:6443 K3S_TOKEN=$TOKEN INSTALL_K3S_EXEC='--node-ip '\$NODE_IP' --flannel-iface enp7s0' sh -
"
ssh "root@$NEW" "$CMD"

echo "==> Done. Verify: kubectl get nodes"
