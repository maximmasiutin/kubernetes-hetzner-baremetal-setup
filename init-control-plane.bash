#!/bin/bash

# This script initializes the Kubernetes control plane using the vSwitch IP.
# It reads the IP and subnet from the vlan4000 interface and validates the
# configuration. An optional hostname can be provided for certificate SANs.
#
# Usage: $0 [HOSTNAME]
#   HOSTNAME - Optional. DNS name to add to API server certificate.
#              If not provided, uses system hostname.

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Get optional hostname parameter or use system hostname
if [ -n "$1" ]; then
    CONTROL_PLANE_HOSTNAME="$1"
else
    CONTROL_PLANE_HOSTNAME=$(hostname)
fi

echo "Using hostname: $CONTROL_PLANE_HOSTNAME"

# Get the vSwitch IP with CIDR notation (e.g., 10.0.0.10/24)
VSWITCH_IP_CIDR=$(ip -4 addr show vlan4000 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')

if [ -z "$VSWITCH_IP_CIDR" ]; then
    echo "Error: vlan4000 not found or not configured!"
    echo "Please run init-hetzner-vswitch.bash first"
    exit 1
fi

# Extract IP address and subnet mask
VSWITCH_IP="${VSWITCH_IP_CIDR%/*}"
VSWITCH_SUBNET="${VSWITCH_IP_CIDR#*/}"

# Validate IP format
if ! [[ "$VSWITCH_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format: $VSWITCH_IP"
    exit 1
fi

# Validate each octet is 0-255
IFS='.' read -r -a octets <<< "$VSWITCH_IP"
for octet in "${octets[@]}"; do
    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
        echo "Error: Invalid IP address $VSWITCH_IP (octet $octet out of range)"
        exit 1
    fi
done

echo "Detected vSwitch IP: $VSWITCH_IP/$VSWITCH_SUBNET on vlan4000"
echo ""
echo "Initializing Kubernetes control plane..."
echo "This may take several minutes..."
echo ""

# Initialize Kubernetes with hostname in certificate SANs
kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=$VSWITCH_IP \
  --control-plane-endpoint=$CONTROL_PLANE_HOSTNAME \
  --apiserver-cert-extra-sans=$CONTROL_PLANE_HOSTNAME,$VSWITCH_IP

if [ $? -ne 0 ]; then
    echo "kubeadm init failed!"
    exit 1
fi

echo ""
echo "Setting up kubectl for current user..."

# Get the actual user (not root if using sudo)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)

# Setup kubectl config
mkdir -p $ACTUAL_HOME/.kube
cp -i /etc/kubernetes/admin.conf $ACTUAL_HOME/.kube/config
chown $(id -u $ACTUAL_USER):$(id -g $ACTUAL_USER) $ACTUAL_HOME/.kube/config

echo ""
echo "Installing Calico CNI..."

# Download and modify Calico manifest
curl -s https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml -o /tmp/calico.yaml

# Switch to actual user for kubectl commands
su - $ACTUAL_USER -c "kubectl apply -f /tmp/calico.yaml"

# Wait for calico-node daemonset to be created
echo "Waiting for Calico to initialize..."
sleep 10

# Configure Calico to use vlan4000
su - $ACTUAL_USER -c "kubectl set env daemonset/calico-node -n kube-system IP_AUTODETECTION_METHOD=interface=vlan4000"

echo ""
echo "Configuring firewall for vSwitch traffic..."

# Allow all traffic through vSwitch interface
iptables -I INPUT -i vlan4000 -j ACCEPT
iptables -I OUTPUT -o vlan4000 -j ACCEPT
iptables -I FORWARD -i vlan4000 -j ACCEPT
iptables -I FORWARD -o vlan4000 -j ACCEPT

# Make iptables rules persistent
apt-get install -y iptables-persistent
netfilter-persistent save

echo ""
echo "Waiting for node to be Ready..."
sleep 30

# Check node status
su - $ACTUAL_USER -c "kubectl get nodes"

echo ""
echo "=========================================="
echo "Control Plane Initialization Complete!"
echo "=========================================="
echo ""
echo "To add worker nodes, run this command on the control plane to get the join command:"
echo "  kubeadm token create --print-join-command"
echo ""
echo "To check cluster status:"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo ""
echo "If you want this to be a single-node cluster (run workloads on control plane):"
echo "  kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-"
echo ""
