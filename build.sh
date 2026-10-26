#!/usr/bin/env bash
# Build the arch-iso live image. The image is generic: it holds no
# secrets, and is configured after it is written to a USB stick, from an
# archiso-config/ directory on the stick's FAT32 partition (see
# provision.sh and airootfs/usr/local/bin/arch-iso-config).
#
# Usage: build.sh [TARGET]
#   x86_64  (default) a USB disk image for x86_64 PCs (UEFI)
#   rpi5    a USB/SD disk image for the Raspberry Pi 5 (Arch Linux ARM)
#   usb     one USB disk image that boots both: x86_64 PCs (UEFI) and the
#           Raspberry Pi 5. Builds the x86_64 ISO first, then the rpi5
#           image with the ISO's UEFI boot files and airootfs merged into
#           its FAT32 partition.
#   iso     internal: the plain x86_64 ISO, staged for the usb target.
#
# Every target is one MBR disk image with a single FAT32 partition, so
# the config partition can be edited after writing the stick. x86_64
# boots UEFI only; legacy BIOS is not supported (it needs the ISO
# itself, which cannot carry a config partition).
#
# On the host, this re-runs itself inside an Arch Linux container with
# Podman, with the repo bind-mounted at /build. Inside the container, it
# installs archiso, copies the stock releng profile, lays this repo's
# airootfs/ overlay on top, and runs mkarchiso. The image is written to
# out/.
#
# The container always matches the host's architecture: Arch Linux on
# amd64, Arch Linux ARM (imported from its rootfs tarball) on arm64, e.g.
# Apple Silicon. When the target is the other architecture, pacman
# installs the target's packages into the image root (Architecture= in
# the profile's pacman.conf) and only what runs inside that root, like
# package scriptlets and mkinitcpio, goes through qemu-user (binfmt_misc).
#
# For rpi5, mkarchiso builds in netboot mode (just the kernel, initramfs
# and airootfs.sfs), and the result is packed into an MBR disk image with
# one FAT32 partition the Pi firmware boots from.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELENG=/usr/share/archiso/configs/releng
OUT="${ROOT}/out"
# The usb target needs the x86_64 ISO in the repo, where the second
# container can see it. It is deleted once the image is built.
STAGE="${OUT}/.iso-stage"
# Configuration templates copied onto the image's FAT partition, for the
# user to fill in after writing the stick.
TEMPLATES="${ROOT}/config-templates"
CONFIG_DIR=archiso-config

die() { echo "ERROR: $*" >&2; exit 1; }

TARGET=${1:-x86_64}
case ${TARGET} in
    x86_64 | iso) TARGET_ARCH=x86_64 TARGET_PODMAN_ARCH=amd64 ;;
    rpi5 | usb) TARGET_ARCH=aarch64 TARGET_PODMAN_ARCH=arm64 ;;
    *) die "unknown target '${TARGET}' (x86_64, rpi5 or usb)" ;;
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
# FAT volume label of the boot partition. The live system falls back to
# searching for this label when it did not boot from the partition
# holding archiso-config/ (an ISO, or a copytoram boot).
FAT_LABEL=ARCH_CONFIG
# Arch Linux mirror for x86_64 packages when building on arm64.
ARCH_MIRROR='https://geo.mirror.pkgbuild.com/$repo/os/$arch'

# The build container for this host's architecture, and a named volume
# for its pacman cache, so rebuilds don't re-download every package. It
# holds packages only, no secrets.
host_container() {
    case $(podman info --format '{{.Host.Arch}}') in
        amd64)
            IMAGE=${ARCHISO_IMAGE:-docker.io/library/archlinux:latest}
            PACMAN_CACHE_VOLUME=boomstick-pacman-cache
            ;;
        arm64)
            # There is no official Arch Linux ARM container image: this
            # one is imported from the ALARM rootfs (see ensure_alarm_image).
            IMAGE=${ARCHISO_IMAGE:-localhost/archlinuxarm:latest}
            PACMAN_CACHE_VOLUME=boomstick-pacman-cache-arm64
            ;;
        *) die "unsupported Podman host architecture: $(podman info --format '{{.Host.Arch}}')" ;;
    esac
}

# True for the targets that build the Raspberry Pi 5 live system.
pi_target() {
    [[ ${TARGET} == rpi5 || ${TARGET} == usb ]]
}

# Container side: true when the target isn't this container's architecture.
cross_build() {
    [[ $(uname -m) != "${TARGET_ARCH}" ]]
}

# Assemble the profile: releng + our overlay + packages.
stage_profile() {
    mkdir -p "${PROFILE}" "${OUT}"
    cp -a "${RELENG}/." "${PROFILE}/"
    cp -a "${ROOT}/airootfs/." "${PROFILE}/airootfs/"
    if pi_target; then
        stage_profile_rpi5
        return
    fi
    grep -v '^#' "${ROOT}/packages.extra" >>"${PROFILE}/packages.x86_64"
    if cross_build; then
        # releng's pacman.conf uses the container's mirrorlist, which on
        # Arch Linux ARM points to ALARM.
        sed -i -e 's/^Architecture.*/Architecture = x86_64/' \
            -e "s|^Include = /etc/pacman.d/mirrorlist|Server = ${ARCH_MIRROR}|" \
            "${PROFILE}/pacman.conf"
        cross_cache_dir
    fi
    cat >>"${PROFILE}/profiledef.sh" <<'EOF'

# --- boomstick ---
iso_name="arch-iso"
# mkarchiso defaults to the build host's architecture.
arch="x86_64"
file_permissions["/usr/local/bin/arch-iso-webhook"]="0:0:755"
file_permissions["/usr/local/bin/arch-iso-config"]="0:0:755"
file_permissions["/usr/local/bin/setup"]="0:0:755"
EOF
}

# Package list for rpi5: releng's packages.aarch64 (made for generic UEFI
# arm64 machines) with the changes in packages.rpi5 and packages.extra,
# minus anything Arch Linux ARM doesn't have.
rpi5_packages() {
    local available line pkg
    local -A removed=()
    local -a pkgs=()
    # The target's repos, synced into a throwaway database.
    mkdir -p "${BUILD}/syncdb"
    pacman --config "${PROFILE}/pacman.conf" --dbpath "${BUILD}/syncdb" -Sy >/dev/null
    available=$( {
        pacman --config "${PROFILE}/pacman.conf" --dbpath "${BUILD}/syncdb" -Slq
        pacman --config "${PROFILE}/pacman.conf" --dbpath "${BUILD}/syncdb" -Sgq
    } | sort -u)
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
    # Arch Linux ARM's repos instead of releng's Arch ones.
    cp "${ROOT}/rpi5/pacman.conf" "${PROFILE}/pacman.conf"
    cross_build && cross_cache_dir
    rpi5_packages >"${PROFILE}/packages.aarch64.new"
    mv "${PROFILE}/packages.aarch64.new" "${PROFILE}/packages.aarch64"
    cat >>"${PROFILE}/profiledef.sh" <<'EOF'

# --- boomstick ---
iso_name="arch-rpi5"
arch="aarch64"
# The Pi firmware boots the FAT partition directly: no boot loader.
bootmodes=()
file_permissions["/usr/local/bin/arch-iso-webhook"]="0:0:755"
file_permissions["/usr/local/bin/arch-iso-config"]="0:0:755"
file_permissions["/usr/local/bin/setup"]="0:0:755"
EOF
}

# Cross builds keep the target's packages apart from the container's:
# both distros have "any" packages with the same file names but different
# signatures. mkarchiso uses a profile CacheDir that isn't the default.
cross_cache_dir() {
    mkdir -p "/var/cache/pacman/pkg/${TARGET_ARCH}"
    sed -i "/^\[options\]/a CacheDir = /var/cache/pacman/pkg/${TARGET_ARCH}" "${PROFILE}/pacman.conf"
}

# Host side: re-run this script in a throwaway Arch container. Rootless
# Podman maps container root to the invoking user, so everything written
# to the bind mount is owned by that user. --privileged is needed for
# pacstrap's mounts.
run_container() {
    local arch usb_iso=${1:-}
    command -v podman >/dev/null || die "podman is not installed"
    host_container
    [[ ${IMAGE} == localhost/archlinuxarm:latest ]] && ensure_alarm_image
    # Building for the other architecture runs the target's binaries
    # (scriptlets, mkinitcpio) through qemu-user: check that works.
    arch=$(podman info --format '{{.Host.Arch}}')
    if [[ ${arch} != "${TARGET_PODMAN_ARCH}" ]]; then
        podman run --rm --arch "${TARGET_PODMAN_ARCH}" docker.io/library/busybox:latest true >/dev/null 2>&1 \
            || die "can't run ${TARGET_PODMAN_ARCH} binaries on this ${arch} host: install qemu-user-static with binfmt_misc support (see README)"
        echo "NOTE: building ${TARGET} (${TARGET_PODMAN_ARCH}) on a ${arch} host: the target's scriptlets and mkinitcpio run under qemu-user, so it is slower" >&2
    fi
    podman run --rm --privileged \
        --volume "${ROOT}:/build" \
        --volume "${PACMAN_CACHE_VOLUME}:/var/cache/pacman/pkg" \
        --env BOOMSTICK_IN_CONTAINER=1 \
        --env BOOMSTICK_USB_ISO="${usb_iso}" \
        "${IMAGE}" /build/build.sh "${TARGET}"
}

# Host side, usb: build the x86_64 ISO (in its own container), then the
# rpi5 image with that ISO merged in. The ISO is only an intermediate,
# so it is staged inside out/ and removed afterwards.
run_usb() {
    local iso
    rm -rf "${STAGE}"
    "${ROOT}/build.sh" iso
    iso=$(ls -t "${STAGE}"/*.iso | head -1)
    echo "Merging into the USB image: ${iso#"${ROOT}"/}"
    run_container "${iso#"${ROOT}"/}"
    rm -rf "${STAGE}"
}

# Host side, arm64: create the Arch Linux ARM container image from the
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
    podman import --arch arm64 --change 'CMD ["/bin/bash"]' "${tmp}/rootfs.tar.gz" "${IMAGE}"
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
# the container and root copies the image out (owned by the host user).
build_iso() {
    if [[ $(uname -m) == aarch64 ]]; then
        install_archiso_alarm
    else
        pacman -Syu --noconfirm --needed archiso openssh
    fi
    if cross_build && pi_target; then
        # Trust Arch Linux ARM's package signing key (Arch Linux ARM's
        # container already has Arch's keyring for the other direction).
        #
        # --init first: the official archlinux image ships a populated
        # public keyring but an empty private-keys-v1.d, and --lsign-key
        # needs that local signing key ("There is no secret key
        # available to sign with"). --init only adds what is missing.
        pacman-key --init
        pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys "${ALARM_SIGNING_KEY}"
        pacman-key --lsign-key "${ALARM_SIGNING_KEY}"
    fi
    [[ -d ${RELENG} ]] || die "archiso is not installed (missing ${RELENG})"
    stage_profile
    setup_builder
    if pi_target; then
        runuser -u builder -- mkarchiso -v -m netboot -w "${WORK}" -o "${BUILD}/out" "${PROFILE}"
        make_disk_image
        return
    fi
    runuser -u builder -- mkarchiso -v -w "${WORK}" -o "${BUILD}/out" "${PROFILE}"
    if [[ ${TARGET} == iso ]]; then
        # Only an intermediate for the usb target, never shipped: an ISO
        # 9660 filesystem cannot hold a config partition.
        mkdir -p "${STAGE}"
        install -m 644 "${BUILD}"/out/*.iso "${STAGE}/"
        return
    fi
    make_disk_image
}

# Container side, arm64: the imported rootfs has no pacman keyring yet.
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

# Container side: pack the live system into an MBR disk image with one
# FAT32 partition, without loop devices: the filesystem is built in a
# file with mkfs.vfat and mtools, then placed after the partition table.
# Every target produces one of these, so the config partition can be
# edited after the image is written to a stick.
#
# rpi5 puts the Pi's /boot (firmware config, kernel, DTBs and the archiso
# initramfs) and the netboot airootfs on it. x86_64 puts the ISO's UEFI
# boot files (systemd-boot in EFI/BOOT/, loader/, its kernel and
# initramfs in arch/boot/x86_64/) and arch/x86_64/airootfs.sfs on it,
# leaving out the ISO 9660-only boot files: syslinux (legacy BIOS, not
# supported) and GRUB's loopback config. usb puts both on one partition.
#
# Nothing collides: the Pi firmware only reads the top-level files, UEFI
# only EFI/ and loader/, and each initramfs loads arch/$(uname -m)/. The
# ISO's initramfs can't find the partition by its ISO volume UUID, so it
# falls back to searching for its /boot/<uuid>.uuid file (archiso's
# support for copying an ISO onto a FAT32 stick), which comes along with
# the rest of the ISO.
make_disk_image() {
    local fat=${BUILD}/fat fatimg=${BUILD}/fat.img disk volid uuid name kib iso suffix
    case ${TARGET} in
        x86_64) suffix=x86_64 ;;
        rpi5) suffix=aarch64 ;;
        usb) suffix=x86_64+rpi5 ;;
        *) die "make_disk_image: unexpected target ${TARGET}" ;;
    esac
    # shellcheck disable=SC2034,SC2154 # set and used by profiledef.sh
    name=$(declare -A file_permissions && source "${PROFILE}/profiledef.sh" \
        && echo "${iso_name}-${iso_version}-${suffix}.img")
    # usb builds on the rpi5 profile, but it is not a Pi-only image.
    [[ ${TARGET} == usb ]] && name=${name/arch-rpi5-/arch-usb-}
    disk=${BUILD}/${name}

    mkdir -p "${fat}"
    if pi_target; then
        # mkarchiso's copy of the airootfs /boot. vmlinuz-* only exists for
        # mkarchiso (see rpi5/airootfs/etc/pacman.d/hooks/); the firmware
        # loads kernel8.img.
        cp -r "${WORK}/aarch64/boot/." "${fat}/"
        rm -f "${fat}"/vmlinuz-*
        # airootfs.sfs and its checksum, without netboot's kernel copies.
        mkdir -p "${fat}/arch"
        cp -r "${BUILD}/out/arch/." "${fat}/arch/"
        rm -rf "${fat}/arch/boot"
    fi
    if [[ ${TARGET} != rpi5 ]]; then
        # x86_64 built its ISO in this container; usb got one from the
        # host, built in a container of its own.
        if [[ ${TARGET} == usb ]]; then
            iso="/build/${BOOMSTICK_USB_ISO}"
        else
            iso=$(ls -t "${BUILD}"/out/*.iso | head -1)
        fi
        bsdtar -xf "${iso}" -C "${fat}" \
            --exclude 'boot/syslinux' --exclude 'boot/grub' --exclude 'arch/grubenv'
        [[ -f ${fat}/EFI/BOOT/BOOTx64.EFI && -d ${fat}/arch/x86_64 ]] \
            || die "$(basename "${iso}") has no UEFI boot files or x86_64 airootfs"
    fi

    # The configuration the user fills in after writing the stick. The
    # live system reads it from here on every boot and writes the SSH
    # host keys back on the first one.
    cp -r "${TEMPLATES}" "${fat}/${CONFIG_DIR}"

    # The FAT volume ID, unique per build. The Pi has no boot loader, so
    # its kernel command line goes in cmdline.txt and points the archiso
    # hook at a search file named after that ID. x86_64 needs neither:
    # systemd-boot's loader entry already carries the ISO's search UUID.
    volid=$(od -An -tx4 -N4 /dev/urandom | tr -d ' ' | tr a-f A-F)
    if pi_target; then
        uuid=${volid:0:4}-${volid:4:4}
        mkdir -p "${fat}/boot"
        touch "${fat}/boot/${uuid}.uuid"
        echo "archisobasedir=arch archisosearchuuid=${uuid} console=serial0,115200 console=tty1" \
            >"${fat}/cmdline.txt"
    fi

    # Room for the files plus FAT overhead and slack.
    kib=$(( $(du -sk "${fat}" | cut -f1) * 105 / 100 + 64 * 1024 ))
    kib=$(( (kib + 1023) / 1024 * 1024 ))
    # -h: the boot sector's "hidden sectors" must be the partition's start
    # sector (2048, below). mkfs.vfat -C on a plain file would write 0,
    # and boot firmware may use it to locate the filesystem.
    mkfs.vfat -F 32 -h 2048 -n "${FAT_LABEL}" -i "${volid}" -C "${fatimg}" "${kib}"
    MTOOLS_SKIP_CHECK=1 mcopy -s -i "${fatimg}" "${fat}"/* ::/

    # 1 MiB for the MBR, then the FAT32 (LBA) partition, marked bootable.
    truncate -s $(( 1024 * 1024 + kib * 1024 )) "${disk}"
    printf 'label: dos\nstart=2048, type=c, bootable\n' | sfdisk -q "${disk}"
    dd if="${fatimg}" of="${disk}" bs=1M seek=1 conv=notrunc status=none

    install -m 644 "${disk}" "${OUT}/"
    echo
    echo "Built:"
    ls -lh "${OUT}/${name}"
}

main() {
    if [[ -n ${BOOMSTICK_IN_CONTAINER:-} ]]; then
        build_iso
    elif [[ ${TARGET} == usb ]]; then
        run_usb
    else
        run_container
    fi
}

main "$@"
