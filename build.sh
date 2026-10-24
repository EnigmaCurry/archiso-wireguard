#!/usr/bin/env bash
# Build the arch-iso live ISO with secrets baked in.
#
# On the host, this checks the secrets and re-runs itself inside an Arch
# Linux container with Podman, with the repo bind-mounted at /build.
# Inside the container, it installs archiso, copies the stock releng
# profile, lays this repo's airootfs/ overlay and the git-ignored secrets/
# on top, and runs mkarchiso. The ISO contains secrets and is written to
# secrets/out/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELENG=/usr/share/archiso/configs/releng
SECRETS="${ROOT}/secrets"
OUT="${SECRETS}/out"
SSH_HOST_KEY_TYPES=(ed25519 ecdsa rsa)

IMAGE=${ARCHISO_IMAGE:-docker.io/library/archlinux:latest}
# Named volume for the container's pacman cache, so rebuilds don't
# re-download every package. It holds packages only, no secrets.
PACMAN_CACHE_VOLUME=archiso-wireguard-pacman-cache
# Staging and work dirs live in the container and vanish with it.
BUILD=/tmp/archiso-build
PROFILE="${BUILD}/profile"
WORK="${BUILD}/work"

die() { echo "ERROR: $*" >&2; exit 1; }

# iwd network files in secrets/wifi/ (other files, like templates, are ignored)
wifi_networks() {
    find "${SECRETS}/wifi" -maxdepth 1 -type f \
        \( -name '*.psk' -o -name '*.open' -o -name '*.8021x' \) 2>/dev/null
}

check_secrets() {
    local wg=${SECRETS}/wireguard/wg0.conf
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
    webhook_enabled \
        || echo "WARNING: no WEBHOOK_URL in secrets/webhook.env (webhook disabled)" >&2
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
file_permissions["/usr/local/bin/arch-iso-webhook"]="0:0:755"
EOF
}

# True if secrets/webhook.env sets WEBHOOK_URL (not just the template).
webhook_enabled() {
    grep -qE '^\s*WEBHOOK_URL=.+' "${SECRETS}/webhook.env" 2>/dev/null
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

    # Boot webhook (arch-iso-webhook.service only runs if this exists)
    if webhook_enabled; then
        secret_dir /etc/arch-iso 700
        install_secret "${SECRETS}/webhook.env" /etc/arch-iso/webhook.env 600
    fi
}

# Host side: re-run this script in a throwaway Arch container. Rootless
# Podman maps container root to the invoking user, so everything written
# to the bind mount is owned by that user. --privileged is needed for
# pacstrap's mounts. Secrets are only bind-mounted, never put in an image.
run_container() {
    command -v podman >/dev/null || die "podman is not installed"
    podman run --rm --privileged \
        --volume "${ROOT}:/build" \
        --volume "${PACMAN_CACHE_VOLUME}:/var/cache/pacman/pkg" \
        --env ARCHISO_WIREGUARD_IN_CONTAINER=1 \
        "${IMAGE}" /build/build.sh
}

# As root, pacstrap mounts a devtmpfs, which a rootless container can't.
# As a regular user, mkarchiso runs pacstrap in unshare mode (-N), which
# only needs bind/proc/tmpfs mounts. So mkarchiso runs as "builder" in a
# nested user namespace.
setup_builder() {
    useradd --create-home --uid 1000 builder
    # Rootless Podman gives the container uids/gids 0-65536. Map those
    # above builder's own into its namespace (as uids 1-64536, which
    # includes nobody=65534). Container root is left out: mapping uid 0
    # would also need CAP_SETFCAP.
    printf 'builder:1001:64536\n' | tee /etc/subuid >/etc/subgid
    # The image doesn't keep file capabilities, which these need.
    setcap cap_setuid=ep /usr/bin/newuidmap
    setcap cap_setgid=ep /usr/bin/newgidmap
    chown -R builder: /var/cache/pacman/pkg "${BUILD}"
}

# Container side: install archiso and build. Files builder creates would
# show up on the host with a subordinate uid, so builder only writes inside
# the container and root copies the ISO out (owned by the host user).
build_iso() {
    pacman -Syu --noconfirm --needed archiso openssh
    [[ -d ${RELENG} ]] || die "archiso is not installed (missing ${RELENG})"
    ensure_host_keys
    stage_profile
    stage_secrets
    setup_builder
    runuser -u builder -- mkarchiso -v -w "${WORK}" -o "${BUILD}/out" "${PROFILE}"
    install -m 600 "${BUILD}"/out/*.iso "${OUT}/"
    echo
    echo "Built:"
    ls -lh "${OUT}"/*.iso
}

main() {
    check_secrets
    if [[ -n ${ARCHISO_WIREGUARD_IN_CONTAINER:-} ]]; then
        build_iso
    else
        run_container
    fi
}

main "$@"
