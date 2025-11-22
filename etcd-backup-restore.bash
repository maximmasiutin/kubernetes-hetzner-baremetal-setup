#!/bin/bash

# etcd-backup-restore.bash - Backup and restore Kubernetes etcd datastore
#
# Usage:
#   ./etcd-backup-restore.bash backup [BACKUP_FILE]    # Create backup
#   ./etcd-backup-restore.bash restore <BACKUP_FILE>   # Restore from backup
#   ./etcd-backup-restore.bash list                    # List existing backups
#   ./etcd-backup-restore.bash verify <BACKUP_FILE>    # Verify backup integrity

set -e

# Default backup directory
BACKUP_DIR="/var/backups/etcd"
ETCD_CERT_DIR="/etc/kubernetes/pki/etcd"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${NC}[INFO]  $1${NC}"; }
log_ok()    { echo -e "${GREEN}[OK]    $1${NC}"; }
log_warn()  { echo -e "${YELLOW}[WARN]  $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

show_help() {
    echo "etcd Backup and Restore Tool"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  backup [FILE]     Create etcd snapshot backup"
    echo "                    FILE: optional backup filename (default: etcd-backup-TIMESTAMP.db)"
    echo "  restore <FILE>    Restore etcd from snapshot"
    echo "                    FILE: path to backup file (required)"
    echo "  list              List existing backups in $BACKUP_DIR"
    echo "  verify <FILE>     Verify backup file integrity"
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 backup                           # Backup to default location"
    echo "  $0 backup /path/to/my-backup.db     # Backup to specific file"
    echo "  $0 restore /var/backups/etcd/etcd-backup-20240101-120000.db"
    echo "  $0 list"
    echo "  $0 verify /path/to/backup.db"
    echo ""
    echo "Backup location: $BACKUP_DIR"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_control_plane() {
    log_info "Checking if this is a control plane node..."

    # Check for admin.conf
    if [ ! -f "/etc/kubernetes/admin.conf" ]; then
        log_error "Not a control plane node: /etc/kubernetes/admin.conf not found"
        exit 1
    fi

    # Check for etcd manifest (static pod)
    if [ ! -f "/etc/kubernetes/manifests/etcd.yaml" ]; then
        log_error "etcd manifest not found: /etc/kubernetes/manifests/etcd.yaml"
        log_error "This node may not be running etcd (external etcd cluster?)"
        exit 1
    fi

    # Check for etcd certificates
    if [ ! -d "$ETCD_CERT_DIR" ]; then
        log_error "etcd certificate directory not found: $ETCD_CERT_DIR"
        exit 1
    fi

    log_ok "Running on control plane node with etcd"
}

check_etcdctl() {
    log_info "Checking if etcdctl is installed..."

    if command -v etcdctl &> /dev/null; then
        ETCDCTL_VERSION=$(etcdctl version 2>/dev/null | head -1 || echo "unknown")
        log_ok "etcdctl is installed: $ETCDCTL_VERSION"
        return 0
    fi

    log_error "etcdctl is not installed!"
    echo ""
    echo "To install etcdctl on Ubuntu, run:"
    echo ""
    echo "  sudo apt-get update && sudo apt-get install -y etcd-client"
    echo ""
    echo "Or download from GitHub releases:"
    echo ""
    echo "  ETCD_VERSION=v3.5.12"
    echo "  curl -fsSL https://github.com/etcd-io/etcd/releases/download/\${ETCD_VERSION}/etcd-\${ETCD_VERSION}-linux-amd64.tar.gz | \\"
    echo "    sudo tar -xzf - -C /usr/local/bin --strip-components=1 etcd-\${ETCD_VERSION}-linux-amd64/etcdctl"
    echo ""
    echo "After installing etcdctl, run this script again."
    exit 1
}

get_etcd_endpoint() {
    # Try to get etcd endpoint from the manifest
    local endpoint=""

    if [ -f "/etc/kubernetes/manifests/etcd.yaml" ]; then
        endpoint=$(grep -oP '(?<=--listen-client-urls=)https://[^,\s]+' /etc/kubernetes/manifests/etcd.yaml 2>/dev/null | head -1)
    fi

    if [ -z "$endpoint" ]; then
        # Default to localhost
        endpoint="https://127.0.0.1:2379"
    fi

    echo "$endpoint"
}

# Common etcdctl command with certificates
run_etcdctl() {
    local endpoint=$(get_etcd_endpoint)

    ETCDCTL_API=3 etcdctl \
        --endpoints="$endpoint" \
        --cacert="${ETCD_CERT_DIR}/ca.crt" \
        --cert="${ETCD_CERT_DIR}/server.crt" \
        --key="${ETCD_CERT_DIR}/server.key" \
        "$@"
}

do_backup() {
    local backup_file="$1"

    # Generate default backup filename if not provided
    if [ -z "$backup_file" ]; then
        mkdir -p "$BACKUP_DIR"
        local timestamp=$(date +%Y%m%d-%H%M%S)
        backup_file="${BACKUP_DIR}/etcd-backup-${timestamp}.db"
    fi

    # Ensure parent directory exists
    local backup_dir=$(dirname "$backup_file")
    if [ ! -d "$backup_dir" ]; then
        log_info "Creating backup directory: $backup_dir"
        mkdir -p "$backup_dir"
    fi

    log_info "Creating etcd snapshot backup..."
    log_info "Backup file: $backup_file"
    echo ""

    # Check etcd health first
    log_info "Checking etcd cluster health..."
    if run_etcdctl endpoint health 2>&1 | grep -q "is healthy"; then
        log_ok "etcd cluster is healthy"
    else
        log_warn "etcd health check returned warnings (continuing anyway)"
    fi

    # Create snapshot
    log_info "Creating snapshot..."
    if run_etcdctl snapshot save "$backup_file"; then
        log_ok "Snapshot created successfully"
    else
        log_error "Failed to create snapshot"
        exit 1
    fi

    # Verify the backup
    log_info "Verifying backup integrity..."
    if ETCDCTL_API=3 etcdctl snapshot status "$backup_file" --write-out=table; then
        log_ok "Backup verified successfully"
    else
        log_warn "Could not verify backup (file may still be valid)"
    fi

    # Show backup info
    local backup_size=$(du -h "$backup_file" | cut -f1)
    echo ""
    echo "========================================"
    log_ok "Backup completed!"
    echo "========================================"
    echo ""
    echo "Backup file: $backup_file"
    echo "Size: $backup_size"
    echo ""
    echo "To restore from this backup:"
    echo "  sudo $0 restore $backup_file"
    echo ""

    # Cleanup old backups (keep last 10)
    if [ -d "$BACKUP_DIR" ]; then
        local backup_count=$(ls -1 "$BACKUP_DIR"/etcd-backup-*.db 2>/dev/null | wc -l)
        if [ "$backup_count" -gt 10 ]; then
            log_info "Cleaning up old backups (keeping last 10)..."
            ls -1t "$BACKUP_DIR"/etcd-backup-*.db | tail -n +11 | xargs rm -f
        fi
    fi
}

do_restore() {
    local backup_file="$1"

    if [ -z "$backup_file" ]; then
        log_error "Backup file path is required for restore"
        echo ""
        echo "Usage: $0 restore <BACKUP_FILE>"
        exit 1
    fi

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi

    echo ""
    echo "========================================"
    echo "         etcd RESTORE WARNING"
    echo "========================================"
    echo ""
    log_warn "This will REPLACE the current etcd data!"
    log_warn "All current cluster state will be LOST!"
    echo ""
    echo "Backup file: $backup_file"
    echo ""

    # Verify backup first
    log_info "Verifying backup file..."
    if ! ETCDCTL_API=3 etcdctl snapshot status "$backup_file" --write-out=table 2>/dev/null; then
        log_error "Backup file appears to be invalid or corrupted"
        exit 1
    fi
    log_ok "Backup file is valid"

    echo ""
    read -p "Are you SURE you want to restore? Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi

    echo ""
    log_info "Starting restore process..."

    # Get current etcd data directory
    local etcd_data_dir="/var/lib/etcd"
    if [ -f "/etc/kubernetes/manifests/etcd.yaml" ]; then
        local yaml_data_dir=$(grep -oP '(?<=--data-dir=)[^\s]+' /etc/kubernetes/manifests/etcd.yaml 2>/dev/null | head -1)
        if [ -n "$yaml_data_dir" ]; then
            etcd_data_dir="$yaml_data_dir"
        fi
    fi

    log_info "etcd data directory: $etcd_data_dir"

    # Get node name for restore
    local node_name=$(hostname)
    local initial_cluster="${node_name}=https://127.0.0.1:2380"

    # Check if we can get the actual peer URL
    if [ -f "/etc/kubernetes/manifests/etcd.yaml" ]; then
        local peer_url=$(grep -oP '(?<=--initial-advertise-peer-urls=)[^\s]+' /etc/kubernetes/manifests/etcd.yaml 2>/dev/null | head -1)
        if [ -n "$peer_url" ]; then
            initial_cluster="${node_name}=${peer_url}"
        fi
    fi

    # Stop kubelet to stop etcd
    log_info "Stopping kubelet..."
    systemctl stop kubelet

    # Wait for etcd to stop
    log_info "Waiting for etcd to stop..."
    sleep 5

    # Check if etcd container is still running
    if command -v crictl &> /dev/null; then
        local etcd_container=$(crictl ps -q --name etcd 2>/dev/null)
        if [ -n "$etcd_container" ]; then
            log_info "Stopping etcd container..."
            crictl stop "$etcd_container" 2>/dev/null || true
            sleep 3
        fi
    fi

    # Backup current etcd data
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local old_data_backup="${etcd_data_dir}.pre-restore-${timestamp}"
    if [ -d "$etcd_data_dir" ]; then
        log_info "Backing up current etcd data to: $old_data_backup"
        mv "$etcd_data_dir" "$old_data_backup"
    fi

    # Restore snapshot
    log_info "Restoring snapshot to: $etcd_data_dir"

    ETCDCTL_API=3 etcdctl snapshot restore "$backup_file" \
        --data-dir="$etcd_data_dir" \
        --name="$node_name" \
        --initial-cluster="$initial_cluster" \
        --initial-advertise-peer-urls="https://127.0.0.1:2380" \
        --skip-hash-check=true

    if [ $? -ne 0 ]; then
        log_error "Snapshot restore failed!"
        log_info "Attempting to restore original data..."
        if [ -d "$old_data_backup" ]; then
            rm -rf "$etcd_data_dir"
            mv "$old_data_backup" "$etcd_data_dir"
        fi
        systemctl start kubelet
        exit 1
    fi

    log_ok "Snapshot restored successfully"

    # Fix permissions
    log_info "Fixing etcd data directory permissions..."
    chown -R root:root "$etcd_data_dir"

    # Start kubelet
    log_info "Starting kubelet..."
    systemctl start kubelet

    # Wait for etcd to start
    log_info "Waiting for etcd to start (this may take a minute)..."
    sleep 30

    # Check etcd health
    local max_attempts=12
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        log_info "Checking etcd health (attempt $attempt/$max_attempts)..."
        if run_etcdctl endpoint health 2>&1 | grep -q "is healthy"; then
            log_ok "etcd is healthy!"
            break
        fi
        sleep 10
        attempt=$((attempt + 1))
    done

    if [ $attempt -gt $max_attempts ]; then
        log_warn "etcd health check timed out"
        log_info "Check etcd logs: crictl logs \$(crictl ps -q --name etcd)"
    fi

    echo ""
    echo "========================================"
    log_ok "Restore completed!"
    echo "========================================"
    echo ""
    echo "Previous data backed up to: $old_data_backup"
    echo ""
    echo "Verify cluster status:"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo ""
    log_warn "If this is a multi-node cluster, you may need to:"
    log_warn "  1. Restore the same backup on all control plane nodes"
    log_warn "  2. Or remove and re-join other control plane nodes"
}

do_list() {
    echo "Existing etcd backups in $BACKUP_DIR:"
    echo ""

    if [ ! -d "$BACKUP_DIR" ]; then
        log_info "Backup directory does not exist: $BACKUP_DIR"
        return
    fi

    local count=0
    for backup in $(ls -1t "$BACKUP_DIR"/etcd-backup-*.db 2>/dev/null); do
        local size=$(du -h "$backup" | cut -f1)
        local date=$(stat -c %y "$backup" 2>/dev/null | cut -d. -f1)
        echo "  $backup"
        echo "    Size: $size, Created: $date"
        count=$((count + 1))
    done

    if [ $count -eq 0 ]; then
        log_info "No backups found"
    else
        echo ""
        echo "Total: $count backup(s)"
    fi
}

do_verify() {
    local backup_file="$1"

    if [ -z "$backup_file" ]; then
        log_error "Backup file path is required"
        echo "Usage: $0 verify <BACKUP_FILE>"
        exit 1
    fi

    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi

    log_info "Verifying backup: $backup_file"
    echo ""

    if ETCDCTL_API=3 etcdctl snapshot status "$backup_file" --write-out=table; then
        echo ""
        log_ok "Backup file is valid"
    else
        log_error "Backup file is invalid or corrupted"
        exit 1
    fi
}

# Main
case "${1:-}" in
    backup)
        check_root
        check_control_plane
        check_etcdctl
        do_backup "$2"
        ;;
    restore)
        check_root
        check_control_plane
        check_etcdctl
        do_restore "$2"
        ;;
    list)
        do_list
        ;;
    verify)
        check_etcdctl
        do_verify "$2"
        ;;
    -h|--help|help|"")
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
