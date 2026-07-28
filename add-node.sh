#!/usr/bin/env bash
set -euo pipefail

# Join a new K3s worker node via IPIP tunnel.
# The tunnel gives the worker routable IPv4 through the master's NAT.
# Usage: ./add-node.sh <new-node-ip> <master-ipv4> <master-ipv6>
# Example: ./add-node.sh 2a01:4f9:c014:4e9d::2 89.167.78.168 2a01:4f9:c014:4e9d::1

NEW="${1:?Usage: $0 <new-node-ip> <master-ipv4> <master-ipv6>}"
MASTER_IPV4="${2}"
MASTER_IPV6="${3}"
TUNNEL_SCRIPT="$(dirname "$0")/scripts/node-network-setup.sh"

echo "==> Fetching token from master (via IPv4 $MASTER_IPV4)"
TOKEN=$(ssh "root@$MASTER_IPV4" cat /var/lib/rancher/k3s/server/node-token)

echo "==> Detecting worker IPv6"
WORKER_IPV6=$(ssh "root@$NEW" "ip -6 addr show scope global | grep -oP '(?<=inet6 )[\da-f:]+' | head -1" || true)
if [ -z "$WORKER_IPV6" ]; then
  echo "ERROR: no global IPv6 found on worker. Tunnel requires IPv6 connectivity between nodes."
  exit 1
fi

echo "==> Setting up IPIP tunnel on master → $WORKER_IPV6"
ssh "root@$MASTER_IPV4" "
# Install script if not already there
if [ ! -f /usr/local/bin/node-network-setup.sh ]; then
cat > /usr/local/bin/node-network-setup.sh << 'SCRIPT'
$(cat "$TUNNEL_SCRIPT")
SCRIPT
chmod +x /usr/local/bin/node-network-setup.sh
fi

# Create or update systemd service for this worker's tunnel
# Note: for multiple workers, each gets tun0..tunN — currently single-worker
cat > /etc/systemd/system/ipip-tunnel.service << 'SERVICE'
[Unit]
Description=IPIP tunnel for worker $WORKER_IPV6
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/node-network-setup.sh --master $WORKER_IPV6
ExecStop=ip link del tun0

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable ipip-tunnel
/usr/local/bin/node-network-setup.sh --master $WORKER_IPV6
"

echo "==> Setting up IPIP tunnel on worker $NEW → $MASTER_IPV6"
ssh "root@$NEW" "
cat > /usr/local/bin/node-network-setup.sh << 'SCRIPT'
$(cat "$TUNNEL_SCRIPT")
SCRIPT
chmod +x /usr/local/bin/node-network-setup.sh

cat > /etc/systemd/system/ipip-tunnel.service << 'SERVICE'
[Unit]
Description=IPIP tunnel to master $MASTER_IPV6
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/node-network-setup.sh --worker $MASTER_IPV4 $MASTER_IPV6
ExecStop=ip link del tun0

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable ipip-tunnel
/usr/local/bin/node-network-setup.sh --worker $MASTER_IPV4 $MASTER_IPV6
"

echo "==> Verifying tunnel (ping 8.8.8.8 via tunnel)"
ssh "root@$NEW" "ping -c 1 -W 3 8.8.8.8"

echo "==> Installing K3s worker on $NEW"
NODE_IFACE=$(ssh "root@$NEW" "ip -4 addr show enp7s0 2>/dev/null && echo enp7s0 || echo eth0")
ssh "root@$NEW" "
export INSTALL_K3S_SKIP_START=true  # we'll start after configuring
curl -sfL https://get.k3s.io | K3S_URL=https://10.0.0.2:6443 K3S_TOKEN=$TOKEN sh -

# Remove any proxy leftovers from the env file
sed -i '/^HTTP_PROXY=/d' /etc/systemd/system/k3s-agent.service.env 2>/dev/null || true
sed -i '/^HTTPS_PROXY=/d' /etc/systemd/system/k3s-agent.service.env 2>/dev/null || true
sed -i '/^NO_PROXY=/d' /etc/systemd/system/k3s-agent.service.env 2>/dev/null || true

systemctl daemon-reload
systemctl restart k3s-agent
"

echo "==> Done. Verify with: kubectl get nodes"
echo "    The IPIP tunnel will persist across reboots (systemd: ipip-tunnel.service)"
