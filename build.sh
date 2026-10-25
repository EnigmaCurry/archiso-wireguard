#!/usr/bin/env bash
# Build the arch-iso live image with secrets baked in.
#
# Usage: build.sh [TARGET]
#   x86_64  (default) a live ISO for x86_64 PCs
#   rpi5    a USB/SD disk image for the Raspberry Pi 5 (Arch Linux ARM)
#
# On the host, this checks the secrets and re-runs itself inside an Arch
# Linux container with Podman, with the repo bind-mounted at /build.
# Inside the container, it installs archiso, copies the stock releng
# profile, lays this repo's airootfs/ overlay and the git-ignored secrets/
# on top, and runs mkarchiso. The image contains secrets and is written to
# secrets/out/.
#
# rpi5 builds natively on an arm64 host (e.g. Podman on Apple Silicon):
# the container is Arch Linux ARM, mkarchiso builds in netboot mode (just
# the kernel, initramfs and airootfs.sfs), and the result is packed into
# an MBR disk image with one FAT32 partition the Pi firmware boots from.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELENG=/usr/share/archiso/configs/releng
SECRETS="${ROOT}/secrets"
OUT="${SECRETS}/out"
SSH_HOST_KEY_TYPES=(ed25519 ecdsa rsa)

die() { echo "ERROR: $*" >&2; exit 1; }

TARGET=${1:-x86_64}
case ${TARGET} in
    x86_64)
        IMAGE=${ARCHISO_IMAGE:-docker.io/library/archlinux:latest}
        PODMAN_ARCH=amd64
        # Named volume for the container's pacman cache, so rebuilds don't
        # re-download every package. It holds packages only, no secrets.
        PACMAN_CACHE_VOLUME=archiso-wireguard-pacman-cache
        ;;
    rpi5)
        # There is no official Arch Linux ARM container image: this one is
        # imported from the ALARM rootfs tarball (see ensure_alarm_image).
        IMAGE=${ARCHISO_IMAGE:-localhost/archlinuxarm:latest}
        PODMAN_ARCH=arm64
        PACMAN_CACHE_VOLUME=archiso-wireguard-pacman-cache-rpi5
        ;;
    *) die "unknown target '${TARGET}' (x86_64 or rpi5)" ;;
esac
# Staging and work dirs live in the container and vanish with it.
BUILD=/tmp/archiso-build
PROFILE="${BUILD}/profile"
WORK="${BUILD}/work"

# Arch Linux ARM rootfs for the rpi5 build container, and the key it is
# signed with ("Arch Linux ARM Build System <builder@archlinuxarm.org>").
ALARM_ROOTFS_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
ALARM_SIGNING_KEY=68B3537F39A313B3E574D06777193F152BDBE6A6
# ALARM doesn't package archiso; Arch's is arch "any" and this redirects
# to its current version on a mirror.
ARCHISO_PKG_URL=https://archlinux.org/packages/extra/any/archiso/download/
# FAT volume label of the rpi5 boot partition.
RPI5_LABEL=ARCH_RPI5

# iwd network files in secrets/wifi/ (other files, like templates, are ignored)
wifi_networks() {
    find "${SECRETS}/wifi" -maxdepth 1 -type f \
        \( -name '*.psk' -o -name '*.open' -o -name '*.8021x' \) 2>/dev/null
}

# True if secrets/wireguard/wg0.conf has anything besides comments and
# blank lines. A missing, empty or fully commented-out config builds an
# ISO without WireGuard.
wireguard_enabled() {
    grep -qvE '^\s*(#|$)' "${SECRETS}/wireguard/wg0.conf" 2>/dev/null
}

check_secrets() {
    local wg=${SECRETS}/wireguard/wg0.conf
    if wireguard_enabled; then
        grep -qE '^\s*\[Interface\]' "${wg}" && grep -qiE '^\s*PrivateKey\s*=' "${wg}" \
            || die "secrets/wireguard/wg0.conf is not filled in (no [Interface] PrivateKey)"
        # Without a keepalive, the peer cannot reach us through NAT until we
        # send traffic first, so SSH in over the VPN would not work.
        grep -qiE '^\s*PersistentKeepalive\s*=' "${wg}" \
            || die "secrets/wireguard/wg0.conf has no PersistentKeepalive (add e.g. PersistentKeepalive = 25 to [Peer])"
    else
        echo "WARNING: secrets/wireguard/wg0.conf is missing, empty or commented out (no WireGuard)" >&2
    fi
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
    if [[ ${TARGET} == rpi5 ]]; then
        stage_profile_rpi5
        return
    fi
    grep -v '^#' "${ROOT}/packages.extra" >>"${PROFILE}/packages.x86_64"
    cat >>"${PROFILE}/profiledef.sh" <<'EOF'

# --- archiso-wireguard ---
# The ISO contains secrets: make that obvious in its filename.
iso_name="arch-iso-CONTAINS-SECRETS"
file_permissions["/usr/local/bin/arch-iso-webhook"]="0:0:755"
EOF
}

# Package list for rpi5: releng's packages.aarch64 (made for generic UEFI
# arm64 machines) with the changes in packages.rpi5 and packages.extra,
# minus anything Arch Linux ARM doesn't have.
rpi5_packages() {
    local available line pkg
    local -A removed=()
    local -a pkgs=()
    available=$( { pacman -Slq; pacman -Sgq; } | sort -u)
    while IFS= read -r line; do
        [[ ${line} == -* ]] && removed[${line#-}]=1
    done < <(grep -vE '^\s*(#|$)' "${ROOT}/packages.rpi5")
    while IFS= read -r pkg; do
        [[ -n ${removed[${pkg}]:-} ]] && continue
        if ! grep -qxF -- "${pkg}" <<<"${available}"; then
            echo "Not in Arch Linux ARM, skipped: ${pkg}" >&2
            continue
        fi
        pkgs+=("${pkg}")
    done < <(cat "${RELENG}/packages.aarch64" "${ROOT}/packages.extra" \
        <(grep -vE '^\s*-' "${ROOT}/packages.rpi5") | grep -vE '^\s*(#|$)')
    printf '%s\n' "${pkgs[@]}" | sort -u
}

stage_profile_rpi5() {
    cp -a "${ROOT}/rpi5/airootfs/." "${PROFILE}/airootfs/"
    rpi5_packages >"${PROFILE}/packages.aarch64.new"
    mv "${PROFILE}/packages.aarch64.new" "${PROFILE}/packages.aarch64"
    # Build with Arch Linux ARM's repos (the container's pacman.conf)
    # instead of releng's Arch ones. pacstrap runs pacman in a nested user
    # namespace, where its download sandbox can't switch users.
    sed -e 's/^DownloadUser/#DownloadUser/' /etc/pacman.conf >"${PROFILE}/pacman.conf"
    sed -i '/^\[options\]/a DisableSandbox' "${PROFILE}/pacman.conf"
    cat >>"${PROFILE}/profiledef.sh" <<'EOF'

# --- archiso-wireguard ---
# The image contains secrets: make that obvious in its filename.
iso_name="arch-rpi5-CONTAINS-SECRETS"
arch="aarch64"
# The Pi firmware boots the FAT partition directly: no boot loader.
bootmodes=()
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

    # WireGuard, or drop the overlay's wg-quick@wg0 enable link without it
    if wireguard_enabled; then
        secret_dir /etc/wireguard 700
        install_secret "${SECRETS}/wireguard/wg0.conf" /etc/wireguard/wg0.conf 600
    else
        rm "${PROFILE}/airootfs/etc/systemd/system/multi-user.target.wants/wg-quick@wg0.service"
    fi

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
    local arch
    command -v podman >/dev/null || die "podman is not installed"
    # Emulating the other architecture would work but take hours.
    arch=$(podman info --format '{{.Host.Arch}}')
    [[ ${arch} == "${PODMAN_ARCH}" ]] \
        || die "target ${TARGET} needs a native ${PODMAN_ARCH} Podman host (this one is ${arch})"
    [[ ${TARGET} == rpi5 ]] && ensure_alarm_image
    podman run --rm --privileged \
        --volume "${ROOT}:/build" \
        --volume "${PACMAN_CACHE_VOLUME}:/var/cache/pacman/pkg" \
        --env ARCHISO_WIREGUARD_IN_CONTAINER=1 \
        "${IMAGE}" /build/build.sh "${TARGET}"
}

# Host side, rpi5: create the Arch Linux ARM container image from the
# official rootfs tarball, once. The tarball's signature is checked in a
# throwaway Debian container against the pinned ALARM signing key.
ensure_alarm_image() {
    local tmp
    podman image exists "${IMAGE}" && return
    [[ ${IMAGE} == localhost/archlinuxarm:latest ]] \
        || die "image ${IMAGE} does not exist (pull or build it first)"
    echo "Creating ${IMAGE} from ${ALARM_ROOTFS_URL}"
    tmp=$(mktemp -d)
    curl -fL --progress-bar -o "${tmp}/rootfs.tar.gz" "${ALARM_ROOTFS_URL}"
    curl -fsSL -o "${tmp}/rootfs.tar.gz.sig" "${ALARM_ROOTFS_URL}.sig"
    podman run --rm --volume "${tmp}:/d:ro" docker.io/library/debian:stable-slim sh -c "
        apt-get update -qq && apt-get install -y -qq gpg dirmngr ca-certificates >/dev/null 2>&1 &&
        gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys ${ALARM_SIGNING_KEY} &&
        gpg --status-fd 1 --verify /d/rootfs.tar.gz.sig /d/rootfs.tar.gz 2>/dev/null |
            grep -q '^\[GNUPG:\] VALIDSIG ${ALARM_SIGNING_KEY} '" \
        || { rm -rf "${tmp}"; die "bad signature on ${ALARM_ROOTFS_URL}"; }
    podman import --change 'CMD ["/bin/bash"]' "${tmp}/rootfs.tar.gz" "${IMAGE}"
    rm -rf "${tmp}"
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
    if [[ ${TARGET} == rpi5 ]]; then
        install_archiso_alarm
    else
        pacman -Syu --noconfirm --needed archiso openssh
    fi
    [[ -d ${RELENG} ]] || die "archiso is not installed (missing ${RELENG})"
    ensure_host_keys
    stage_profile
    stage_secrets
    setup_builder
    if [[ ${TARGET} == rpi5 ]]; then
        runuser -u builder -- mkarchiso -v -m netboot -w "${WORK}" -o "${BUILD}/out" "${PROFILE}"
        make_rpi5_image
        return
    fi
    runuser -u builder -- mkarchiso -v -w "${WORK}" -o "${BUILD}/out" "${PROFILE}"
    install -m 600 "${BUILD}"/out/*.iso "${OUT}/"
    echo
    echo "Built:"
    ls -lh "${OUT}"/*.iso
}

# Container side, rpi5: the imported rootfs has no pacman keyring yet.
install_archiso_alarm() {
    local url
    pacman-key --init
    pacman-key --populate archlinuxarm archlinux
    pacman -Sy --noconfirm --needed archlinuxarm-keyring archlinux-keyring
    pacman -Su --noconfirm --needed openssh dosfstools mtools
    url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "${ARCHISO_PKG_URL}")
    pacman -U --noconfirm --needed "${url}"
    # The rootfs's default user has uid 1000, which setup_builder needs.
    userdel --remove alarm
}

# Container side, rpi5: pack the Pi's /boot (firmware config, kernel,
# DTBs and the archiso initramfs) and the netboot airootfs into one FAT32
# partition of an MBR disk image, without loop devices: the filesystem is
# built in a file with mkfs.vfat and mtools, then placed after the
# partition table.
make_rpi5_image() {
    local fat=${BUILD}/fat fatimg=${BUILD}/fat.img disk volid uuid name kib
    # shellcheck disable=SC2034,SC2154 # set and used by profiledef.sh
    name=$(declare -A file_permissions && source "${PROFILE}/profiledef.sh" \
        && echo "${iso_name}-${iso_version}-aarch64.img")
    disk=${BUILD}/${name}

    mkdir -p "${fat}"
    # mkarchiso's copy of the airootfs /boot. vmlinuz-* only exists for
    # mkarchiso (see rpi5/airootfs/etc/pacman.d/hooks/); the firmware
    # loads kernel8.img.
    cp -r "${WORK}/aarch64/boot/." "${fat}/"
    rm -f "${fat}"/vmlinuz-*
    # airootfs.sfs and its checksum, without netboot's kernel copies.
    mkdir -p "${fat}/arch"
    cp -r "${BUILD}/out/arch/." "${fat}/arch/"
    rm -rf "${fat}/arch/boot"

    # The archiso hook finds the boot partition by its FAT volume ID,
    # unique per build (like the ISO's search UUID).
    volid=$(od -An -tx4 -N4 /dev/urandom | tr -d ' ' | tr a-f A-F)
    uuid=${volid:0:4}-${volid:4:4}
    mkdir -p "${fat}/boot"
    touch "${fat}/boot/${uuid}.uuid"
    echo "archisobasedir=arch archisosearchuuid=${uuid} console=serial0,115200 console=tty1" \
        >"${fat}/cmdline.txt"

    # Room for the files plus FAT overhead and slack.
    kib=$(( $(du -sk "${fat}" | cut -f1) * 105 / 100 + 64 * 1024 ))
    kib=$(( (kib + 1023) / 1024 * 1024 ))
    mkfs.vfat -F 32 -n "${RPI5_LABEL}" -i "${volid}" -C "${fatimg}" "${kib}"
    MTOOLS_SKIP_CHECK=1 mcopy -s -i "${fatimg}" "${fat}"/* ::/

    # 1 MiB for the MBR, then the FAT32 (LBA) partition, marked bootable.
    truncate -s $(( 1024 * 1024 + kib * 1024 )) "${disk}"
    printf 'label: dos\nstart=2048, type=c, bootable\n' | sfdisk -q "${disk}"
    dd if="${fatimg}" of="${disk}" bs=1M seek=1 conv=notrunc status=none

    install -m 600 "${disk}" "${OUT}/"
    echo
    echo "Built:"
    ls -lh "${OUT}/${name}"
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
