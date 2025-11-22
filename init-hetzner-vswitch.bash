#!/bin/bash

# This script configures the Hetzner vSwitch VLAN interface for node-to-node communication.
# The IP address specified here is the node's address within the private vSwitch network,
# used for Kubernetes control plane and inter-node traffic (e.g., 10.0.0.10/24).
# This is NOT a Pod IP - Pod IPs are managed by the Kubernetes CNI (Calico) on a
# separate network (192.168.0.0/16 by default).

# Check if IP address parameter is provided
if [ -z "$1" ]; then
    echo "Error: IP address with subnet parameter is required"
    echo "Usage: $0 <IP_ADDRESS/SUBNET>"
    echo "Example: $0 10.0.0.10/24"
    exit 1
fi

# Parse IP address and subnet from parameter
IP_WITH_SUBNET="$1"
if ! [[ "$IP_WITH_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "Error: Invalid IP address format"
    echo "Expected format: x.x.x.x/mask (e.g., 10.0.0.10/24)"
    exit 1
fi

# Extract IP address and subnet mask
IP_ADDRESS="${IP_WITH_SUBNET%/*}"
SUBNET_MASK="${IP_WITH_SUBNET#*/}"

# Validate subnet mask (0-32)
if [ "$SUBNET_MASK" -gt 32 ] || [ "$SUBNET_MASK" -lt 0 ]; then
    echo "Error: Subnet mask must be between 0 and 32"
    exit 1
fi

# Validate each octet is between 0-255
IFS='.' read -r -a octets <<< "$IP_ADDRESS"
for octet in "${octets[@]}"; do
    if [ "$octet" -gt 255 ] || [ "$octet" -lt 0 ]; then
        echo "Error: IP address octets must be between 0 and 255"
        exit 1
    fi
done

echo "Using IP address: $IP_ADDRESS with subnet /$SUBNET_MASK"

# Detect the primary physical network interface
PHYSICAL_IFACE=$(ip route show default | grep -oP 'dev \K\S+' | head -n1)

# Fallback: try to get first non-loopback interface
if [ -z "$PHYSICAL_IFACE" ]; then
    PHYSICAL_IFACE=$(ip link show | grep -E '^[0-9]+: (en|eth)' | head -n1 | cut -d: -f2 | tr -d ' ')
fi

# Check if we successfully detected an interface
if [ -z "$PHYSICAL_IFACE" ]; then
    echo "Error: Could not detect physical network interface"
    echo "Available interfaces:"
    ip link show
    exit 1
fi

echo "Detected physical interface: $PHYSICAL_IFACE"

# Install VLAN support
sudo apt update
sudo apt install -y vlan

# Load 8021q module
sudo modprobe 8021q
echo "8021q" | sudo tee -a /etc/modules

# Create vSwitch netplan configuration
# Note: We only create the VLAN config, assuming main interface is already configured
cat <<EOT | sudo tee /etc/netplan/10-vswitch.yaml
network:
  version: 2
  vlans:
    vlan4000:
      id: 4000
      link: $PHYSICAL_IFACE
      addresses:
        - $IP_WITH_SUBNET
      mtu: 1400
EOT

sudo chmod 600 /etc/netplan/10-vswitch.yaml

# Apply netplan configuration
echo "Applying netplan configuration..."
sudo netplan apply

# Verify vlan4000 is up
echo ""
echo "Verifying vlan4000 interface:"
ip addr show vlan4000
echo ""
echo "VLAN interface configured successfully!"

# Determine the alternate IP address for ping suggestion
if [ "$IP_ADDRESS" = "10.0.0.10" ]; then
    PING_TARGET="10.0.0.11"
elif [[ "$IP_ADDRESS" =~ ^10\.0\.0\. ]]; then
    # Extract last octet and suggest a different IP in same subnet
    LAST_OCTET="${IP_ADDRESS##*.}"
    if [ "$LAST_OCTET" = "10" ]; then
        PING_TARGET="10.0.0.11"
    else
        PING_TARGET="10.0.0.10"
    fi
else
    PING_TARGET="<other-vswitch-node-ip>"
fi

echo "To test connectivity, ping another node in the vSwitch:"
echo "  ping $PING_TARGET"
echo " According to Hetzner https://docs.hetzner.com/robot/dedicated-server/network/vswitch/#firewall The servers' firewall is also applied to the packets of the vSwitches. Important note: If you have activated a firewall, you must also enable internal IP addresses in the firewall."