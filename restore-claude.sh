#!/bin/bash
# Restore Claude Code configuration and state
# Usage: restore-claude.sh [backup-file]
#        restore-claude.sh                    # restores latest backup
#        restore-claude.sh claude-backup-20240101-120000.tar.gz

set -euo pipefail

BACKUP_DIR="/home/ubuntu/code/andrewkroh/claude-setup/backups"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Determine which backup to restore
if [[ $# -ge 1 ]]; then
    # User specified a backup file
    if [[ -f "$1" ]]; then
        BACKUP_FILE="$1"
    elif [[ -f "${BACKUP_DIR}/$1" ]]; then
        BACKUP_FILE="${BACKUP_DIR}/$1"
    else
        log_error "Backup file not found: $1"
        exit 1
    fi
else
    # Find latest backup
    BACKUP_FILE=$(ls -t "${BACKUP_DIR}"/claude-backup-*.tar.gz 2>/dev/null | head -1)
    if [[ -z "${BACKUP_FILE}" ]]; then
        log_error "No backups found in ${BACKUP_DIR}"
        exit 1
    fi
fi

log_info "Restoring from: ${BACKUP_FILE}"

# Show what's in the backup
echo ""
log_info "Backup contents:"
tar -tzf "${BACKUP_FILE}" | head -20
echo ""

# Confirm
read -p "Restore these files to ~/ ? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warn "Aborted"
    exit 1
fi

# Restore
cd ~
tar -xzf "${BACKUP_FILE}"

log_info "Restore complete!"
