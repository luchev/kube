#!/usr/bin/env bash
set -euo pipefail

# Join a new K3s worker node via IPIP tunnel over the Hetzner private network.
# The tunnel gives the worker a routable IPv4 path through the master's NAT.
# Usage: ./add-node.sh <new-node-ip> <master-public-ipv4>
# Example: ./add-node.sh 2a01:4f8:1c1e:7e37::1 89.167.78.168

NEW="${1:?Usage: $0 <new-node-ip> <master-public-ipv4>}"
MASTER_PUB="${2}"
TUNNEL_SCRIPT="$(dirname "$0")/scripts/node-network-setup.sh"

# CNPG scale-down/up helpers (git + Flux based — kubectl patches get reverted)
source "$(dirname "$0")/scripts/cnpg-scale-lib.sh"

echo "==> Fetching token from master (via public IPv4 $MASTER_PUB)"
TOKEN=$(ssh "root@$MASTER_PUB" cat /var/lib/rancher/k3s/server/node-token)

echo "==> Detecting private network IPs (Hetzner vSwitch 10.0.0.0/16)"
MASTER_PRIV4=$(ssh "root@$MASTER_PUB" "ip -4 addr show dev enp7s0 | grep -oP '(?<=inet )10\.\d+\.\d+\.\d+' | head -1")
WORKER_PRIV4=$(ssh "root@$NEW" "ip -4 addr show dev enp7s0 | grep -oP '(?<=inet )10\.\d+\.\d+\.\d+' | head -1")
if [ -z "$MASTER_PRIV4" ] || [ -z "$WORKER_PRIV4" ]; then
  echo "ERROR: both nodes must be attached to the Hetzner private network (enp7s0)"
  exit 1
fi

echo "==> Setting up IPIP tunnel on master → $WORKER_PRIV4"
ssh "root@$MASTER_PUB" "
cat > /usr/local/bin/node-network-setup.sh << 'SCRIPT'
$(cat "$TUNNEL_SCRIPT")
SCRIPT
chmod +x /usr/local/bin/node-network-setup.sh

# Create or update systemd service for this worker's tunnel
# Note: for multiple workers, each gets tun0..tunN — currently single-worker
cat > /etc/systemd/system/ipip-tunnel.service << 'SERVICE'
[Unit]
Description=IPIP tunnel for worker $WORKER_PRIV4
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/node-network-setup.sh --master $WORKER_PRIV4
ExecStop=ip link del tun0

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable ipip-tunnel
/usr/local/bin/node-network-setup.sh --master $WORKER_PRIV4
"

echo "==> Setting up IPIP tunnel on worker $NEW → $MASTER_PRIV4"
ssh "root@$NEW" "
cat > /usr/local/bin/node-network-setup.sh << 'SCRIPT'
$(cat "$TUNNEL_SCRIPT")
SCRIPT
chmod +x /usr/local/bin/node-network-setup.sh

cat > /etc/systemd/system/ipip-tunnel.service << 'SERVICE'
[Unit]
Description=IPIP tunnel to master $MASTER_PRIV4
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/node-network-setup.sh --worker $MASTER_PRIV4
ExecStop=ip link del tun0

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable ipip-tunnel
/usr/local/bin/node-network-setup.sh --worker $MASTER_PRIV4
" || { echo "ERROR: worker tunnel setup failed (exit $?)"; exit 1; }

echo "==> Verifying tunnel (ping 8.8.8.8 via tunnel)"
ssh "root@$NEW" "ping -c 1 -W 3 8.8.8.8" || {
  echo "ERROR: tunnel ping failed — worker cannot reach the internet via the tunnel"
  echo "       check: systemctl status ipip-tunnel on $NEW, ip addr show tun0, tunnel on master"
  exit 1
}

echo "==> Installing K3s worker on $NEW"
ssh "root@$NEW" "
export INSTALL_K3S_SKIP_START=true  # we'll start after configuring
# Advertise the vSwitch IP as node IP so flannel VXLAN uses legit vSwitch
# addresses (a tunnel IP here breaks cross-node pod traffic via anti-spoofing).
# flannel-iface is REQUIRED: without it flannel binds the default-route iface
# (tun0) and VXLAN packets get dropped by vSwitch anti-spoofing.
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << EOF
node-ip: $WORKER_PRIV4
flannel-iface: enp7s0
EOF
curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_PRIV4:6443 K3S_TOKEN=$TOKEN sh -

# Remove any proxy leftovers from the env file
sed -i '/^HTTP_PROXY=/d' /etc/systemd/system/k3s-agent.service.env 2>/dev/null || true
sed -i '/^HTTPS_PROXY=/d' /etc/systemd/system/k3s-agent.service.env 2>/dev/null || true
sed -i '/^NO_PROXY=/d' /etc/systemd/system/k3s-agent.service.env 2>/dev/null || true

systemctl daemon-reload
# restart, not start: after a drain the node object was deleted while the
# agent kept running; a plain start is a no-op on a running unit and the
# stale kubelet never re-registers. restart forces a fresh registration.
systemctl restart k3s-agent
" || { echo "ERROR: k3s agent install/start failed on $NEW (exit $?)"; exit 1; }

echo "==> Waiting for node (InternalIP $WORKER_PRIV4) to become Ready"
for i in $(seq 1 30); do
  if kubectl get nodes -o wide --no-headers 2>/dev/null | grep -q "^.*Ready.*$WORKER_PRIV4"; then
    echo "  node Ready (attempt $i)"
    break
  fi
  # Two phases: node not yet registered (agent starting) vs registered but not
  # Ready (CNI/tunnel still coming up). Showing which tells the user if it's a
  # registration problem or a network problem.
  if kubectl get nodes -o wide --no-headers 2>/dev/null | grep -q "$WORKER_PRIV4"; then
    status=$(kubectl get nodes -o wide --no-headers | grep "$WORKER_PRIV4" | awk '{print $2}')
    echo "  [$(date +%H:%M:%S)] registered, status: $status (attempt $i/30)"
  else
    echo "  [$(date +%H:%M:%S)] not registered yet (attempt $i/30)"
  fi
  sleep 5
done
if ! kubectl get nodes -o wide --no-headers | grep -q "$WORKER_PRIV4"; then
  echo "ERROR: node with InternalIP $WORKER_PRIV4 not registered after 150s"
  exit 1
fi
kubectl get nodes -o wide | grep "$WORKER_PRIV4"

# A node cordoned in a previous drain keeps unschedulable=true across re-joins;
# kubelet won't clear it. Uncordon (no-op if already schedulable).
NODE_NAME=$(kubectl get nodes -o wide --no-headers | awk -v ip="$WORKER_PRIV4" '$6 == ip {print $1}' | head -1)
[ -n "$NODE_NAME" ] || { echo "ERROR: cannot resolve node name for $WORKER_PRIV4"; exit 1; }
kubectl uncordon "$NODE_NAME"
echo "==> $NODE_NAME is schedulable (uncordoned)"

# If drain-node.sh scaled CNPG clusters down before this node was added,
# restore them now. Marker line: "<ns>/<cluster> <original-instances>".
if [ -s "$SCALE_MARKER" ]; then
  echo "==> Restoring CNPG clusters scaled down by a previous drain:"
  while read -r ns_cluster orig; do
    ns="${ns_cluster%/*}"
    cluster="${ns_cluster#*/}"
    manifest=$(cnpg_manifest "$cluster") || { echo "ERROR: no Flux manifest for CNPG cluster $cluster"; exit 1; }
    echo "==> Scaling $ns/$cluster back to $orig instance(s) (git + Flux)"
    cnpg_set_instances "$manifest" "$orig"
    cnpg_apply_scale "$manifest" "add-node: scale $cluster back to $orig instance(s) after $NODE_NAME joined"
    cnpg_wait_ready "$ns" "$cluster" 300 || { echo "ERROR: $ns/$cluster not ready at $orig instances after 300s"; exit 1; }
    cnpg_wait_caught_up "$ns" "$cluster" 300 || { echo "ERROR: $ns/$cluster replicas not caught up after 300s"; exit 1; }
  done < "$SCALE_MARKER"
  rm -f "$SCALE_MARKER"
fi

echo "==> Done. Verify with: kubectl get nodes"
echo "    The IPIP tunnel will persist across reboots (systemd: ipip-tunnel.service)"
