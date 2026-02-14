#!/bin/bash
# Backup Claude Code configuration and state
# Usage: backup-claude.sh

set -euo pipefail

BACKUP_DIR="/home/ubuntu/code/andrewkroh/claude-setup/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/claude-backup-${TIMESTAMP}.tar.gz"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Files/directories to backup
BACKUP_SOURCES=()

if [[ -d ~/.claude ]]; then
    BACKUP_SOURCES+=(".claude")
fi

if [[ -f ~/.claude.json ]]; then
    BACKUP_SOURCES+=(".claude.json")
fi

if [[ ${#BACKUP_SOURCES[@]} -eq 0 ]]; then
    log_warn "No Claude files found to backup"
    exit 1
fi

log_info "Backing up Claude files..."
for src in "${BACKUP_SOURCES[@]}"; do
    echo "  - ~/${src}"
done

# Create tarball
cd ~
tar -czf "${BACKUP_FILE}" "${BACKUP_SOURCES[@]}"

log_info "Backup created: ${BACKUP_FILE}"
ls -lh "${BACKUP_FILE}"

# Keep only last 5 backups
log_info "Cleaning old backups (keeping last 5)..."
ls -t "${BACKUP_DIR}"/claude-backup-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f

echo ""
log_info "Done! Backups in ${BACKUP_DIR}:"
ls -lht "${BACKUP_DIR}"/claude-backup-*.tar.gz 2>/dev/null | head -5
