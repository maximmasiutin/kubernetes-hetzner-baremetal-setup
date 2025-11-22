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
6. **join-worker-node.bash** - Joins worker nodes (validates vSwitch subnet, tests connectivity)
7. **join-additional-control-plane.bash** - Joins additional control planes (HA setup)
8. **install-metrics-server.pl** - Installs metrics-server with TLS validation (enables kubectl top)
9. **install-node-problem-detector.pl** - Installs node-problem-detector (detects kernel/system issues)
10. **etcd-backup-restore.bash** - Backup and restore etcd datastore

## Step-by-Step Installation

### On Control Plane Node (Master)

#### Step 1: Configure Network
```
sudo ./init-network.bash
```

#### Step 2: Install Kubernetes Tools and CRI-O Container Runtime
```
# Auto-detect and install latest version
sudo ./install-kube-tools-cri-o.bash

# Or install previous stable version
sudo ./install-kube-tools-cri-o.bash --previous

# Or install specific version
sudo ./install-kube-tools-cri-o.bash --version 1.32

# List available versions
./install-kube-tools-cri-o.bash --list
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
# Basic usage (uses system hostname)
sudo ./init-control-plane.bash

# With custom hostname for certificate SANs
sudo ./init-control-plane.bash k8s-master.example.com
```

This script will:
- Detect vSwitch IP from vlan4000 interface and validate it
- Initialize Kubernetes with proper certificate SANs (hostname + IP)
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

Get join credentials from control plane:
```
kubeadm token create --print-join-command
```

Use the join script (validates vSwitch IPs are in same subnet):
```
sudo ./join-worker-node.bash <CONTROL_PLANE_IP> <TOKEN> <CA_HASH> [HOSTNAME]

# Example:
sudo ./join-worker-node.bash 10.0.0.10 abcdef.0123456789abcdef sha256:xxx worker-1
```

The script validates:
- Worker's vlan4000 interface exists
- Control plane IP is in the same subnet as worker's vlan4000 IP
- Connectivity to control plane (ping and API server port 6443)

### Adding Additional Control Planes (HA Setup)

For high availability, you can add more control plane nodes.

#### Steps 1-3: Same as Worker Node
```
sudo ./init-network.bash
sudo ./install-kube-tools-cri-o.bash
sudo ./init-hetzner-vswitch.bash 10.0.0.12/24  # Use unique IP for each control plane
```

#### Step 4: Get Join Credentials from Existing Control Plane
```
# Get token and hash
kubeadm token create --print-join-command

# Get certificate key (needed for control plane join)
kubeadm init phase upload-certs --upload-certs
```

#### Step 5: Join as Control Plane
```
sudo ./join-additional-control-plane.bash <EXISTING_CP_IP> <TOKEN> <CA_HASH> <CERT_KEY> [HOSTNAME]

# Example:
sudo ./join-additional-control-plane.bash 10.0.0.10 abcdef.token sha256:xxx certkey123 cp-2
```

The script validates:
- Both nodes have vlan4000 interface configured
- Both IPs are in the same vSwitch subnet
- Connectivity to existing control plane (API server and etcd)
- Configures certificates with proper SANs for the new control plane

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

## Installing Metrics Server (kubectl top)

To enable `kubectl top nodes` and `kubectl top pods`, install the metrics-server:

```
sudo perl install-metrics-server.pl
```

The script:
- Verifies it's running on a control plane node
- Checks all nodes are Ready with valid IPs/hostnames
- Validates kubelet and API server certificates
- Tests kubelet connectivity on all nodes
- If metrics-server exists and works: reports status and exits
- If TLS issues detected: offers to fix or use `--kubelet-insecure-tls`
- Installs/reinstalls metrics-server as needed

Options:
- `--force` - Skip checks and reinstall
- `--insecure-tls` - Use `--kubelet-insecure-tls` flag (bypasses cert verification)

## Installing Node Problem Detector

Detects node-level problems: kernel deadlocks, filesystem issues, container runtime problems.

```
sudo perl install-node-problem-detector.pl
```

The script:
- Deploys NPD as a DaemonSet on all nodes
- Monitors kernel messages, systemd logs, container runtime
- Adds node conditions: KernelDeadlock, ReadonlyFilesystem, FrequentKubeletRestart

Check node conditions:
```
kubectl describe node <node-name> | grep -A10 Conditions
kubectl get events --field-selector source=node-problem-detector
```

Options:
- `--force` - Reinstall
- `--uninstall` - Remove NPD

## etcd Backup and Restore

Backup and restore the Kubernetes etcd datastore (cluster state).

```
# Create backup (auto-generates timestamped filename)
sudo ./etcd-backup-restore.bash backup

# Create backup to specific file
sudo ./etcd-backup-restore.bash backup /path/to/backup.db

# List existing backups
./etcd-backup-restore.bash list

# Verify backup integrity
./etcd-backup-restore.bash verify /path/to/backup.db

# Restore from backup (DESTRUCTIVE - replaces current state)
sudo ./etcd-backup-restore.bash restore /path/to/backup.db
```

The script:
- Checks if running on control plane with etcd
- Checks if etcdctl is installed (suggests install command if not)
- Uses proper etcd certificates from /etc/kubernetes/pki/etcd/
- Verifies backup integrity after creation
- Keeps last 10 backups automatically
- Backs up current data before restore

Default backup location: `/var/backups/etcd/`

**If etcdctl is not installed:**
```
sudo apt-get update && sudo apt-get install -y etcd-client
```

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
