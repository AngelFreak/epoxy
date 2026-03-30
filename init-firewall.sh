#!/usr/bin/env bash
set -euo pipefail

# ── Egress firewall (iptables allowlist) ──────────────────────────
# Resolves domains to IPs and allows only those destinations.

# DNS server from resolv.conf
DNS_SERVER=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null || echo "8.8.8.8")

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true
iptables -F INPUT 2>/dev/null || true

# Default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Established / related
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS
iptables -A OUTPUT -p udp -d "$DNS_SERVER" --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d "$DNS_SERVER" --dport 53 -j ACCEPT

# Domain allowlist
ALLOWED_DOMAINS=(
    api.anthropic.com
    statsig.anthropic.com
    sentry.io
    registry.npmjs.org
    registry.yarnpkg.com
    github.com
    api.github.com
    raw.githubusercontent.com
    pypi.org
    files.pythonhosted.org
    deb.debian.org
    security.debian.org
    archive.ubuntu.com
    proxy.golang.org
    sum.golang.org
)

# Extra domains from env
if [ -n "${EXTRA_FW_DOMAINS:-}" ]; then
    IFS=',' read -ra EXTRA <<< "$EXTRA_FW_DOMAINS"
    ALLOWED_DOMAINS+=("${EXTRA[@]}")
fi

# Resolve and allow each domain
for domain in "${ALLOWED_DOMAINS[@]}"; do
    domain=$(echo "$domain" | tr -d '[:space:]')
    [ -z "$domain" ] && continue

    IPS=$(getent ahosts "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u || true)
    for ip in $IPS; do
        [ -z "$ip" ] && continue
        iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -p tcp -d "$ip" --dport 80 -j ACCEPT 2>/dev/null || true
    done
done

# SSH outbound
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT

# Log and drop everything else
iptables -A OUTPUT -j LOG --log-prefix "SANDBOX-DROPPED: " --log-level 4 2>/dev/null || true
iptables -A OUTPUT -j DROP

# Verification
echo "   Testing connectivity to api.anthropic.com..."
if curl -sf --max-time 5 -o /dev/null https://api.anthropic.com 2>/dev/null; then
    echo "   ✓ Egress firewall verified"
else
    echo "   ⚠ Connectivity test inconclusive (may be normal without valid API key)"
fi
