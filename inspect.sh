#!/usr/bin/env bash
# Show what this repo put into a built ISO: image name, hostname, and the
# owner/mode of every secret and overlay file (never their contents).
# Fails if any secret is not root-owned or is readable by group/others.
#
# Usage: inspect.sh [ISO]   (default: newest ISO in secrets/out/)
#
# On the host, this re-runs itself inside an Arch Linux container with
# Podman (squashfs-tools isn't needed on the host), with secrets/out/
# mounted read-only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ROOT}/secrets/out"
IMAGE=${ARCHISO_IMAGE:-docker.io/library/archlinux:latest}
PACMAN_CACHE_VOLUME=archiso-wireguard-pacman-cache

# Paths whose files must be 0:0 and not readable by group/others.
SECRET_PATHS=(
    etc/wireguard
    var/lib/iwd
    root/.ssh
    etc/arch-iso
    'etc/ssh/ssh_host_*_key'
)
# Overlay files to list as well.
OVERLAY_PATHS=(
    etc/hostname
    etc/ssh/sshd_config.d
    'etc/ssh/ssh_host_*_key.pub'
    usr/local/bin/arch-iso-webhook
    etc/systemd/system/arch-iso-webhook.service
    etc/systemd/system/multi-user.target.wants/arch-iso-webhook.service
    'etc/systemd/system/multi-user.target.wants/wg-quick@*'
)

die() { echo "ERROR: $*" >&2; exit 1; }

run_container() {
    local iso=${1:-}
    command -v podman >/dev/null || die "podman is not installed"
    if [[ -z ${iso} ]]; then
        iso=$(ls -t "${OUT}"/*.iso 2>/dev/null | head -1) || true
        [[ -n ${iso} ]] || die "no ISO in secrets/out/ (run: just build)"
    fi
    [[ -f ${iso} ]] || die "no such ISO: ${iso}"
    iso=$(realpath "${iso}")
    podman run --rm \
        --volume "${ROOT}/inspect.sh:/inspect.sh:ro" \
        --volume "${iso}:/iso/$(basename "${iso}"):ro" \
        --volume "${PACMAN_CACHE_VOLUME}:/var/cache/pacman/pkg" \
        --env ARCHISO_WIREGUARD_IN_CONTAINER=1 \
        "${IMAGE}" /inspect.sh "/iso/$(basename "${iso}")"
}

# Convert a squashfs-root-relative glob to a regex matching the path
# field of a listing line ("mode owner path").
path_regex() {
    local p=${1//./\\.}
    echo " squashfs-root/${p//\*/[^/ ]*}( |/|$)"
}

inspect_iso() {
    local iso=$1 sfs=/tmp/airootfs.sfs listing p regex bad
    pacman -Sy --noconfirm --needed squashfs-tools >/dev/null
    bsdtar -xOf "${iso}" arch/x86_64/airootfs.sfs >"${sfs}"
    # Fields: mode owner size date time path [-> symlink target]
    listing=$(unsquashfs -lln "${sfs}" | awk '$6 ~ /^squashfs-root\// { $3 = $4 = $5 = ""; print }' | tr -s ' ')

    echo "ISO:      $(basename "${iso}") ($(du -h "${iso}" | cut -f1))"
    unsquashfs -cat "${sfs}" usr/lib/os-release | grep -E '^IMAGE_(ID|VERSION)=' | sed 's/^/          /'
    echo "Hostname: $(unsquashfs -cat "${sfs}" etc/hostname)"

    echo
    echo "Secrets (mode owner/group path):"
    for p in "${SECRET_PATHS[@]}"; do
        regex=$(path_regex "${p}")
        grep -E "${regex}" <<<"${listing}" | sed 's/squashfs-root//; s/^/  /' \
            || echo "  (missing) /${p}"
    done

    echo
    echo "Overlay:"
    for p in "${OVERLAY_PATHS[@]}"; do
        regex=$(path_regex "${p}")
        grep -E "${regex}" <<<"${listing}" | sed 's/squashfs-root//; s/^/  /' \
            || echo "  (missing) /${p}"
    done

    # Regular files under secret paths: must be 0/0 with no group/other bits.
    bad=$(for p in "${SECRET_PATHS[@]}"; do
        grep -E "$(path_regex "${p}")" <<<"${listing}" || true
    done | awk '$1 ~ /^-/ && ($2 != "0/0" || substr($1, 5) != "------")')
    echo
    if [[ -n ${bad} ]]; then
        echo "FAIL: secrets not root-only:"
        sed 's/squashfs-root//; s/^/  /' <<<"${bad}"
        exit 1
    fi
    echo "PASS: all secret files are root-owned and root-only."
}

if [[ -n ${ARCHISO_WIREGUARD_IN_CONTAINER:-} ]]; then
    inspect_iso "$@"
else
    run_container "$@"
fi
