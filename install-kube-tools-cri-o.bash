#!/bin/bash

# Install Kubernetes tools and CRI-O container runtime
# Auto-detects latest versions or allows specifying version
#
# Usage:
#   ./install-kube-tools-cri-o.bash              # Install latest version
#   ./install-kube-tools-cri-o.bash --previous   # Install previous stable version
#   ./install-kube-tools-cri-o.bash --version 1.32  # Install specific version
#   ./install-kube-tools-cri-o.bash --list       # List available versions

set -e

# Parse command line arguments
VERSION_ARG=""
SHOW_LIST=0
USE_PREVIOUS=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            VERSION_ARG="$2"
            shift 2
            ;;
        -p|--previous)
            USE_PREVIOUS=1
            shift
            ;;
        -l|--list)
            SHOW_LIST=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -v, --version VERSION  Install specific version (e.g., 1.32, 1.31)"
            echo "  -p, --previous         Install previous stable version"
            echo "  -l, --list             List available Kubernetes versions"
            echo "  -h, --help             Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                     # Install latest version"
            echo "  $0 --previous          # Install previous stable version"
            echo "  $0 --version 1.32      # Install version 1.32"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Function to get available Kubernetes versions from pkgs.k8s.io
get_available_versions() {
    echo "Fetching available Kubernetes versions..." >&2
    # Try to get versions from the Kubernetes release page
    local versions=$(curl -fsSL "https://api.github.com/repos/kubernetes/kubernetes/releases" 2>/dev/null | \
        grep -oP '"tag_name":\s*"v\K[0-9]+\.[0-9]+' | \
        sort -t. -k1,1n -k2,2n | uniq | tail -10)

    if [ -z "$versions" ]; then
        # Fallback: try dl.k8s.io
        local latest=$(curl -fsSL "https://dl.k8s.io/release/stable.txt" 2>/dev/null | grep -oP '^v\K[0-9]+\.[0-9]+')
        if [ -n "$latest" ]; then
            local major=$(echo "$latest" | cut -d. -f1)
            local minor=$(echo "$latest" | cut -d. -f2)
            # Generate last 5 versions
            for i in $(seq 0 4); do
                local v=$((minor - i))
                if [ $v -gt 0 ]; then
                    echo "${major}.${v}"
                fi
            done
        fi
    else
        echo "$versions"
    fi
}

# Function to get the latest stable version
get_latest_version() {
    local latest=$(curl -fsSL "https://dl.k8s.io/release/stable.txt" 2>/dev/null | grep -oP '^v\K[0-9]+\.[0-9]+')
    if [ -z "$latest" ]; then
        # Fallback to GitHub API
        latest=$(curl -fsSL "https://api.github.com/repos/kubernetes/kubernetes/releases/latest" 2>/dev/null | \
            grep -oP '"tag_name":\s*"v\K[0-9]+\.[0-9]+' | head -1)
    fi
    echo "$latest"
}

# Function to get the previous stable version
get_previous_version() {
    local latest="$1"
    local major=$(echo "$latest" | cut -d. -f1)
    local minor=$(echo "$latest" | cut -d. -f2)
    local prev_minor=$((minor - 1))
    if [ $prev_minor -lt 1 ]; then
        prev_minor=1
    fi
    echo "${major}.${prev_minor}"
}

# Function to verify version exists
verify_version_exists() {
    local version="$1"
    local url="https://pkgs.k8s.io/core:/stable:/v${version}/deb/Release"
    if curl -fsSL --head "$url" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Function to verify CRI-O version exists
verify_crio_version_exists() {
    local version="$1"
    local url="https://download.opensuse.org/repositories/isv:/cri-o:/stable:/v${version}/deb/Release"
    if curl -fsSL --head "$url" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Show available versions and exit
if [ $SHOW_LIST -eq 1 ]; then
    echo "Available Kubernetes versions:"
    echo "==============================="
    versions=$(get_available_versions)
    latest=$(get_latest_version)
    for v in $versions; do
        if [ "$v" = "$latest" ]; then
            echo "  $v (latest)"
        else
            echo "  $v"
        fi
    done
    echo ""
    echo "Note: CRI-O versions typically match Kubernetes minor versions"
    exit 0
fi

# Determine version to install
echo "========================================"
echo "Kubernetes + CRI-O Installation"
echo "========================================"
echo ""

echo "Detecting available versions..."
LATEST_VERSION=$(get_latest_version)

if [ -z "$LATEST_VERSION" ]; then
    echo "Error: Could not detect latest Kubernetes version"
    echo "Please check your internet connection or specify version manually:"
    echo "  $0 --version 1.32"
    exit 1
fi

echo "Latest available version: $LATEST_VERSION"

if [ -n "$VERSION_ARG" ]; then
    # User specified version
    # Normalize version (remove 'v' prefix if present, handle formats like "1.32" or "v1.32")
    KUBERNETES_VERSION=$(echo "$VERSION_ARG" | sed 's/^v//')
    echo "Using specified version: $KUBERNETES_VERSION"
elif [ $USE_PREVIOUS -eq 1 ]; then
    # Use previous version
    KUBERNETES_VERSION=$(get_previous_version "$LATEST_VERSION")
    echo "Using previous stable version: $KUBERNETES_VERSION"
else
    # Use latest
    KUBERNETES_VERSION="$LATEST_VERSION"
    echo "Using latest version: $KUBERNETES_VERSION"
fi

# Verify Kubernetes version exists
echo ""
echo "Verifying Kubernetes v$KUBERNETES_VERSION repository..."
if ! verify_version_exists "$KUBERNETES_VERSION"; then
    echo "Error: Kubernetes version $KUBERNETES_VERSION not found in repository"
    echo "Use --list to see available versions"
    exit 1
fi
echo "Kubernetes v$KUBERNETES_VERSION: OK"

# CRI-O version (same minor version as Kubernetes)
CRIO_VERSION="$KUBERNETES_VERSION"
echo "Verifying CRI-O v$CRIO_VERSION repository..."
if ! verify_crio_version_exists "$CRIO_VERSION"; then
    echo "Warning: CRI-O v$CRIO_VERSION not found, trying to find compatible version..."
    # Try to find a compatible CRI-O version
    major=$(echo "$KUBERNETES_VERSION" | cut -d. -f1)
    minor=$(echo "$KUBERNETES_VERSION" | cut -d. -f2)
    found=0
    for try_minor in $minor $((minor-1)) $((minor+1)); do
        try_version="${major}.${try_minor}"
        if verify_crio_version_exists "$try_version"; then
            CRIO_VERSION="$try_version"
            echo "Found compatible CRI-O version: $CRIO_VERSION"
            found=1
            break
        fi
    done
    if [ $found -eq 0 ]; then
        echo "Error: Could not find compatible CRI-O version"
        exit 1
    fi
else
    echo "CRI-O v$CRIO_VERSION: OK"
fi

# Format versions for repository URLs (need v prefix)
K8S_REPO_VERSION="v${KUBERNETES_VERSION}"
CRIO_REPO_VERSION="v${CRIO_VERSION}"

echo ""
echo "Will install:"
echo "  Kubernetes: $K8S_REPO_VERSION"
echo "  CRI-O:      $CRIO_REPO_VERSION"
echo ""
read -p "Continue? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Aborted"
    exit 0
fi

echo ""
echo "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common

# Create keyrings directory if not exists
sudo mkdir -p /etc/apt/keyrings

# Add Kubernetes apt repository
echo ""
echo "Adding Kubernetes repository..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_REPO_VERSION}/deb/Release.key" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_REPO_VERSION}/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list

# Add CRI-O apt repository
echo ""
echo "Adding CRI-O repository..."
curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_REPO_VERSION}/deb/Release.key" | \
    sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg --yes

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_REPO_VERSION}/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/cri-o.list

# Install CRI-O and Kubernetes tools
echo ""
echo "Installing packages..."
sudo apt-get update
sudo apt-get install -y cri-o kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Start and enable CRI-O
echo ""
echo "Starting CRI-O service..."
sudo systemctl start crio.service
sudo systemctl enable crio.service

# Enable kubelet
sudo systemctl enable kubelet

# Get installed versions
INSTALLED_K8S=$(kubeadm version -o short 2>/dev/null || echo "unknown")
INSTALLED_CRIO=$(crio --version 2>/dev/null | head -1 || echo "unknown")

echo ""
echo "========================================"
echo "Installation complete!"
echo "========================================"
echo ""
echo "Installed versions:"
echo "  Kubernetes: $INSTALLED_K8S"
echo "  CRI-O:      $INSTALLED_CRIO"
echo ""
echo "Verify installation:"
echo "  sudo systemctl status crio"
echo "  kubeadm version"
echo "  kubectl version --client"
