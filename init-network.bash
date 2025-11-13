#!/bin/bash

echo "Configuring kernel modules..."

# Load required kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe 8021q

# Make kernel modules persistent
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
8021q
EOF

echo "Configuring sysctl parameters..."

# sysctl params required by Kubernetes
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Disable swap (Kubernetes requirement)
echo "Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Verify settings
echo ""
echo "Verifying network configuration:"
echo "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)"
echo "net.bridge.bridge-nf-call-iptables = $(sysctl -n net.bridge.bridge-nf-call-iptables)"
echo ""
echo "Loaded modules:"
lsmod | grep -E 'overlay|br_netfilter|8021q'
echo ""
echo "Network initialization complete!"
