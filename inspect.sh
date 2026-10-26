#!/usr/bin/env bash
# Show what this repo put into a built image: its name, hostname, the
# owner/mode of every overlay file (never their contents), and the
# config partition's boomstick/ listing. Fails if the image
# contains any secret, which would make it unsafe to publish: images
# are generic and are configured afterwards, on the stick.
#
# Usage: inspect.sh [IMAGE]   (default: newest image in out/)
# A usb image has two live systems (x86_64 and aarch64); both are checked.
#
# On the host, this re-runs itself inside the same container build.sh
# uses for this host's architecture (Arch Linux on amd64, Arch Linux ARM
# on arm64; squashfs-tools isn't needed on the host), with the image
# mounted read-only. Either container inspects either kind of image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ROOT}/out"
CONFIG_DIR=boomstick

# Nothing may live under these paths: they are filled in at boot from
# the config partition, and a file here means a secret was baked in.
SECRET_PATHS=(
    etc/wireguard
    var/lib/iwd
    root/.ssh
    etc/boomstick
    'etc/ssh/ssh_host_*_key'
)
# Overlay files to list.
OVERLAY_PATHS=(
    etc/hostname
    etc/ssh/sshd_config.d
    usr/local/bin/boomstick-config
    usr/local/bin/boomstick-webhook
    usr/local/bin/boomstick-motd
    usr/local/bin/setup
    usr/local/bin/boomstick-cowspace
    usr/local/bin/boomstick-update
    etc/systemd/system/boomstick-config.service
    etc/systemd/system/sysinit.target.wants/boomstick-config.service
    etc/systemd/system/boomstick-motd.service
    etc/systemd/system/sysinit.target.wants/boomstick-motd.service
    etc/systemd/system/boomstick-cowspace.service
    etc/systemd/system/sysinit.target.wants/boomstick-cowspace.service
    etc/systemd/system/boomstick-webhook.service
    etc/systemd/system/multi-user.target.wants/boomstick-webhook.service
    'etc/systemd/system/multi-user.target.wants/wg-quick@*'
    'etc/systemd/system/wg-quick@wg0.service.d'
)

die() { echo "ERROR: $*" >&2; exit 1; }

run_container() {
    local iso=${1:-} image volume
    command -v podman >/dev/null || die "podman is not installed"
    if [[ -z ${iso} ]]; then
        iso=$(ls -t "${OUT}"/*.img 2>/dev/null | head -1) || true
        [[ -n ${iso} ]] || die "no image in out/ (run: just build, just build-rpi5 or just build-usb)"
    fi
    [[ -f ${iso} ]] || die "no such image: ${iso}"
    iso=$(realpath "${iso}")
    # Same images and cache volumes as build.sh.
    case $(podman info --format '{{.Host.Arch}}') in
        amd64)
            image=${ARCHISO_IMAGE:-docker.io/library/archlinux:latest}
            volume=boomstick-pacman-cache
            ;;
        arm64)
            image=${ARCHISO_IMAGE:-localhost/archlinuxarm:latest}
            volume=boomstick-pacman-cache-arm64
            podman image exists "${image}" || die "no ${image} image (build.sh creates it)"
            ;;
        *) die "unsupported Podman host architecture" ;;
    esac
    podman run --rm \
        --volume "${ROOT}/inspect.sh:/inspect.sh:ro" \
        --volume "${iso}:/iso/$(basename "${iso}"):ro" \
        --volume "${volume}:/var/cache/pacman/pkg" \
        --env BOOMSTICK_IN_CONTAINER=1 \
        "${image}" /inspect.sh "/iso/$(basename "${iso}")"
}

# Convert a squashfs-root-relative glob to a regex matching the path
# field of a listing line ("mode owner path").
path_regex() {
    local p=${1//./\\.}
    echo " squashfs-root/${p//\*/[^/ ]*}( |/|$)"
}

# Print what's in one airootfs.sfs; fail if it contains a secret.
inspect_sfs() {
    local sfs=$1 listing p regex baked
    # Fields: mode owner size date time path [-> symlink target]
    listing=$(unsquashfs -lln "${sfs}" | awk '$6 ~ /^squashfs-root\// { $3 = $4 = $5 = ""; print }' | tr -s ' ')

    unsquashfs -cat "${sfs}" usr/lib/os-release | grep -E '^IMAGE_(ID|VERSION)=' | sed 's/^/          /'
    echo "Hostname: $(unsquashfs -cat "${sfs}" etc/hostname)"

    echo
    echo "Overlay (mode owner/group path):"
    for p in "${OVERLAY_PATHS[@]}"; do
        regex=$(path_regex "${p}")
        grep -E "${regex}" <<<"${listing}" | sed 's/squashfs-root//; s/^/  /' \
            || echo "  (missing) /${p}"
    done

    # Regular files under the secret paths: there must be none.
    baked=$(for p in "${SECRET_PATHS[@]}"; do
        grep -E "$(path_regex "${p}")" <<<"${listing}" || true
    done | awk '$1 ~ /^-/')
    echo
    if [[ -n ${baked} ]]; then
        echo "FAIL: the image contains secrets, do not publish it:"
        sed 's/squashfs-root//; s/^/  /' <<<"${baked}"
        return 1
    fi
    echo "PASS: no secrets in the image (it is configured at boot from ${CONFIG_DIR}/)."
}

# Say whether the config partition still holds only the templates, so a
# provisioned image isn't published by mistake. Only counts lines, never
# prints a file's contents.
inspect_config() {
    local iso=$1 listing=$2 f filled=()
    while IFS= read -r f; do
        f=${f#::/}
        case ${f} in
            */ | "${CONFIG_DIR}/README.txt" | *.example) continue ;;
        esac
        # A template is nothing but comments and blank lines.
        if MTOOLS_SKIP_CHECK=1 mtype -i "${iso}@@1M" "::/${f}" 2>/dev/null \
            | grep -qvE '^\s*(#|$)'; then
            filled+=("${f#"${CONFIG_DIR}"/}")
        fi
    done <<<"${listing}"
    echo
    if ((${#filled[@]})); then
        echo "NOTE: this image is already configured and carries secrets:"
        printf '  %s\n' "${filled[@]}"
        echo "Do not publish it. Build again for a generic image."
    else
        echo "The config partition holds only the templates: the image is generic."
    fi
}

# An x86_64 image has arch/x86_64/airootfs.sfs, an rpi5 image
# arch/aarch64/, and a usb image both. Each is inspected. A plain ISO
# (the usb target's intermediate) can be passed in too.
inspect_iso() {
    local iso=$1 arch sfs config cmdline found=0 failed=0
    # The imported Arch Linux ARM image has no pacman keyring yet.
    if [[ $(uname -m) == aarch64 ]]; then
        { pacman-key --init && pacman-key --populate archlinuxarm; } >/dev/null 2>&1
    fi
    # pacman's download sandbox doesn't work in an unprivileged
    # Arch Linux ARM container; this one is thrown away anyway.
    pacman -Sy --noconfirm --needed --disable-sandbox squashfs-tools mtools >/dev/null

    echo "Image:    $(basename "${iso}") ($(du -h "${iso}" | cut -f1))"
    if [[ ${iso} == *.img ]]; then
        # build.sh puts the FAT partition at 1 MiB. cmdline.txt is the
        # Pi's kernel command line; an x86_64-only image has none.
        cmdline=$(MTOOLS_SKIP_CHECK=1 mtype -i "${iso}@@1M" ::cmdline.txt 2>/dev/null) \
            && echo "Boot:     ${cmdline}"
        echo "Files:    $(MTOOLS_SKIP_CHECK=1 mdir -b -i "${iso}@@1M" :: | sed 's|^::/||' | grep -vE '\.dtb$' | sort | paste -sd ' ')"
        # The config partition, as the user will find it on the stick.
        echo "Config:   ${CONFIG_DIR}/ on the FAT partition:"
        config=$(MTOOLS_SKIP_CHECK=1 mdir -b -i "${iso}@@1M" -/ "::/${CONFIG_DIR}" 2>/dev/null) || true
        if [[ -z ${config} ]]; then
            echo "            (missing: the stick cannot be configured)"
        else
            sed "s|^::/||; s|^|            |" <<<"${config}"
            inspect_config "${iso}" "${config}"
        fi
    fi

    for arch in x86_64 aarch64; do
        sfs=/tmp/airootfs-${arch}.sfs
        if [[ ${iso} == *.img ]]; then
            MTOOLS_SKIP_CHECK=1 mcopy -n -i "${iso}@@1M" "::arch/${arch}/airootfs.sfs" "${sfs}" 2>/dev/null || continue
        else
            bsdtar -xOf "${iso}" "arch/${arch}/airootfs.sfs" >"${sfs}" 2>/dev/null || true
            [[ -s ${sfs} ]] || continue
        fi
        found=1
        echo
        echo "== arch/${arch}/airootfs.sfs"
        inspect_sfs "${sfs}" || failed=1
        rm -f "${sfs}"
    done
    ((found)) || die "no arch/*/airootfs.sfs in $(basename "${iso}")"
    exit "${failed}"
}

if [[ -n ${BOOMSTICK_IN_CONTAINER:-} ]]; then
    inspect_iso "$@"
else
    run_container "$@"
fi
