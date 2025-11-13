#!/bin/bash

KUBERNETES_VERSION=v1.34
CRIO_VERSION=v1.34

echo "Installing Kubernetes tools and CRI-O runtime..."

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common 

# Add Kubernetes apt repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Add CRI-O apt repository
curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/cri-o.list

# Install CRI-O and Kubernetes tools
sudo apt-get update
sudo apt-get install -y cri-o kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Start and enable CRI-O
sudo systemctl start crio.service
sudo systemctl enable crio.service

# Enable kubelet
sudo systemctl enable kubelet

echo ""
echo "Installation complete!"
echo "Container runtime: CRI-O"
echo "Kubernetes version: $KUBERNETES_VERSION"
echo ""
echo "Verify installation:"
echo "  sudo systemctl status crio"
echo "  kubeadm version"
echo "  kubectl version --client"
