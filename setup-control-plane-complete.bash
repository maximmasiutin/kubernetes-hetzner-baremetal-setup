#!/bin/bash

# Complete setup script for Kubernetes control plane on Hetzner
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
    echo "Example: sudo $0 10.0.0.10/24"
    exit 1
fi

VSWITCH_IP="$1"

echo "=========================================="
echo "Kubernetes Control Plane Setup"
echo "=========================================="
echo "vSwitch IP: $VSWITCH_IP"
echo ""
echo "This script will:"
echo "1. Configure network settings"
echo "2. Install Kubernetes tools and CRI-O"
echo "3. Setup Hetzner vSwitch"
echo "4. Initialize Kubernetes control plane"
echo "5. Install and configure Calico CNI"
echo ""
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

echo ""
echo "Step 1/5: Configuring network..."
bash init-network.bash

echo ""
echo "Step 2/5: Installing Kubernetes tools and CRI-O..."
bash install-kube-tools-cri-o.bash

echo ""
echo "Step 3/5: Setting up vSwitch..."
bash init-hetzner-vswitch.bash $VSWITCH_IP

echo ""
echo "Step 4/5: Initializing control plane..."
bash init-control-plane.bash

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Your Kubernetes control plane is ready!"
echo ""
echo "Next steps:"
echo ""
echo "1. Check cluster status:"
echo "   kubectl get nodes"
echo "   kubectl get pods -A"
echo ""
echo "2. To add worker nodes:"
echo "   a) Run setup scripts on worker (steps 1-3)"
echo "   b) Get join command:"
echo "      kubeadm token create --print-join-command"
echo "   c) Run join command on worker node"
echo ""
echo "3. For single-node cluster (optional):"
echo "   kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-"
echo ""
