# Kubernetes Cluster Setup on Hetzner with vSwitch

This guide provides scripts to set up a Kubernetes cluster on Hetzner servers using vSwitch for private networking.

## Prerequisites

- Two or more Hetzner dedicated servers
- Servers added to the same vSwitch in Hetzner Robot panel (https://robot.hetzner.com)
- Ubuntu 24.04 (recommended) or similar Debian-based OS
- Root access to all servers

## Files Overview

1. **init-network.bash** - Configures kernel parameters and modules for Kubernetes
2. **init-hetzner-vswitch.bash** - Sets up Hetzner vSwitch VLAN interface
3. **install-kube-tools-containerd.bash** - Installs Kubernetes tools with containerd (RECOMMENDED)
4. **install-kube-tools-cri-o.bash** - Installs Kubernetes tools with CRI-O (alternative)
5. **init-control-plane.bash** - Initializes the Kubernetes control plane
6. **join-worker-node.bash** - Joins worker nodes to the cluster

## Step-by-Step Installation

Replace version numbers to the versions you need in the `install-kube-tools-cri-o.bash` file, by editing these lines:
```
KUBERNETES_VERSION=v1.34
CRIO_VERSION=v1.34
```

### On Control Plane Node (Master)

#### Step 1: Configure Network
```
sudo ./init-network.bash
```

#### Step 2: Install Kubernetes Tools and CRI-O Container Runtime
```
sudo ./install-kube-tools-cri-o.bash
```

#### Step 3: Configure Hetzner vSwitch and set IP address of Your Node
```
# Use the IP/subnet you want for this node (e.g., 10.0.0.10/24)
# This is the node's address in the vSwitch network for inter-node communication,
# NOT a pod IP (pod IPs are managed by Calico CNI)
sudo ./init-hetzner-vswitch.bash 10.0.0.10/24
```

[According to Hetzner](https://docs.hetzner.com/robot/dedicated-server/network/vswitch/#firewall)
>The servers' firewall is also applied to the packets of the vSwitches. Important note: If you have activated a firewall, you must also enable internal IP addresses in the firewall.

Verify vSwitch connectivity:
```
ip addr show vlan4000
# Should show: inet 10.0.0.10/24
```

#### Step 4: Initialize Control Plane
```
sudo ./init-control-plane.bash
```

This script will:
- Initialize Kubernetes on vSwitch IP (10.0.0.10)
- Install Calico CNI
- Configure Calico to use vlan4000
- Set up firewall rules for cluster communication
- Configure kubectl for the current user

Wait for all pods to be running:
```
kubectl get pods -A
```

#### Step 5: Get Join Command for Workers
```
kubeadm token create --print-join-command
```

Copy the output - you'll need it for worker nodes.

### On Worker Nodes

#### Steps 1-3: Same as Control Plane
```
# Step 1: Network configuration
sudo ./init-network.bash

# Step 2: Install Kubernetes tools (use same runtime as control plane!)
sudo ./install-kube-tools-containerd.bash

# Step 3: Configure vSwitch with different IP
sudo ./init-hetzner-vswitch.bash 10.0.0.11/24  # Use .11, .12, etc for each worker
```

#### Step 4: Join the Cluster
```
sudo ./join-worker-node.bash 'kubeadm join 10.0.0.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>'
```

Replace the join command with the actual command from Step 5 on the control plane.

### Verify Cluster

From the control plane:
```
kubectl get nodes
# All nodes should show "Ready"

kubectl get pods -A
# All pods should be "Running"
```

## Network Architecture

- **Public Network**: Each server has its public IP (e.g., 5.9.143.195, 78.46.68.239)
- **vSwitch (VLAN 4000)**: Private network for node-to-node communication (10.0.0.0/24). These are node IPs used for Kubernetes control plane traffic and inter-node communication.
  - Control plane: 10.0.0.10
  - Worker 1: 10.0.0.11
  - Worker 2: 10.0.0.12, etc.
- **Pod Network**: Calico CNI manages pod IPs (192.168.0.0/16). These are automatically assigned to pods and are separate from node IPs.

## Important Notes

### vSwitch Configuration
- All servers MUST be added to the same vSwitch in Hetzner Robot panel
- VLAN ID: 4000 (configured in scripts)
- MTU: 1400 (Hetzner requirement)

### Container Runtime
- Choose ONE runtime (containerd OR CRI-O) and use it consistently on all nodes
- Containerd is simpler and recommended for most users
- DO NOT mix runtimes in the same cluster

### Firewall
- The scripts configure iptables to allow traffic on vlan4000
- Hetzner Robot firewall only affects public IPs, not vSwitch traffic
- Rules are made persistent with iptables-persistent

### Calico Configuration
- Uses IPIP mode for pod-to-pod communication
- Configured to detect node IP via vlan4000 interface
- Pod network: 192.168.0.0/16

## Troubleshooting

### Worker Can't Join Cluster
1. Check vSwitch connectivity:
   ```
   ping 10.0.0.10  # from worker to control plane
   ```

2. Test API server access:
   ```
   telnet 10.0.0.10 6443
   curl -k https://10.0.0.10:6443/healthz
   ```

3. Check firewall rules:
   ```
   sudo iptables -L INPUT -n -v | grep vlan4000
   ```

4. Verify both nodes are in the same vSwitch in Hetzner Robot panel

### Node Shows "NotReady"
1. Check if Calico pods are running:
   ```
   kubectl get pods -n kube-system | grep calico
   ```

2. Check Calico logs:
   ```
   kubectl logs -n kube-system -l k8s-app=calico-node
   ```

3. Verify Calico is using correct interface:
   ```
   kubectl logs -n kube-system -l k8s-app=calico-node | grep "Using detected IPv4"
   # Should show: Using detected IPv4 address: 10.0.0.X
   ```

### Pods Can't Communicate
1. Check if tunl0 interface exists (Calico IPIP tunnel):
   ```
   ifconfig tunl0
   ```

2. Test pod-to-pod connectivity:
   ```
   kubectl run test --image=busybox --rm -it -- ping <other-pod-ip>
   ```

3. Check Calico network policy:
   ```
   kubectl get networkpolicies -A
   ```

## Single-Node Cluster

If you want to run workloads on the control plane (single-node setup):
```
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
```

## Cleaning Up

To completely remove Kubernetes from a node:
```
sudo kubeadm reset -f
sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni
sudo apt-get autoremove -y
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd ~/.kube
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
```

## Additional Resources

- Kubernetes Documentation: https://kubernetes.io/docs/
- Calico Documentation: https://docs.tigera.io/calico/latest/about
- Hetzner Docs: https://docs.hetzner.com/

## Support

For issues specific to these scripts, check:
1. All servers are in the same vSwitch in Hetzner Robot
2. vlan4000 interface is UP on all nodes
3. Firewall rules are applied (check iptables)
4. Same container runtime on all nodes
5. Correct IPs in all commands
