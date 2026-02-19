#!/bin/bash
# Start or connect to the cc-sandbox VM
# Usage: ./start-cc-sandbox.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Derive the bootstrap script path inside the VM.
# Strip the HOST_MOUNT prefix from REPO_DIR and prepend VM_MOUNT.
if [[ "${REPO_DIR}" != "${HOST_MOUNT}"* ]]; then
    log_error "This repository (${REPO_DIR}) is not under HOST_MOUNT (${HOST_MOUNT})."
    log_error "Update HOST_MOUNT in sandbox.conf so it contains this repo."
    exit 1
fi
REPO_REL="${REPO_DIR#"${HOST_MOUNT}"}"
BOOTSTRAP_SCRIPT="${VM_MOUNT}${REPO_REL}/bootstrap-ubuntu-24.04.sh"

if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
    log_warn "SSH_PUBLIC_KEY is empty in sandbox.conf — VM will not have SSH key access."
fi

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
log_info "Launching VM with ${VM_CPUS} CPUs, ${VM_MEMORY} memory, ${VM_DISK} disk..."
multipass launch 24.04 \
    --name "${VM_NAME}" \
    --cpus "${VM_CPUS}" \
    --memory "${VM_MEMORY}" \
    --disk "${VM_DISK}" \
    --mount "${HOST_MOUNT}:${VM_MOUNT}"

# Wait for VM to be fully ready
log_info "Waiting for VM to be ready..."
sleep 10

# Verify mount is available
log_info "Verifying mount..."
if ! multipass exec "${VM_NAME}" -- test -d "${VM_MOUNT}"; then
    log_warn "Mount not available, attempting to mount..."
    multipass mount "${HOST_MOUNT}" "${VM_NAME}:${VM_MOUNT}"
    sleep 2
fi

# Run bootstrap script
log_info "Running bootstrap script..."
multipass exec "${VM_NAME}" -- sudo bash "${BOOTSTRAP_SCRIPT}"

print_ssh_command
