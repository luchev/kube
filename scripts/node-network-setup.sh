#!/usr/bin/env bash
set -euo pipefail

# Configure IPIP tunnel + NAT for Hetzner worker nodes behind CGNAT.
# Run with: --master on the master node, --worker on the worker node.
# The tunnel creates a routable IPv4 path for workers that have no default route.

usage() { echo "Usage: $0 --master <tunnel-peer-ipv6> | --worker <master-ipv4> <tunnel-peer-ipv6>"; exit 1; }

ROLE="${1:?$(usage)}"
shift

case "$ROLE" in
  --master)
    PEER_V6="${1:?$(usage)}"
    # Create tunnel if not exists
    if ! ip link show tun0 &>/dev/null; then
      ip tunnel add tun0 mode ipip local any remote "$PEER_V6"
      ip addr add 172.16.0.1/30 dev tun0
      ip link set tun0 up
    fi
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    # NAT for tunnel subnet
    iptables -t nat -C POSTROUTING -s 172.16.0.0/30 -o eth0 -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s 172.16.0.0/30 -o eth0 -j MASQUERADE
    iptables -C FORWARD -i tun0 -o eth0 -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT
    iptables -C FORWARD -i eth0 -o tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i eth0 -o tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT
    echo "Master tunnel configured. Peer: $PEER_V6"
    ;;
  --worker)
    MASTER_IP="${1:?$(usage)}"
    PEER_V6="${2:?$(usage)}"
    # Create tunnel if not exists
    if ! ip link show tun0 &>/dev/null; then
      ip tunnel add tun0 mode ipip local any remote "$PEER_V6"
      ip addr add 172.16.0.2/30 dev tun0
      ip link set tun0 up
    fi
    # Default route via tunnel (metric 10 so it won't override a real default)
    if ! ip route show | grep -q 'default via 172.16.0.1'; then
      ip route add default via 172.16.0.1 metric 10
    fi
    echo "Worker tunnel configured. Master: $MASTER_IP ($PEER_V6)"
    ;;
  *)
    usage
    ;;
esac
