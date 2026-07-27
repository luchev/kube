#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a K3s master node with IPIP tunnel support for workers behind CGNAT.
# Usage: ./bootstrap-master.sh <master-ip>
# Example: ./bootstrap-master.sh 89.167.78.168

IP="${1:?Usage: $0 <master-ip>}"
SCRIPTS="$(dirname "$0")/scripts"

echo "==> Installing K3s server"
ssh "root@$IP" "
  if ! command -v k3s &>/dev/null; then
    curl -sfL https://get.k3s.io | sh -
  fi
"

echo "==> Setting up IP forwarding and NAT for IPIP tunnel"
ssh "root@$IP" "
  sysctl -w net.ipv4.ip_forward=1
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ipforward.conf
  iptables -t nat -C POSTROUTING -s 172.16.0.0/30 -o eth0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 172.16.0.0/30 -o eth0 -j MASQUERADE
  iptables -C FORWARD -i tun0 -o eth0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
  iptables -C FORWARD -i eth0 -o tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i eth0 -o tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT
"

echo "==> Installing node-network-setup script and IPIP tunnel persistence"
# Copy the script and service to the master
ssh "root@$IP" "
cat > /usr/local/bin/node-network-setup.sh << 'SCRIPT'
$(cat "$SCRIPTS/node-network-setup.sh")
SCRIPT
chmod +x /usr/local/bin/node-network-setup.sh

cat > /etc/systemd/system/ipip-tunnel.service << 'SERVICE'
[Unit]
Description=IPIP tunnel for worker node internet access
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/node-network-setup.sh --master 2a01:4f8:1c18:65cc::1
ExecStop=ip link del tun0

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable ipip-tunnel

# Create the tunnel now if not already up
/usr/local/bin/node-network-setup.sh --master 2a01:4f8:1c18:65cc::1
"

echo "==> Installing tinyproxy (restricted to private IPs only)"
ssh "root@$IP" "
  apt-get update -qq && apt-get install -y -qq tinyproxy 2>/dev/null || true
  # Remove any existing Allow/Deny, then restrict to private ranges
  sed -i '/^\s*Allow /d' /etc/tinyproxy/tinyproxy.conf
  sed -i '/^\s*Deny /d' /etc/tinyproxy/tinyproxy.conf
  cat >> /etc/tinyproxy/tinyproxy.conf << 'ALLOW'

# Restricted to private IPs only (security: no open proxy)
Allow 127.0.0.0/8
Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16
ALLOW
  systemctl restart tinyproxy || true
"

echo "==> Detecting master IPv6"
IPV6=$(ssh "root@$IP" "ip -6 addr show scope global | grep -oP '(?<=inet6 )[\da-f:]+' | head -1" || true)
if [ -n "$IPV6" ]; then
  echo "Master IPv6: $IPV6"
  echo "Use ./add-node.sh <node-ip> $IP $IPV6 to add worker nodes."
else
  echo "No global IPv6 found. Workers will need manual tunnel peer address."
fi

echo "==> Done."
echo "    IPIP tunnel + NAT configured for worker internet access."
echo "    Run: ./add-node.sh <worker-ip> $IP <ipv6>   to add workers."
