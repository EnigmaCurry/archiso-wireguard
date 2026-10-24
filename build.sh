#!/usr/bin/env bash
# Build the arch-iso live ISO with secrets baked in.
#
# Copies archiso's stock releng profile, lays this repo's airootfs/ overlay
# and the git-ignored secrets/ on top, then runs mkarchiso (rootless).
# The resulting ISO contains secrets and is written to secrets/out/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELENG=/usr/share/archiso/configs/releng
SECRETS="${ROOT}/secrets"
BUILD="${SECRETS}/build"
PROFILE="${BUILD}/profile"
WORK="${BUILD}/work"
OUT="${SECRETS}/out"
SSH_HOST_KEY_TYPES=(ed25519 ecdsa rsa)

die() { echo "ERROR: $*" >&2; exit 1; }

# mkarchiso runs in a user namespace, so the work dir holds files owned by
# subordinate uids that only the namespace's root can delete.
clean_build() {
    [[ -e ${BUILD} ]] && unshare --map-auto --map-root-user -- rm -rf -- "${BUILD}"
    return 0
}

# iwd network files in secrets/wifi/ (other files, like templates, are ignored)
wifi_networks() {
    find "${SECRETS}/wifi" -maxdepth 1 -type f \
        \( -name '*.psk' -o -name '*.open' -o -name '*.8021x' \) 2>/dev/null
}

check_secrets() {
    local wg=${SECRETS}/wireguard/wg0.conf
    [[ -d ${RELENG} ]] || die "archiso is not installed (missing ${RELENG})"
    [[ -f ${wg} ]] || die "missing secrets/wireguard/wg0.conf (run: just config)"
    grep -qE '^\s*\[Interface\]' "${wg}" && grep -qiE '^\s*PrivateKey\s*=' "${wg}" \
        || die "secrets/wireguard/wg0.conf is not filled in (no [Interface] PrivateKey)"
    # Without a keepalive, the peer cannot reach us through NAT until we
    # send traffic first, so SSH in over the VPN would not work.
    grep -qiE '^\s*PersistentKeepalive\s*=' "${wg}" \
        || die "secrets/wireguard/wg0.conf has no PersistentKeepalive (add e.g. PersistentKeepalive = 25 to [Peer])"
    [[ -f ${SECRETS}/ssh/authorized_keys ]] || die "missing secrets/ssh/authorized_keys (run: just config)"
    grep -qvE '^\s*(#|$)' "${SECRETS}/ssh/authorized_keys" \
        || die "secrets/ssh/authorized_keys has no keys (only comments)"
    [[ -n $(wifi_networks) ]] \
        || echo "WARNING: no WiFi networks in secrets/wifi/ (wired only)" >&2
    chmod 700 "${SECRETS}"
}

# Generate a stable set of SSH host keys once, so the fingerprint never
# changes between builds.
ensure_host_keys() {
    local type key
    mkdir -p "${SECRETS}/ssh/host"
    for type in "${SSH_HOST_KEY_TYPES[@]}"; do
        key="${SECRETS}/ssh/host/ssh_host_${type}_key"
        if [[ ! -f ${key} ]]; then
            echo "Generating SSH host key: ${key}"
            ssh-keygen -q -t "${type}" -N '' -C root@arch-iso -f "${key}"
        fi
    done
}

# Assemble the profile: releng + our overlay + packages.
stage_profile() {
    mkdir -p "${PROFILE}" "${OUT}"
    cp -a "${RELENG}/." "${PROFILE}/"
    cp -a "${ROOT}/airootfs/." "${PROFILE}/airootfs/"
    grep -v '^#' "${ROOT}/packages.extra" >>"${PROFILE}/packages.x86_64"
    cat >>"${PROFILE}/profiledef.sh" <<'EOF'

# --- archiso-wireguard ---
# The ISO contains secrets: make that obvious in its filename.
iso_name="arch-iso-CONTAINS-SECRETS"
EOF
}

# Copy a secret into the airootfs and register its permissions. mkarchiso
# does not preserve modes, so every secret needs a file_permissions entry.
install_secret() {
    local src=$1 dest=$2 mode=$3
    install -D -m 600 "${src}" "${PROFILE}/airootfs${dest}"
    printf 'file_permissions["%s"]="0:0:%s"\n' "${dest}" "${mode}" >>"${PROFILE}/profiledef.sh"
}

secret_dir() {
    # mkarchiso aborts on a file_permissions entry for a missing path.
    mkdir -p "${PROFILE}/airootfs$1"
    printf 'file_permissions["%s"]="0:0:%s"\n' "$1" "$2" >>"${PROFILE}/profiledef.sh"
}

stage_secrets() {
    local f type

    # WiFi: iwd network files (<SSID>.psk, .open, .8021x)
    secret_dir /var/lib/iwd 700
    while IFS= read -r f; do
        install_secret "${f}" "/var/lib/iwd/$(basename "${f}")" 600
    done < <(wifi_networks)

    # WireGuard
    secret_dir /etc/wireguard 700
    install_secret "${SECRETS}/wireguard/wg0.conf" /etc/wireguard/wg0.conf 600

    # SSH client keys allowed to log in as root
    secret_dir /root/.ssh 700
    install_secret "${SECRETS}/ssh/authorized_keys" /root/.ssh/authorized_keys 600

    # SSH host keys
    for type in "${SSH_HOST_KEY_TYPES[@]}"; do
        install_secret "${SECRETS}/ssh/host/ssh_host_${type}_key" \
            "/etc/ssh/ssh_host_${type}_key" 600
        install_secret "${SECRETS}/ssh/host/ssh_host_${type}_key.pub" \
            "/etc/ssh/ssh_host_${type}_key.pub" 644
    done
}

main() {
    check_secrets
    ensure_host_keys
    clean_build
    stage_profile
    stage_secrets
    mkarchiso -v -w "${WORK}" -o "${OUT}" "${PROFILE}"
    chmod 600 "${OUT}"/*.iso
    clean_build
    echo
    echo "Built:"
    ls -lh "${OUT}"/*.iso
}

main "$@"
