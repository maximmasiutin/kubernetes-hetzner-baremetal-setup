#!/bin/bash

# Check if IP address parameter is provided
if [ -z "$1" ]; then
    echo "Error: IP address parameter is required"
    echo "Usage: $0 <IP_ADDRESS>"
    echo "Example: $0 10.0.0.10"
    exit 1
fi

# Validate IP address format (basic IPv4 validation)
IP_ADDRESS="$1"
if ! [[ "$IP_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format"
    echo "Expected format: x.x.x.x (e.g., 10.0.0.10)"
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

echo "Using IP address: $IP_ADDRESS"

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
        - $IP_ADDRESS/24
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