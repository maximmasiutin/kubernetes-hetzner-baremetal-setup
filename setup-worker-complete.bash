#!/bin/bash

# Complete setup script for Kubernetes worker node on Hetzner
# This script runs all setup steps in the correct order

set -e  # Exit on any error

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Check if IP address parameter is provided
if [ -z "$1" ]; then
    echo "Error: IP address with subnet parameter is required"
    echo "Usage: sudo $0 <VSWITCH_IP/SUBNET>"
    echo "Example: sudo $0 10.0.0.11/24"
    exit 1
fi

VSWITCH_IP="$1"

echo "=========================================="
echo "Kubernetes Worker Node Setup"
echo "=========================================="
echo "vSwitch IP: $VSWITCH_IP"
echo ""
echo "This script will:"
echo "1. Configure network settings"
echo "2. Install Kubernetes tools and CRI-O"
echo "3. Setup Hetzner vSwitch"
echo "4. Configure firewall for cluster communication"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

echo ""
echo "Step 1/4: Configuring network..."
bash init-network.bash

echo ""
echo "Step 2/4: Installing Kubernetes tools and CRI-O..."
bash install-kube-tools-cri-o.bash

echo ""
echo "Step 3/4: Setting up vSwitch..."
bash init-hetzner-vswitch.bash $VSWITCH_IP

echo ""
echo "Step 4/4: Configuring firewall..."

# Allow all traffic through vSwitch interface
iptables -I INPUT -i vlan4000 -j ACCEPT
iptables -I OUTPUT -o vlan4000 -j ACCEPT
iptables -I FORWARD -i vlan4000 -j ACCEPT
iptables -I FORWARD -o vlan4000 -j ACCEPT

# Make iptables rules persistent
apt-get install -y iptables-persistent
netfilter-persistent save

echo ""
echo "=========================================="
echo "Worker Node Setup Complete!"
echo "=========================================="
echo ""
echo "Next step: Join this node to the cluster"
echo ""
echo "1. On the control plane node, get the join command:"
echo "   kubeadm token create --print-join-command"
echo ""
echo "2. Use the join script (validates vSwitch subnet):"
echo "   sudo ./join-worker-node.bash <CONTROL_PLANE_IP> <TOKEN> <CA_HASH> [HOSTNAME]"
echo ""
echo "   Example:"
echo "   sudo ./join-worker-node.bash 10.0.0.10 abcdef.token sha256:hash worker-1"
echo ""
echo "3. Verify from control plane:"
echo "   kubectl get nodes"
echo ""
