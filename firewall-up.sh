#!/bin/bash
# firewall-up.sh — Lock down outbound traffic to allowed domains only.
# Usage: sudo ./firewall-up.sh [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SCRIPT_DIR}/allowed-domains.conf"
IPSET_NAME="allowed-domains"
LOCK_FILE="/run/claude-firewall.lock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

for cmd in iptables ip6tables ipset dig curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

if [[ ! -f "$CONF" ]]; then
    log_error "Config file not found: $CONF"
    exit 1
fi

# --- Idempotency ---
FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

if ipset list "$IPSET_NAME" &>/dev/null && [[ $FORCE -eq 0 ]]; then
    log_info "Firewall already active (ipset '$IPSET_NAME' exists). Use --force to re-apply."
    exit 0
fi

if [[ $FORCE -eq 1 ]]; then
    log_info "Force mode: tearing down existing firewall first..."
    bash "${SCRIPT_DIR}/firewall-down.sh"
fi

log_info "Activating firewall..."

# --- Step 1: Flush and set temporary ACCEPT policies ---
iptables -F
iptables -X || true
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# --- Step 2: Base rules ---
# Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Conntrack (established/related)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Inbound SSH
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# Temporary wide DNS (needed for domain resolution below)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT

# --- Step 3: Build ipset ---
ipset create "$IPSET_NAME" hash:net

# GitHub CIDRs from /meta API
log_info "Fetching GitHub CIDRs..."
GH_CIDRS=$(curl -s --max-time 10 https://api.github.com/meta 2>/dev/null | jq -r '(.web + .api + .git)[]' 2>/dev/null || true)
for cidr in $GH_CIDRS; do
    # Filter to IPv4 only (contains a dot, no colon)
    if [[ "$cidr" == *.* && "$cidr" != *:* ]]; then
        ipset add "$IPSET_NAME" "$cidr" 2>/dev/null || true
    fi
done
log_info "Added GitHub CIDRs to ipset"

# Resolve domains from config
log_info "Resolving domains from $CONF..."
while IFS= read -r line; do
    # Strip comments and whitespace
    domain=$(echo "$line" | sed 's/#.*//' | xargs)
    [[ -z "$domain" ]] && continue

    ips=$(dig +short A "$domain" 2>/dev/null || true)
    if [[ -z "$ips" ]]; then
        log_warn "DNS lookup returned no results for: $domain"
        continue
    fi
    for ip in $ips; do
        # Skip non-IP lines (e.g. CNAMEs)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            ipset add "$IPSET_NAME" "$ip" 2>/dev/null || true
        fi
    done
done < "$CONF"
log_info "Domain resolution complete"

# --- Step 4: Allow local network ---
GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
if [[ -n "$GATEWAY" ]]; then
    # Derive /24 from gateway IP
    LOCAL_NET="${GATEWAY%.*}.0/24"
    iptables -A OUTPUT -d "$LOCAL_NET" -j ACCEPT
    log_info "Allowed local network: $LOCAL_NET"
fi

# --- Step 5: Allow ipset destinations ---
iptables -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j ACCEPT

# --- Step 6: Set DROP policies ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Explicit REJECT as last OUTPUT rule for fast client-side feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable

# --- Step 7: Tighten DNS ---
# Remove the wide UDP 53 rule (it was rule #4 in OUTPUT, after lo, conntrack, and temp DNS)
iptables -D OUTPUT -p udp --dport 53 -j ACCEPT

# Allow DNS only to nameservers listed in /etc/resolv.conf
while IFS= read -r ns; do
    if [[ -n "$ns" ]]; then
        iptables -I OUTPUT 3 -p udp -d "$ns" --dport 53 -j ACCEPT
        iptables -I OUTPUT 4 -p tcp -d "$ns" --dport 53 -j ACCEPT
        log_info "Allowed DNS to nameserver: $ns"
    fi
done < <(grep -oP '(?<=^nameserver\s)\S+' /etc/resolv.conf)

# --- Step 8: IPv6 lockdown ---
log_info "Locking down IPv6..."
ip6tables -F
ip6tables -X || true
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# --- Step 9: Write lock file ---
date -Iseconds > "$LOCK_FILE"

# --- Step 10: Verify ---
log_info "Verifying firewall..."

if curl -s --max-time 5 https://example.com &>/dev/null; then
    log_error "VERIFICATION FAILED: example.com is reachable (should be blocked)"
    exit 1
else
    log_info "Blocked traffic verified (example.com unreachable)"
fi

if curl -s --max-time 5 https://api.github.com/zen &>/dev/null; then
    log_info "Allowed traffic verified (api.github.com reachable)"
else
    log_warn "api.github.com unreachable — GitHub IPs may have changed"
fi

log_info "Firewall is UP. Lock file: $LOCK_FILE"
