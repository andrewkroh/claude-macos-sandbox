#!/bin/bash
# Shared config loader for claude-setup scripts.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Derive the repository directory from this file's location.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load user configuration.
CONF_FILE="${REPO_DIR}/sandbox.conf"
if [[ ! -f "${CONF_FILE}" ]]; then
    log_error "Missing configuration file: ${CONF_FILE}"
    echo "  cp sandbox.conf.example sandbox.conf   # then edit sandbox.conf" >&2
    exit 1
fi
# shellcheck source=sandbox.conf.example
source "${CONF_FILE}"
