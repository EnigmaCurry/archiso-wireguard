#!/usr/bin/env bash
# Copy secrets/ onto a stick's config partition, as archiso-config/.
#
# Usage: provision.sh [TARGET]
#   (default)      the config partition of a stick, found by its
#                  ARCH_CONFIG filesystem label and mounted with
#                  udisksctl if it isn't mounted already
#   <directory>    an already-mounted config partition, e.g.
#                  /run/media/you/ARCH_CONFIG
#   /dev/sdX       a stick (or /dev/sdX1, its FAT partition), unmounted
#   <image>.img    a built image, before it is written to a stick. The
#                  image then contains your secrets and is no longer
#                  the generic thing it was built as.
#
# The files are checked first, with the same rules the build used to
# apply, so a typo fails here instead of silently leaving a headless
# machine unreachable.
#
# Images and devices are written with mtools inside a throwaway Podman
# container (no root, no loop device, nothing to mount); a directory is
# written directly. Writing to a device node needs permission to open
# it, so that usually means sudo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BOOMSTICK_SECRETS: another secrets/ directory (test-vm.sh uses one).
SECRETS="${BOOMSTICK_SECRETS:-${ROOT}/secrets}"
TEMPLATES="${ROOT}/config-templates"
CONFIG_DIR=archiso-config
# Filesystem label build.sh gives the config partition, and how a
# written stick is found again here.
FAT_LABEL=${FAT_LABEL:-ARCH_CONFIG}

# Set when we mounted the stick ourselves, so we can unmount it again.
MOUNTED_DEV=
TARGET=

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# Undo our own mount, on the way out whether or not this succeeded, so
# the stick is flushed and can be pulled.
unmount_if_ours() {
    local dev=${MOUNTED_DEV}
    [[ -n ${dev} ]] || return 0
    MOUNTED_DEV=
    if udisksctl unmount -b "${dev}" >/dev/null 2>&1; then
        echo "Unmounted ${dev}."
    else
        warn "could not unmount ${dev}: do it yourself before pulling the stick"
    fi
}
trap unmount_if_ours EXIT

# True if the file exists and has anything besides comments and blanks.
has_content() { [[ -f $1 ]] && grep -qvE '^\s*(#|$)' "$1"; }

# iwd network files in secrets/wifi/ (templates and the rest are ignored)
wifi_networks() {
    find "${SECRETS}/wifi" -maxdepth 1 -type f \
        \( -name '*.psk' -o -name '*.open' -o -name '*.8021x' \) 2>/dev/null
}

check_config() {
    local wg=${SECRETS}/wireguard/wg0.conf
    [[ -d ${SECRETS} ]] || die "no secrets/ directory (run: just config)"
    if has_content "${wg}"; then
        grep -qE '^\s*\[Interface\]' "${wg}" && grep -qiE '^\s*PrivateKey\s*=' "${wg}" \
            || die "secrets/wireguard/wg0.conf is not filled in (no [Interface] PrivateKey)"
        # Without a keepalive, the peer cannot reach us through NAT until we
        # send traffic first, so SSH in over the VPN would not work.
        grep -qiE '^\s*PersistentKeepalive\s*=' "${wg}" \
            || die "secrets/wireguard/wg0.conf has no PersistentKeepalive (add e.g. PersistentKeepalive = 25 to [Peer])"
    else
        warn "secrets/wireguard/wg0.conf is missing, empty or commented out (no WireGuard)"
    fi
    [[ -f ${SECRETS}/ssh/authorized_keys ]] || die "missing secrets/ssh/authorized_keys (run: just config)"
    has_content "${SECRETS}/ssh/authorized_keys" \
        || die "secrets/ssh/authorized_keys has no keys (only comments): nobody could log in"
    [[ -n $(wifi_networks) ]] || warn "no WiFi networks in secrets/wifi/ (wired only)"
    grep -qE '^\s*WEBHOOK_URL=.+' "${SECRETS}/webhook.env" 2>/dev/null \
        || warn "no WEBHOOK_URL in secrets/webhook.env (webhook disabled)"
}

# Where the config partition is mounted, or empty.
label_mountpoint() {
    findmnt -rn -o TARGET -S "LABEL=${FAT_LABEL}" 2>/dev/null | head -1
}

# With no argument: the stick, found by the label build.sh gave its
# config partition. Sets TARGET (not stdout: mounting has to record the
# device in MOUNTED_DEV, which a $( ) subshell would throw away).
#
# If the label is there but unmounted, mount it with udisksctl rather
# than telling the user to. FAT stores no ownership, so mounting it by
# hand as root makes every file root-owned and uneditable; udisks mounts
# it uid=<caller> under /run/media, which is the point.
find_target() {
    local dev
    # || true: findmnt exits 1 when the label isn't mounted, which with
    # set -e would end the script before the fallbacks below.
    TARGET=$(label_mountpoint) || true
    [[ -n ${TARGET} ]] && return 0
    dev=$(blkid -L "${FAT_LABEL}" 2>/dev/null) || true
    [[ -n ${dev} ]] \
        || die "no ${FAT_LABEL} filesystem: plug in a stick written from out/, or name a target (a mount point, a /dev node, or an image)"
    command -v udisksctl >/dev/null \
        || die "${FAT_LABEL} is on ${dev} but not mounted, and udisksctl is not installed: mount it with -o uid=$(id -u),gid=$(id -g) and try again"
    udisksctl mount -b "${dev}" >/dev/null \
        || die "could not mount ${dev}: mount it with -o uid=$(id -u),gid=$(id -g) and try again"
    MOUNTED_DEV=${dev}
    TARGET=$(label_mountpoint) || true
    [[ -n ${TARGET} ]] || die "mounted ${dev}, but cannot tell where"
    echo "Mounted ${dev} at ${TARGET}"
}

# The installer, copied as bin/setup so that a fix to it reaches a
# stick with 'just provision' rather than a rebuild. arch-iso-config
# installs it over the copy baked into the image.
SETUP=${ROOT}/airootfs/usr/local/bin/setup

# What gets copied: everything in secrets/, the README for whoever
# plugs the stick into another machine, and the installer.
sources() {
    find "${SECRETS}" -mindepth 1 -not -name '*.example'
    echo "${TEMPLATES}/README.txt"
    echo "${SETUP}"
}

# Target is a mounted filesystem: plain cp. Accepts either the partition
# root or the archiso-config/ directory inside it.
provision_dir() {
    local dest=$1 src rel
    [[ $(basename "${dest}") == "${CONFIG_DIR}" ]] || dest="${dest}/${CONFIG_DIR}"
    mkdir -p "${dest}"
    while IFS= read -r src; do
        rel=${src#"${SECRETS}"/}
        rel=${rel#"${TEMPLATES}"/}
        [[ ${src} == "${SETUP}" ]] && rel=bin/setup
        if [[ -d ${src} ]]; then
            mkdir -p "${dest}/${rel}"
        else
            mkdir -p "$(dirname "${dest}/${rel}")"
            cp "${src}" "${dest}/${rel}"
            echo "  ${CONFIG_DIR}/${rel}"
        fi
    done < <(sources | sort)
    sync
    echo
    echo "Wrote ${CONFIG_DIR}/ to ${dest%/"${CONFIG_DIR}"}"
}

# The build container for this host's architecture (same as build.sh and
# inspect.sh). Only mtools and util-linux are needed, so either works.
host_image() {
    case $(podman info --format '{{.Host.Arch}}') in
        amd64) echo "${ARCHISO_IMAGE:-docker.io/library/archlinux:latest}" ;;
        arm64)
            podman image exists localhost/archlinuxarm:latest \
                || die "no localhost/archlinuxarm image yet (build.sh creates it)"
            echo "${ARCHISO_IMAGE:-localhost/archlinuxarm:latest}"
            ;;
        *) die "unsupported Podman host architecture" ;;
    esac
}

# Target is an image file or a block device: mtools, in a container.
provision_mtools() {
    local target=$1 mount_opt
    command -v podman >/dev/null || die "podman is not installed"
    target=$(realpath "${target}")
    if [[ ${target} == *.iso ]]; then
        die "an ISO is read-only: configure it from a second filesystem labelled ARCH_CONFIG, or use just build-usb"
    fi
    if [[ -b ${target} ]]; then
        [[ -w ${target} ]] || die "no write permission on ${target} (try: sudo $0 ${target})"
        mount_opt=(--device "${target}:/target")
    else
        [[ -f ${target} ]] || die "no such image, device or directory: ${target}"
        mount_opt=(--volume "${target}:/target")
    fi
    podman run --rm \
        "${mount_opt[@]}" \
        --volume "${ROOT}/provision.sh:/provision.sh:ro" \
        --volume "${SECRETS}:/secrets:ro" \
        --volume "${TEMPLATES}:/templates:ro" \
        --volume "${SETUP}:/setup:ro" \
        --env BOOMSTICK_IN_CONTAINER=1 \
        "$(host_image)" /provision.sh /target
}

# Byte offset of the filesystem in /target: the first partition if there
# is a partition table, otherwise the whole thing (a partition node).
fat_offset() {
    local start
    start=$(sfdisk -J /target 2>/dev/null \
        | grep -oE '"start"[[:space:]]*:[[:space:]]*[0-9]+' \
        | head -1 | grep -oE '[0-9]+$') || true
    echo $(( ${start:-0} * 512 ))
}

# Container side. mtools writes into the FAT filesystem in place.
provision_in_container() {
    local offset img src rel dir
    # pacman's download sandbox doesn't work in an unprivileged
    # Arch Linux ARM container; this one is thrown away anyway.
    pacman -Sy --noconfirm --needed --disable-sandbox mtools >/dev/null
    offset=$(fat_offset)
    img="/target@@${offset}"
    export MTOOLS_SKIP_CHECK=1
    mdir -i "${img}" :: >/dev/null 2>&1 \
        || die "no FAT filesystem at offset ${offset} in the target"
    mmd -i "${img}" "::/${CONFIG_DIR}" 2>/dev/null || true
    while IFS= read -r src; do
        rel=${src#/secrets/}
        rel=${rel#/templates/}
        [[ ${src} == /setup ]] && rel=bin/setup
        if [[ -d ${src} ]]; then
            mmd -i "${img}" "::/${CONFIG_DIR}/${rel}" 2>/dev/null || true
            continue
        fi
        dir=$(dirname "${rel}")
        if [[ ${dir} != . ]]; then
            # find lists a directory before its files, so this is
            # normally already there: mmd fails and that is fine.
            mmd -i "${img}" "::/${CONFIG_DIR}/${dir}" 2>/dev/null || true
        fi
        mcopy -o -i "${img}" "${src}" "::/${CONFIG_DIR}/${rel}"
        echo "  ${CONFIG_DIR}/${rel}"
    done < <( { find /secrets -mindepth 1 -not -name '*.example'; echo /templates/README.txt; echo /setup; } | sort)
    sync
    echo
    echo "Wrote ${CONFIG_DIR}/ to the target's FAT partition."
}

main() {
    local target=${1:-}
    if [[ -n ${BOOMSTICK_IN_CONTAINER:-} ]]; then
        provision_in_container
        return
    fi
    check_config
    if [[ -n ${target} ]]; then
        TARGET=${target}
    else
        find_target
    fi
    echo "Target: ${TARGET#"${ROOT}"/}"
    if [[ -d ${TARGET} ]]; then
        provision_dir "${TARGET}"
        if [[ -n ${MOUNTED_DEV} ]]; then
            unmount_if_ours
            echo "Pull the stick and boot it."
        else
            echo "Unmount the stick and boot it."
        fi
    else
        provision_mtools "${TARGET}"
        [[ -b ${TARGET} ]] && echo "Unplug the stick and boot it." \
            || echo "This image is no longer generic: write it to a stick (and don't publish it)."
    fi
}

main "$@"
