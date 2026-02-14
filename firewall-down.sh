#!/bin/bash
# firewall-down.sh — Remove all firewall rules and restore full network access.
# Usage: sudo ./firewall-down.sh

set -euo pipefail

LOCK_FILE="/run/claude-firewall.lock"
IPSET_NAME="allowed-domains"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

log_info "Tearing down firewall..."

# IPv4: set ACCEPT policies, then flush
iptables -P INPUT ACCEPT   || true
iptables -P FORWARD ACCEPT || true
iptables -P OUTPUT ACCEPT  || true
iptables -F                || true
iptables -X                || true
iptables -t nat -F         || true
iptables -t nat -X         || true
iptables -t mangle -F      || true
iptables -t mangle -X      || true

# IPv6: set ACCEPT policies, then flush
ip6tables -P INPUT ACCEPT   || true
ip6tables -P FORWARD ACCEPT || true
ip6tables -P OUTPUT ACCEPT  || true
ip6tables -F                || true
ip6tables -X                || true
ip6tables -t nat -F         || true
ip6tables -t nat -X         || true
ip6tables -t mangle -F      || true
ip6tables -t mangle -X      || true

# Destroy ipset
ipset destroy "$IPSET_NAME" || true

# Remove lock file
rm -f "$LOCK_FILE"

log_info "Firewall is DOWN. Full network access restored."
