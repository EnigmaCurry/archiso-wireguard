#!/usr/bin/env bash
# Show what this repo put into a built ISO or rpi5 .img: image name,
# hostname, and the owner/mode of every secret and overlay file (never
# their contents). Fails if any secret is not root-owned or is readable by
# group/others.
#
# Usage: inspect.sh [IMAGE]   (default: newest .iso or .img in secrets/out/)
#
# On the host, this re-runs itself inside the same container build.sh
# uses for this host's architecture (Arch Linux on amd64, Arch Linux ARM
# on arm64; squashfs-tools isn't needed on the host), with the image
# mounted read-only. Either container inspects either kind of image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ROOT}/secrets/out"

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
    local iso=${1:-} image volume
    command -v podman >/dev/null || die "podman is not installed"
    if [[ -z ${iso} ]]; then
        iso=$(ls -t "${OUT}"/*.iso "${OUT}"/*.img 2>/dev/null | head -1) || true
        [[ -n ${iso} ]] || die "no ISO or .img in secrets/out/ (run: just build or just build-rpi5)"
    fi
    [[ -f ${iso} ]] || die "no such image: ${iso}"
    iso=$(realpath "${iso}")
    # Same images and cache volumes as build.sh.
    case $(podman info --format '{{.Host.Arch}}') in
        amd64)
            image=${ARCHISO_IMAGE:-docker.io/library/archlinux:latest}
            volume=archiso-wireguard-pacman-cache
            ;;
        arm64)
            image=${ARCHISO_IMAGE:-localhost/archlinuxarm:latest}
            volume=archiso-wireguard-pacman-cache-arm64
            podman image exists "${image}" || die "no ${image} image (build.sh creates it)"
            ;;
        *) die "unsupported Podman host architecture" ;;
    esac
    podman run --rm \
        --volume "${ROOT}/inspect.sh:/inspect.sh:ro" \
        --volume "${iso}:/iso/$(basename "${iso}"):ro" \
        --volume "${volume}:/var/cache/pacman/pkg" \
        --env ARCHISO_WIREGUARD_IN_CONTAINER=1 \
        "${image}" /inspect.sh "/iso/$(basename "${iso}")"
}

# Convert a squashfs-root-relative glob to a regex matching the path
# field of a listing line ("mode owner path").
path_regex() {
    local p=${1//./\\.}
    echo " squashfs-root/${p//\*/[^/ ]*}( |/|$)"
}

inspect_iso() {
    local iso=$1 sfs=/tmp/airootfs.sfs listing p regex bad
    # The imported Arch Linux ARM image has no pacman keyring yet.
    if [[ $(uname -m) == aarch64 ]]; then
        { pacman-key --init && pacman-key --populate archlinuxarm; } >/dev/null 2>&1
    fi
    # pacman's download sandbox doesn't work in an unprivileged
    # Arch Linux ARM container; this one is thrown away anyway.
    pacman -Sy --noconfirm --needed --disable-sandbox squashfs-tools mtools >/dev/null
    if [[ ${iso} == *.img ]]; then
        # build.sh puts the FAT partition at 1 MiB.
        MTOOLS_SKIP_CHECK=1 mcopy -n -i "${iso}@@1M" ::arch/aarch64/airootfs.sfs "${sfs}"
    else
        bsdtar -xOf "${iso}" arch/x86_64/airootfs.sfs >"${sfs}"
    fi
    # Fields: mode owner size date time path [-> symlink target]
    listing=$(unsquashfs -lln "${sfs}" | awk '$6 ~ /^squashfs-root\// { $3 = $4 = $5 = ""; print }' | tr -s ' ')

    echo "Image:    $(basename "${iso}") ($(du -h "${iso}" | cut -f1))"
    unsquashfs -cat "${sfs}" usr/lib/os-release | grep -E '^IMAGE_(ID|VERSION)=' | sed 's/^/          /'
    echo "Hostname: $(unsquashfs -cat "${sfs}" etc/hostname)"
    if [[ ${iso} == *.img ]]; then
        echo "Boot:     $(MTOOLS_SKIP_CHECK=1 mtype -i "${iso}@@1M" ::cmdline.txt)"
        echo "          $(MTOOLS_SKIP_CHECK=1 mdir -b -i "${iso}@@1M" :: | sed 's|^::/||' | grep -vE '\.dtb$' | sort | paste -sd ' ')"
    fi

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
