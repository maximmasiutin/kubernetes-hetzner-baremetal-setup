#!/bin/bash

# This script joins a worker node to an existing Kubernetes cluster.
# It validates that both the control plane and worker node are using vSwitch
# (vlan4000) addresses in the same subnet before attempting to join.
#
# Usage: $0 <CONTROL_PLANE_IP> <JOIN_TOKEN> <CA_CERT_HASH> [WORKER_HOSTNAME]
#   CONTROL_PLANE_IP - IP address of the control plane on vSwitch
#   JOIN_TOKEN       - Token from 'kubeadm token create'
#   CA_CERT_HASH     - CA cert hash (sha256:xxx) from join command
#   WORKER_HOSTNAME  - Optional. Node name for this worker (defaults to system hostname)
#
# Example:
#   $0 10.0.0.10 abcdef.0123456789abcdef sha256:xxx
#   $0 10.0.0.10 abcdef.0123456789abcdef sha256:xxx worker-1.example.com

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# Check required parameters
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <CONTROL_PLANE_IP> <JOIN_TOKEN> <CA_CERT_HASH> [WORKER_HOSTNAME]"
    echo ""
    echo "Get these values from control plane:"
    echo "  kubeadm token create --print-join-command"
    echo ""
    echo "Example:"
    echo "  $0 10.0.0.10 abcdef.0123456789abcdef sha256:64char... worker-1"
    exit 1
fi

CONTROL_PLANE_IP="$1"
JOIN_TOKEN="$2"
CA_CERT_HASH="$3"
WORKER_HOSTNAME="${4:-$(hostname)}"

echo "=========================================="
echo "Kubernetes Worker Node Join"
echo "=========================================="
echo "Control Plane IP: $CONTROL_PLANE_IP"
echo "Worker Hostname:  $WORKER_HOSTNAME"
echo ""

# =============================================================================
# Step 1: Validate worker's vlan4000 interface exists and get its IP/subnet
# =============================================================================
echo "Step 1: Checking worker's vlan4000 interface..."

WORKER_IP_CIDR=$(ip -4 addr show vlan4000 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')

if [ -z "$WORKER_IP_CIDR" ]; then
    echo "Error: vlan4000 interface not found or has no IP on this worker!"
    echo "Please run init-hetzner-vswitch.bash first"
    exit 1
fi

WORKER_IP="${WORKER_IP_CIDR%/*}"
WORKER_SUBNET_MASK="${WORKER_IP_CIDR#*/}"

echo "  Worker vlan4000 IP: $WORKER_IP/$WORKER_SUBNET_MASK"

# =============================================================================
# Step 2: Validate control plane IP format
# =============================================================================
echo ""
echo "Step 2: Validating control plane IP format..."

if ! [[ "$CONTROL_PLANE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Invalid control plane IP format: $CONTROL_PLANE_IP"
    exit 1
fi

# Validate each octet is 0-255
IFS='.' read -r -a cp_octets <<< "$CONTROL_PLANE_IP"
for octet in "${cp_octets[@]}"; do
    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
        echo "Error: Invalid control plane IP $CONTROL_PLANE_IP (octet $octet out of range)"
        exit 1
    fi
done

echo "  Control plane IP format: OK"

# =============================================================================
# Step 3: Calculate network addresses and validate same subnet
# =============================================================================
echo ""
echo "Step 3: Validating both IPs are in the same vSwitch subnet..."

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
NETMASK_INT=$(( 0xFFFFFFFF << (32 - WORKER_SUBNET_MASK) & 0xFFFFFFFF ))

# Calculate network addresses
WORKER_IP_INT=$(ip_to_int "$WORKER_IP")
CONTROL_PLANE_IP_INT=$(ip_to_int "$CONTROL_PLANE_IP")

WORKER_NETWORK_INT=$(( WORKER_IP_INT & NETMASK_INT ))
CONTROL_PLANE_NETWORK_INT=$(( CONTROL_PLANE_IP_INT & NETMASK_INT ))

WORKER_NETWORK=$(int_to_ip $WORKER_NETWORK_INT)
CONTROL_PLANE_NETWORK=$(int_to_ip $CONTROL_PLANE_NETWORK_INT)

echo "  Worker network:        $WORKER_NETWORK/$WORKER_SUBNET_MASK"
echo "  Control plane network: $CONTROL_PLANE_NETWORK/$WORKER_SUBNET_MASK"

if [ "$WORKER_NETWORK_INT" -ne "$CONTROL_PLANE_NETWORK_INT" ]; then
    echo ""
    echo "Error: Control plane IP $CONTROL_PLANE_IP is NOT in the same subnet as worker!"
    echo "  Worker is on network:        $WORKER_NETWORK/$WORKER_SUBNET_MASK"
    echo "  Control plane appears to be: $CONTROL_PLANE_NETWORK/$WORKER_SUBNET_MASK"
    echo ""
    echo "Both nodes must be in the same Hetzner vSwitch subnet."
    echo "Check that:"
    echo "  1. Control plane has vlan4000 configured with IP in $WORKER_NETWORK/$WORKER_SUBNET_MASK"
    echo "  2. Both servers are added to the same vSwitch in Hetzner Robot panel"
    exit 1
fi

echo "  Subnet validation: OK (both in $WORKER_NETWORK/$WORKER_SUBNET_MASK)"

# =============================================================================
# Step 4: Test connectivity to control plane via vlan4000
# =============================================================================
echo ""
echo "Step 4: Testing connectivity to control plane..."

# Ping test
echo -n "  Ping $CONTROL_PLANE_IP: "
if ping -c 2 -W 3 "$CONTROL_PLANE_IP" > /dev/null 2>&1; then
    echo "OK"
else
    echo "FAILED"
    echo ""
    echo "Error: Cannot ping control plane at $CONTROL_PLANE_IP"
    echo "Check that:"
    echo "  1. Control plane server is running"
    echo "  2. Control plane has vlan4000 interface configured"
    echo "  3. Both servers are in the same Hetzner vSwitch"
    echo "  4. Firewall allows vSwitch traffic"
    exit 1
fi

# API server test
echo -n "  API server (port 6443): "
if timeout 5 bash -c "echo > /dev/tcp/$CONTROL_PLANE_IP/6443" 2>/dev/null; then
    echo "OK"
else
    echo "FAILED"
    echo ""
    echo "Error: Cannot reach API server at $CONTROL_PLANE_IP:6443"
    echo "Check that:"
    echo "  1. Kubernetes control plane is initialized"
    echo "  2. API server is running: kubectl get pods -n kube-system"
    echo "  3. Firewall allows port 6443"
    exit 1
fi

# =============================================================================
# Step 5: Join the cluster
# =============================================================================
echo ""
echo "Step 5: Joining cluster..."
echo ""

# Build join command
JOIN_CMD="kubeadm join ${CONTROL_PLANE_IP}:6443"
JOIN_CMD="$JOIN_CMD --token $JOIN_TOKEN"
JOIN_CMD="$JOIN_CMD --discovery-token-ca-cert-hash $CA_CERT_HASH"
JOIN_CMD="$JOIN_CMD --node-name $WORKER_HOSTNAME"

echo "Executing: kubeadm join ${CONTROL_PLANE_IP}:6443 --token <token> --discovery-token-ca-cert-hash <hash> --node-name $WORKER_HOSTNAME"
echo ""

$JOIN_CMD

if [ $? -ne 0 ]; then
    echo ""
    echo "Error: kubeadm join failed!"
    exit 1
fi

echo ""
echo "=========================================="
echo "Worker Node Joined Successfully!"
echo "=========================================="
echo ""
echo "This node ($WORKER_HOSTNAME) has joined the cluster."
echo ""
echo "Verify from control plane:"
echo "  kubectl get nodes"
echo ""
echo "The node may take a minute to show as Ready while Calico initializes."
echo ""
