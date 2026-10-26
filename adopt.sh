#!/usr/bin/env bash
# Copy a stick's configuration back into secrets/, the inverse of
# provision.sh.
#
# Usage: adopt.sh [--force] [TARGET]
#   (default)      the config partition of a stick, found by its
#                  BOOMSTICK filesystem label and mounted with
#                  udisksctl if it isn't mounted already
#   <directory>    an already-mounted config partition, or the
#                  boomstick/ directory inside it
#   /dev/sdX1      the stick's FAT partition, mounted here if it isn't
#   --force        replace files in secrets/ that already exist
#
# For the production order of events: clone this repository somewhere
# fresh, adopt the secrets off the stick you already have, and only then
# wipe or rebuild it. Without this, the only copy of a stick's WireGuard
# key and SSH host keys is the stick.
#
# Refuses to overwrite by default, so running it against the wrong stick
# cannot quietly replace a working secrets/ with someone else's.
#
# What it takes: everything the stick carries that the repository cannot
# regenerate -- the WiFi PSKs, the WireGuard config, authorized_keys,
# webhook.env, and the SSH host keys the stick made on its first boot.
# Not README.txt and not bin/, which come from this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="${BOOMSTICK_SECRETS:-${ROOT}/secrets}"
CONFIG_DIR=boomstick
FAT_LABEL=${FAT_LABEL:-BOOMSTICK}

# Written by this repository, never adopted from a stick.
NOT_SECRETS=(README.txt bin)

FORCE=0
MOUNTED_DEV=
TARGET=

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

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

label_mountpoint() {
    findmnt -rn -o TARGET -S "LABEL=${FAT_LABEL}" 2>/dev/null | head -1
}

# Mount DEV with udisksctl, so the files come out owned by us.
mount_dev() {
    local dev=$1
    command -v udisksctl >/dev/null \
        || die "${dev} is not mounted and udisksctl is not installed: mount it yourself and name the mount point"
    udisksctl mount -b "${dev}" >/dev/null || die "could not mount ${dev}"
    MOUNTED_DEV=${dev}
    TARGET=$(findmnt -rn -o TARGET -S "${dev}" 2>/dev/null | head -1) || true
    [[ -n ${TARGET} ]] || die "mounted ${dev}, but cannot tell where"
    echo "Mounted ${dev} at ${TARGET}"
}

find_target() {
    local dev
    # || true: findmnt exits 1 when the label isn't mounted, which with
    # set -e would end the script before the fallback.
    TARGET=$(label_mountpoint) || true
    [[ -n ${TARGET} ]] && return 0
    dev=$(blkid -L "${FAT_LABEL}" 2>/dev/null) || true
    [[ -n ${dev} ]] \
        || die "no ${FAT_LABEL} filesystem: plug in a stick, or name a target (a mount point or a /dev node)"
    mount_dev "${dev}"
}

# The boomstick/ directory on the stick, given either it or its parent.
config_dir() {
    local t=$1
    [[ $(basename "${t}") == "${CONFIG_DIR}" ]] && { echo "${t}"; return; }
    echo "${t}/${CONFIG_DIR}"
}

skip() {
    local rel=$1 n
    for n in "${NOT_SECRETS[@]}"; do
        [[ ${rel} == "${n}" || ${rel} == "${n}/"* ]] && return 0
    done
    return 1
}

main() {
    local src rel dest copied=0 kept=0 clashes=()

    while (($#)); do
        case $1 in
            --force) FORCE=1; shift ;;
            -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; return 0 ;;
            -*) die "unknown option: $1" ;;
            *) TARGET=$1; shift ;;
        esac
    done

    if [[ -z ${TARGET} ]]; then
        find_target
    elif [[ -b ${TARGET} ]]; then
        mount_dev "${TARGET}"
    elif [[ ! -d ${TARGET} ]]; then
        die "no such mount point or device: ${TARGET}"
    fi

    local from
    from=$(config_dir "${TARGET}")
    [[ -d ${from} ]] || die "${TARGET} has no ${CONFIG_DIR}/ directory: is this a BOOMSTICK?"
    echo "Source: ${from}"

    # Everything the stick has that this repository does not provide.
    while IFS= read -r src; do
        rel=${src#"${from}"/}
        skip "${rel}" && continue
        [[ -d ${src} ]] && continue
        [[ -e ${SECRETS}/${rel} ]] && clashes+=("${rel}")
    done < <(find "${from}" -mindepth 1)

    if ((${#clashes[@]})) && ((!FORCE)); then
        echo
        echo "These already exist in secrets/ and were left alone:" >&2
        printf '  %s\n' "${clashes[@]}" >&2
        die "refusing to overwrite. Adopt into a fresh checkout, or pass --force if the stick is the one you want to keep."
    fi

    mkdir -p "${SECRETS}"
    chmod 700 "${SECRETS}"
    while IFS= read -r src; do
        rel=${src#"${from}"/}
        skip "${rel}" && continue
        dest=${SECRETS}/${rel}
        if [[ -d ${src} ]]; then
            mkdir -p "${dest}"
            chmod 700 "${dest}"
            continue
        fi
        if [[ -e ${dest} ]] && ((!FORCE)); then
            kept=$((kept + 1)); continue
        fi
        mkdir -p "$(dirname "${dest}")"
        # Private keys and PSKs: readable only by this user. FAT carries
        # no modes of its own, so they are set here rather than copied.
        install -m 600 "${src}" "${dest}"
        echo "  secrets/${rel}"
        copied=$((copied + 1))
    done < <(find "${from}" -mindepth 1 | sort)
    find "${SECRETS}" -mindepth 1 -type d -exec chmod 700 {} +

    echo
    local also=
    ((kept)) && also=", kept ${kept} already there"
    echo "Adopted ${copied} file(s) into secrets/${also}."
    echo "Write them to a stick with 'just provision'. secrets/ is git-ignored;"
    echo "keep it that way."
}

main "$@"
