#!/bin/bash
# Start or connect to the cc-sandbox VM
# Usage: ./start-cc-sandbox.sh

set -euo pipefail

VM_NAME="cc-sandbox"
CPUS=4
MEMORY="8G"
DISK="50G"
MOUNT_SOURCE="/Users/akroh/code"
MOUNT_TARGET="/home/ubuntu/code"
BOOTSTRAP_SCRIPT="/home/ubuntu/code/andrewkroh/claude-setup/bootstrap-ubuntu-24.04.sh"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

get_vm_ip() {
    multipass info "${VM_NAME}" --format json | jq -r '.info["'"${VM_NAME}"'"].ipv4[0]'
}

get_vm_state() {
    multipass info "${VM_NAME}" --format json 2>/dev/null | jq -r '.info["'"${VM_NAME}"'"].state' || echo "NotFound"
}

print_ssh_command() {
    local ip
    ip=$(get_vm_ip)
    echo ""
    echo "========================================"
    log_info "VM '${VM_NAME}' is running"
    echo "========================================"
    echo ""
    echo "Connect with:"
    echo "  ssh ubuntu@${ip}"
    echo ""
    echo "Or use multipass:"
    echo "  multipass shell ${VM_NAME}"
    echo ""
}

# Check current VM state
STATE=$(get_vm_state)

case "${STATE}" in
    "Running")
        print_ssh_command
        exit 0
        ;;
    "Stopped")
        log_info "Starting stopped VM '${VM_NAME}'..."
        multipass start "${VM_NAME}"
        # Wait for VM to be ready
        sleep 5
        print_ssh_command
        exit 0
        ;;
    "Suspended")
        log_info "Resuming suspended VM '${VM_NAME}'..."
        multipass start "${VM_NAME}"
        sleep 5
        print_ssh_command
        exit 0
        ;;
    "NotFound")
        log_info "Creating new VM '${VM_NAME}'..."
        ;;
    *)
        log_warn "VM '${VM_NAME}' is in state '${STATE}'. Attempting to start..."
        multipass start "${VM_NAME}" || true
        sleep 5
        print_ssh_command
        exit 0
        ;;
esac

# Create new VM
log_info "Launching VM with ${CPUS} CPUs, ${MEMORY} memory, ${DISK} disk..."
multipass launch 24.04 \
    --name "${VM_NAME}" \
    --cpus "${CPUS}" \
    --memory "${MEMORY}" \
    --disk "${DISK}" \
    --mount "${MOUNT_SOURCE}:${MOUNT_TARGET}"

# Wait for VM to be fully ready
log_info "Waiting for VM to be ready..."
sleep 10

# Verify mount is available
log_info "Verifying mount..."
if ! multipass exec "${VM_NAME}" -- test -d "${MOUNT_TARGET}"; then
    log_warn "Mount not available, attempting to mount..."
    multipass mount "${MOUNT_SOURCE}" "${VM_NAME}:${MOUNT_TARGET}"
    sleep 2
fi

# Run bootstrap script
log_info "Running bootstrap script..."
multipass exec "${VM_NAME}" -- sudo bash "${BOOTSTRAP_SCRIPT}"

print_ssh_command
