# Quick Start Guide

## Download All Files

You should have downloaded these 9 files:

### Core Setup Scripts:
1. `init-network.bash` - Configure kernel for Kubernetes
2. `init-hetzner-vswitch.bash` - Setup vSwitch interface
3. `install-kube-tools-cri-o.bash` - Install Kubernetes + CRI-O

### Automation Scripts:
5. `init-control-plane.bash` - Initialize control plane
6. `setup-control-plane-complete.bash` - Complete control plane setup (all-in-one)
7. `setup-worker-complete.bash` - Complete worker setup (all-in-one)

### Documentation:
8. `README.md` - Full documentation
9. `QUICKSTART.md` - This file

## Fastest Way to Setup

Replace version numbers to the versions you need in the `install-kube-tools-cri-o.bash` file, by editing these lines:
```
KUBERNETES_VERSION=v1.34
CRIO_VERSION=v1.34
```

### Control Plane Node (One Command):

```
# Make scripts executable
chmod +x *.bash

# Run complete setup (replace 10.0.0.10/24 with your IP/subnet)
sudo ./setup-control-plane-complete.bash 10.0.0.10/24
```

This single command does everything!

### Worker Node (Two Commands):

```
# Make scripts executable
chmod +x *.bash

# Run worker setup (replace 10.0.0.11/24 with your IP/subnet)
sudo ./setup-worker-complete.bash 10.0.0.11/24
```

## Manual Step-by-Step (If You Prefer)

### Control Plane:
```
chmod +x *.bash
sudo ./init-network.bash
sudo ./install-kube-tools-containerd.bash
sudo ./init-hetzner-vswitch.bash 10.0.0.10/24
sudo ./init-control-plane.bash
```

### Worker:
```
chmod +x *.bash
sudo ./init-network.bash
sudo ./install-kube-tools-containerd.bash
sudo ./init-hetzner-vswitch.bash 10.0.0.11/24
```

## Get Join Command

On control plane:
```
kubeadm token create --print-join-command
```

Copy the entire output and use it on worker nodes.

## Verify Cluster

```
kubectl get nodes
kubectl get pods -A
```

All nodes should show "Ready" and all pods "Running".

## Important Prerequisites

1. **Hetzner Robot Panel**: Add all servers to the same vSwitch
   - Go to https://robot.hetzner.com
   - Navigate to vSwitch section
   - Ensure all servers are in the same vSwitch

2. **Network Connectivity**: Test vSwitch before joining:
   ```
   # From worker to control plane
   ping 10.0.0.10
   telnet 10.0.0.10 6443
   ```

3. **Same Container Runtime**: Use CRI-O on ALL nodes

## Troubleshooting Quick Fixes

### "Worker can't join cluster"
```
# On control plane, allow vSwitch traffic
sudo iptables -I INPUT -i vlan4000 -j ACCEPT
```

### "Node shows NotReady"
```
# Wait for Calico pods to start
kubectl get pods -n kube-system -w
```

### "Can't ping between nodes"
```
# Check vlan4000 is up
ip addr show vlan4000

# Check both nodes are in Hetzner vSwitch
# (Check in Robot panel)
# Check that the addresses used in vSwitch are accounted for in the external firewall
```

## Single-Node Cluster

To run workloads on control plane:
```
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
```

## Need More Help?

See `README.md` for complete documentation and detailed troubleshooting.

## Network IPs Summary

**Node IPs (vSwitch)** - for inter-node communication, set manually via `init-hetzner-vswitch.bash`:
- Control Plane: `10.0.0.10`
- Worker 1: `10.0.0.11`
- Worker 2: `10.0.0.12`

**Pod IPs** - managed automatically by Calico CNI (not configured manually):
- Pod Network: `192.168.0.0/16`
- Service Network: `10.96.0.0/12`
