#!/usr/bin/env bash
# Create any missing secret files under secrets/ as commented-out templates.
# Existing files are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="${ROOT}/secrets"

# Write stdin to a secret file, unless it already exists.
template() {
    local dest=$1
    if [[ -e ${dest} ]]; then
        echo "exists:  ${dest#"${ROOT}"/}"
        cat >/dev/null
    else
        # Not install -D /dev/stdin: macOS's install can't read a pipe.
        mkdir -p "$(dirname "${dest}")"
        (umask 077 && cat >"${dest}")
        echo "created: ${dest#"${ROOT}"/}  (edit it)"
    fi
}

mkdir -p "${SECRETS}"/{wifi,wireguard,ssh}
chmod 700 "${SECRETS}" "${SECRETS}"/{wifi,wireguard,ssh}

template "${SECRETS}/wireguard/wg0.conf" <<'EOF'
# WireGuard config for this image, in wg-quick(8) format.
# The private key should be unique to this image: just keygen
# Uncomment and fill in, or leave it all commented out to build without
# WireGuard:
#
# [Interface]
# PrivateKey = <this image's private key>
# Address = 10.0.0.2/32
# Optional, resolved via systemd-resolved:
# DNS = 10.0.0.1
#
# [Peer]
# PublicKey = <peer's public key>
# Endpoint = vpn.example.com:51820
# AllowedIPs = 10.0.0.0/24
# Required, so the peer can reach this image through NAT:
# PersistentKeepalive = 25
EOF

template "${SECRETS}/ssh/authorized_keys" <<'EOF'
# Public keys allowed to SSH in as root, one per line (OpenSSH format).
# Uncomment and replace with your own:
#
# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... you@laptop
EOF

template "${SECRETS}/webhook.env" <<'EOF'
# Webhook POSTed once at boot, after WireGuard connects (or fails to),
# with a plain-text message (Content-Type: text/plain) listing the LAN,
# public and WireGuard addresses, or the WireGuard error.
# Works with e.g. a matrix-hookshot generic webhook. Leave commented out
# to disable.
#
# WEBHOOK_URL=https://hookshot.example.com/webhook/abcdef
EOF

if [[ -n $(find "${SECRETS}/wifi" -maxdepth 1 -type f \( -name '*.psk' -o -name '*.open' -o -name '*.8021x' \)) ]]; then
    echo "exists:  secrets/wifi/ networks"
else
    template "${SECRETS}/wifi/EXAMPLE.psk.example" <<'EOF'
# iwd network file, see iwd.network(5). Copy to secrets/wifi/<SSID>.psk
# (one file per network; .example files are ignored by the build).
#
# Filename: the SSID as-is if it only has letters, digits, space, - and _.
# Otherwise "=" + the SSID's bytes in hex:
#   echo "=$(printf '%s' 'Café' | od -An -tx1 | tr -d ' \n').psk"
# Open networks use <SSID>.open (may be empty).
#
# [Security]
# Passphrase=your wifi password
#
# [Settings]
# Hidden=true
EOF
fi
