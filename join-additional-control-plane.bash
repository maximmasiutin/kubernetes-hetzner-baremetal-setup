#!/bin/bash

# This script joins an additional control plane node to an existing Kubernetes cluster.
# It validates that both nodes are using vSwitch (vlan4000) addresses in the same subnet,
# and configures proper certificate SANs for the new control plane.
#
# Usage: $0 <CONTROL_PLANE_IP> <JOIN_TOKEN> <CA_CERT_HASH> <CERT_KEY> [HOSTNAME]
#   CONTROL_PLANE_IP - IP address of existing control plane on vSwitch
#   JOIN_TOKEN       - Token from 'kubeadm token create'
#   CA_CERT_HASH     - CA cert hash (sha256:xxx) from join command
#   CERT_KEY         - Certificate key from 'kubeadm init phase upload-certs --upload-certs'
#   HOSTNAME         - Optional. Node name for this control plane (defaults to system hostname)
#
# On existing control plane, run:
#   kubeadm token create --print-join-command
#   kubeadm init phase upload-certs --upload-certs
#
# Example:
#   $0 10.0.0.10 abcdef.token sha256:xxx certkey123 cp-2.example.com

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Check required parameters
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
    echo "Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <CONTROL_PLANE_IP> <JOIN_TOKEN> <CA_CERT_HASH> <CERT_KEY> [HOSTNAME]"
    echo ""
    echo "On existing control plane, run these commands to get the values:"
    echo "  kubeadm token create --print-join-command"
    echo "  kubeadm init phase upload-certs --upload-certs"
    echo ""
    echo "Example:"
    echo "  $0 10.0.0.10 abcdef.token sha256:xxx certkey123 cp-2"
    exit 1
fi

EXISTING_CP_IP="$1"
JOIN_TOKEN="$2"
CA_CERT_HASH="$3"
CERT_KEY="$4"
NEW_CP_HOSTNAME="${5:-$(hostname)}"

echo "=========================================="
echo "Additional Control Plane Join"
echo "=========================================="
echo "Existing Control Plane IP: $EXISTING_CP_IP"
echo "New Control Plane Hostname: $NEW_CP_HOSTNAME"
echo ""

# =============================================================================
# Step 1: Validate this node's vlan4000 interface exists and get its IP/subnet
# =============================================================================
echo "Step 1: Checking this node's vlan4000 interface..."

NEW_CP_IP_CIDR=$(ip -4 addr show vlan4000 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')

if [ -z "$NEW_CP_IP_CIDR" ]; then
    echo "Error: vlan4000 interface not found or has no IP on this node!"
    echo "Please run init-hetzner-vswitch.bash first"
    exit 1
fi

NEW_CP_IP="${NEW_CP_IP_CIDR%/*}"
NEW_CP_SUBNET_MASK="${NEW_CP_IP_CIDR#*/}"

echo "  This node's vlan4000 IP: $NEW_CP_IP/$NEW_CP_SUBNET_MASK"

# =============================================================================
# Step 2: Validate existing control plane IP format
# =============================================================================
echo ""
echo "Step 2: Validating existing control plane IP format..."

if ! [[ "$EXISTING_CP_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Invalid control plane IP format: $EXISTING_CP_IP"
    exit 1
fi

# Validate each octet is 0-255
IFS='.' read -r -a cp_octets <<< "$EXISTING_CP_IP"
for octet in "${cp_octets[@]}"; do
    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
        echo "Error: Invalid control plane IP $EXISTING_CP_IP (octet $octet out of range)"
        exit 1
    fi
done

echo "  Existing control plane IP format: OK"

# =============================================================================
# Step 3: Calculate network addresses and validate same subnet
# =============================================================================
echo ""
echo "Step 3: Validating both control planes are in the same vSwitch subnet..."

# Function to convert IP to integer
ip_to_int() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Function to convert integer to IP
int_to_ip() {
    local int="$1"
    echo "$(( (int >> 24) & 255 )).$(( (int >> 16) & 255 )).$(( (int >> 8) & 255 )).$(( int & 255 ))"
}

# Calculate network mask from CIDR
NETMASK_INT=$(( 0xFFFFFFFF << (32 - NEW_CP_SUBNET_MASK) & 0xFFFFFFFF ))

# Calculate network addresses
NEW_CP_IP_INT=$(ip_to_int "$NEW_CP_IP")
EXISTING_CP_IP_INT=$(ip_to_int "$EXISTING_CP_IP")

NEW_CP_NETWORK_INT=$(( NEW_CP_IP_INT & NETMASK_INT ))
EXISTING_CP_NETWORK_INT=$(( EXISTING_CP_IP_INT & NETMASK_INT ))

NEW_CP_NETWORK=$(int_to_ip $NEW_CP_NETWORK_INT)
EXISTING_CP_NETWORK=$(int_to_ip $EXISTING_CP_NETWORK_INT)

echo "  This node's network:     $NEW_CP_NETWORK/$NEW_CP_SUBNET_MASK"
echo "  Existing CP network:     $EXISTING_CP_NETWORK/$NEW_CP_SUBNET_MASK"

if [ "$NEW_CP_NETWORK_INT" -ne "$EXISTING_CP_NETWORK_INT" ]; then
    echo ""
    echo "Error: Existing control plane IP $EXISTING_CP_IP is NOT in the same subnet!"
    echo "  This node is on network:     $NEW_CP_NETWORK/$NEW_CP_SUBNET_MASK"
    echo "  Existing CP appears to be:   $EXISTING_CP_NETWORK/$NEW_CP_SUBNET_MASK"
    echo ""
    echo "Both control plane nodes must be in the same Hetzner vSwitch subnet."
    exit 1
fi

echo "  Subnet validation: OK (both in $NEW_CP_NETWORK/$NEW_CP_SUBNET_MASK)"

# =============================================================================
# Step 4: Test connectivity to existing control plane via vlan4000
# =============================================================================
echo ""
echo "Step 4: Testing connectivity to existing control plane..."

# Ping test
echo -n "  Ping $EXISTING_CP_IP: "
if ping -c 2 -W 3 "$EXISTING_CP_IP" > /dev/null 2>&1; then
    echo "OK"
else
    echo "FAILED"
    echo ""
    echo "Error: Cannot ping existing control plane at $EXISTING_CP_IP"
    echo "Check that:"
    echo "  1. Existing control plane server is running"
    echo "  2. Both servers are in the same Hetzner vSwitch"
    echo "  3. Firewall allows vSwitch traffic"
    exit 1
fi

# API server test
echo -n "  API server (port 6443): "
if timeout 5 bash -c "echo > /dev/tcp/$EXISTING_CP_IP/6443" 2>/dev/null; then
    echo "OK"
else
    echo "FAILED"
    echo ""
    echo "Error: Cannot reach API server at $EXISTING_CP_IP:6443"
    exit 1
fi

# etcd test (control planes need etcd access)
echo -n "  etcd (port 2379): "
if timeout 5 bash -c "echo > /dev/tcp/$EXISTING_CP_IP/2379" 2>/dev/null; then
    echo "OK"
else
    echo "FAILED"
    echo ""
    echo "Error: Cannot reach etcd at $EXISTING_CP_IP:2379"
    echo "Ensure firewall allows etcd traffic between control planes"
    exit 1
fi

# =============================================================================
# Step 5: Join as additional control plane
# =============================================================================
echo ""
echo "Step 5: Joining as additional control plane..."
echo ""
echo "This node will:"
echo "  - Join the cluster as a control plane"
echo "  - Advertise API server on: $NEW_CP_IP"
echo "  - Generate certificates with SANs: $NEW_CP_HOSTNAME, $NEW_CP_IP"
echo ""

# Build join command
JOIN_CMD="kubeadm join ${EXISTING_CP_IP}:6443"
JOIN_CMD="$JOIN_CMD --token $JOIN_TOKEN"
JOIN_CMD="$JOIN_CMD --discovery-token-ca-cert-hash $CA_CERT_HASH"
JOIN_CMD="$JOIN_CMD --control-plane"
JOIN_CMD="$JOIN_CMD --certificate-key $CERT_KEY"
JOIN_CMD="$JOIN_CMD --apiserver-advertise-address=$NEW_CP_IP"
JOIN_CMD="$JOIN_CMD --node-name $NEW_CP_HOSTNAME"

echo "Executing: kubeadm join ${EXISTING_CP_IP}:6443 --control-plane --apiserver-advertise-address=$NEW_CP_IP --node-name $NEW_CP_HOSTNAME ..."
echo ""

$JOIN_CMD

if [ $? -ne 0 ]; then
    echo ""
    echo "Error: kubeadm join failed!"
    exit 1
fi

# =============================================================================
# Step 6: Setup kubectl for current user
# =============================================================================
echo ""
echo "Step 6: Setting up kubectl for current user..."

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo ~$ACTUAL_USER)

mkdir -p $ACTUAL_HOME/.kube
cp -i /etc/kubernetes/admin.conf $ACTUAL_HOME/.kube/config
chown $(id -u $ACTUAL_USER):$(id -g $ACTUAL_USER) $ACTUAL_HOME/.kube/config

# =============================================================================
# Step 7: Configure firewall
# =============================================================================
echo ""
echo "Step 7: Configuring firewall for vSwitch traffic..."

iptables -I INPUT -i vlan4000 -j ACCEPT
iptables -I OUTPUT -o vlan4000 -j ACCEPT
iptables -I FORWARD -i vlan4000 -j ACCEPT
iptables -I FORWARD -o vlan4000 -j ACCEPT

apt-get install -y iptables-persistent
netfilter-persistent save

echo ""
echo "=========================================="
echo "Additional Control Plane Joined!"
echo "=========================================="
echo ""
echo "This node ($NEW_CP_HOSTNAME) is now a control plane."
echo "API server advertised on: $NEW_CP_IP"
echo ""
echo "Verify cluster status:"
echo "  kubectl get nodes"
echo ""
echo "You should see multiple control plane nodes with 'control-plane' role."
echo ""
