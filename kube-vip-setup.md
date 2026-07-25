# kube-vip Setup (future)

## Prerequisites

- A spare/floating IP from your provider (Hetzner, DO, etc.)
- 2+ K3s nodes
- Interface: `eth0`

## Steps

1. Order spare IP from provider, routed to your network
2. Generate manifest:
   ```bash
   kube-vip manifest daemonset \
     --interface eth0 \
     --address <SPARE_IP> \
     --controlplane \
     --services \
     --arp \
     --leaderElection
   ```
3. Apply manifest to cluster
4. Update DNS for all domains to point to `<SPARE_IP>` instead of `89.167.78.168`

kube-vip advertises the spare IP via ARP. The leader node owns it. If leader dies, another node takes over. Traefik handles per-domain routing inside the cluster.
