#!/usr/bin/env bash
# Install Arch Linux with setup into a QEMU VM, unattended, and check
# that the result boots and accepts an SSH login.
#
# Usage: test-vm.sh [IMAGE]
#   IMAGE  an x86_64 (or x86_64+rpi5) image from out/; default: the
#          newest one there
#
# What it does, in test/ (git-ignored):
#   1. Copies the image (a clone on APFS or btrfs, so nearly free) and
#      provisions the copy with a throwaway SSH key and nothing else.
#   2. Boots it in QEMU (x86_64, UEFI) with a blank 20 GB disk whose
#      serial makes it /dev/disk/by-id/virtio-setuptest.
#   3. Over SSH, replaces the image's setup with this working tree's,
#      then runs setup host --from, disk, install --passwords, reboot,
#      with every prompt answered.
#   4. Boots the installed disk alone, logs in as admin, and checks
#      the hostname, the root subvolume, swap, sudo and failed units.
#
# Needs qemu (brew install qemu, or pacman -S qemu-full), podman (as for
# the build, for provisioning) and ssh. On Apple Silicon the VM runs
# under emulation (TCG), so an install takes a while: the timings are
# printed as it goes. On an x86_64 Linux host with /dev/kvm it uses KVM.
#
# Environment:
#   ENCRYPT=yes      install with LUKS (the passphrase is typed for you
#                    over a pty, as "setuptest")
#   KEEP=1           leave the VM's disks in test/ afterwards
#   SSH_PORT=2222    host port forwarded to the VM's sshd
#   FW_CODE, FW_VARS the x86_64 UEFI firmware's code and vars files,
#                    when they are somewhere this script doesn't look
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${ROOT}/out"
WORK="${ROOT}/test"
SSH_PORT=${SSH_PORT:-2222}
ENCRYPT=${ENCRYPT:-no}
KEEP=${KEEP:-0}
HOST=setuptest
PASSWORD=setuptest
DISK_SERIAL=setuptest
DISK_SIZE=20G
MEM=${MEM:-4096}
CPUS=${CPUS:-4}
# Minutes to wait for each boot to answer SSH. Generous for TCG.
BOOT_WAIT=${BOOT_WAIT:-15}

die() { echo "ERROR: $*" >&2; exit 1; }
phase() { printf '\n\033[1m== %s ==\033[0m  (%s since start)\n' "$*" "$(elapsed)"; }
START=${SECONDS}
elapsed() { local s=$((SECONDS - START)); printf '%dm%02ds' $((s / 60)) $((s % 60)); }

QEMU_PID=

stop_vm() {
    [[ -n ${QEMU_PID} ]] || return 0
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
    QEMU_PID=
}

cleanup() {
    stop_vm
    if [[ ${KEEP} != 1 ]]; then
        rm -f "${WORK}/stick.img" "${WORK}/disk.qcow2" "${WORK}/vars.fd"
    fi
}
trap cleanup EXIT

# --- prerequisites -----------------------------------------------------------

find_image() {
    local img=${1:-}
    if [[ -z ${img} ]]; then
        # shellcheck disable=SC2012 # names are ours: arch-usb-<date>-<arch>.img
        img=$(ls -t "${OUT}"/*x86_64*.img 2>/dev/null | head -1) || true
        [[ -n ${img} ]] || die "no x86_64 image in out/: run 'just build' (or 'just build-usb') first"
    fi
    [[ -f ${img} ]] || die "no such image: ${img}"
    [[ $(basename "${img}") == *x86_64* ]] || die "$(basename "${img}") is not an x86_64 image (the Pi 5 image cannot boot in QEMU)"
    echo "${img}"
}

# UEFI firmware, as a code + vars pair: the edk2 build qemu ships with
# itself (Homebrew, Arch), or the distribution's OVMF package.
find_firmware() {
    local share real pair code vars
    if [[ -n ${FW_CODE:-} || -n ${FW_VARS:-} ]]; then
        [[ -f ${FW_CODE:-} && -f ${FW_VARS:-} ]] || die "FW_CODE and FW_VARS must both name existing files"
        return
    fi
    share="$(dirname "$(command -v qemu-system-x86_64)")/../share/qemu"
    # Through the symlinks too: on NixOS the command is a link from
    # /run/current-system/sw/bin into qemu's store path.
    real=$(realpath "$(command -v qemu-system-x86_64)" 2>/dev/null) || real=
    real="$(dirname "${real:-$(command -v qemu-system-x86_64)}")/../share/qemu"
    for pair in \
        "${share}/edk2-x86_64-code.fd ${share}/edk2-i386-vars.fd" \
        "${real}/edk2-x86_64-code.fd ${real}/edk2-i386-vars.fd" \
        "${HOME}/.nix-profile/share/qemu/edk2-x86_64-code.fd ${HOME}/.nix-profile/share/qemu/edk2-i386-vars.fd" \
        "/run/current-system/sw/share/qemu/edk2-x86_64-code.fd /run/current-system/sw/share/qemu/edk2-i386-vars.fd" \
        "/opt/homebrew/share/qemu/edk2-x86_64-code.fd /opt/homebrew/share/qemu/edk2-i386-vars.fd" \
        "/usr/local/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-i386-vars.fd" \
        "/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd" \
        "/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd" \
        "/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd"; do
        read -r code vars <<<"${pair}"
        if [[ -f ${code} && -f ${vars} ]]; then
            FW_CODE=${code}
            FW_VARS=${vars}
            return
        fi
    done
    die "no x86_64 UEFI firmware found (qemu's edk2-x86_64-code.fd, or OVMF): set FW_CODE and FW_VARS to its code and vars files"
}

accel() {
    if [[ $(uname -s) == Linux && $(uname -m) == x86_64 && -w /dev/kvm ]]; then
        echo "-accel kvm -cpu host"
    else
        echo "-accel tcg,thread=multi -cpu max"
    fi
}

# Clone the image where the filesystem can (APFS, btrfs, XFS), else copy.
clone() {
    if [[ $(uname -s) == Darwin ]]; then
        cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"
    else
        cp --reflink=auto "$1" "$2"
    fi
}

# --- the VM -------------------------------------------------------------------

# boot_vm LOG [extra qemu args...]: start QEMU in the background,
# exiting instead of rebooting, so a reboot ends the run.
boot_vm() {
    local log=$1
    shift
    # shellcheck disable=SC2046 # accel() is a list of words
    qemu-system-x86_64 \
        -machine q35 $(accel) -smp "${CPUS}" -m "${MEM}" \
        -drive if=pflash,format=raw,readonly=on,file="${FW_CODE}" \
        -drive if=pflash,format=raw,file="${WORK}/vars.fd" \
        -drive if=none,id=target,format=qcow2,file="${WORK}/disk.qcow2" \
        -device virtio-blk-pci,drive=target,serial="${DISK_SERIAL}",bootindex=2 \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
        -device virtio-net-pci,netdev=n0 \
        -display none -serial file:"${log}" -monitor none \
        -no-reboot \
        "$@" &
    QEMU_PID=$!
}

SSH_OPTS=(
    -i "${WORK}/id_ed25519" -p "${SSH_PORT}"
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15
)
# shellcheck disable=SC2029 # the remote commands are meant to be expanded here
vm() { ssh "${SSH_OPTS[@]}" "$@"; }

wait_ssh() {
    local user=$1 deadline=$((SECONDS + BOOT_WAIT * 60))
    printf 'Waiting for ssh %s@localhost:%s ' "${user}" "${SSH_PORT}"
    until vm "${user}@127.0.0.1" true 2>/dev/null; do
        kill -0 "${QEMU_PID}" 2>/dev/null || { echo; die "QEMU exited before ssh answered (see $2)"; }
        ((SECONDS < deadline)) || { echo; die "no ssh after ${BOOT_WAIT} minutes (see $2)"; }
        printf .
        sleep 5
    done
    echo " up ($(elapsed))"
}

# Wait for QEMU to exit by itself (the guest rebooted or powered off).
wait_exit() {
    local deadline=$((SECONDS + 300))
    while kill -0 "${QEMU_PID}" 2>/dev/null; do
        ((SECONDS < deadline)) || die "the VM did not reboot within 5 minutes"
        sleep 2
    done
    wait "${QEMU_PID}" 2>/dev/null || true
    QEMU_PID=
}

# --- the test -----------------------------------------------------------------

main() {
    local image
    command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 is not installed (brew install qemu)"
    command -v qemu-img >/dev/null || die "qemu-img is not installed"
    image=$(find_image "${1:-}")
    find_firmware
    mkdir -p "${WORK}"
    rm -f "${WORK}"/*.log

    phase "Prepare $(basename "${image}")"
    [[ -f ${WORK}/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C setup-test -f "${WORK}/id_ed25519"
    rm -rf "${WORK}/secrets"
    mkdir -p "${WORK}/secrets/ssh"
    cp "${WORK}/id_ed25519.pub" "${WORK}/secrets/ssh/authorized_keys"
    clone "${image}" "${WORK}/stick.img"
    if ! BOOMSTICK_SECRETS="${WORK}/secrets" "${ROOT}/provision.sh" "${WORK}/stick.img" \
        >"${WORK}/provision.log" 2>&1; then
        cat "${WORK}/provision.log" >&2
        die "provisioning the test stick failed"
    fi
    # The test stick has no WiFi, WireGuard or webhook on purpose.
    grep -v '^WARNING:' "${WORK}/provision.log" || true
    qemu-img create -q -f qcow2 "${WORK}/disk.qcow2" "${DISK_SIZE}"
    # Writable: the firmware keeps its variables there, and the source
    # may be read-only (every file in the Nix store is), so is a copy
    # kept by an earlier KEEP=1 run.
    rm -f "${WORK}/vars.fd"
    cp "${FW_VARS}" "${WORK}/vars.fd"
    chmod u+w "${WORK}/vars.fd"
    cat >"${WORK}/host.env" <<EOF
HOSTNAME=${HOST}
DISK=/dev/disk/by-id/virtio-${DISK_SERIAL}
ENCRYPT=${ENCRYPT}
SWAP_SIZE=1g
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
ADMIN_NOPASSWD=yes
EOF
    printf 'root:%s\nadmin:%s\nuser:%s\n' "${PASSWORD}" "${PASSWORD}" "${PASSWORD}" >"${WORK}/passwords"

    phase "Boot the stick"
    boot_vm "${WORK}/serial-live.log" \
        -drive if=none,id=stick,format=raw,file="${WORK}/stick.img" \
        -device qemu-xhci -device usb-storage,drive=stick,bootindex=1
    wait_ssh root "${WORK}/serial-live.log"

    phase "Copy this tree's setup and the test answers"
    vm root@127.0.0.1 'cat >/usr/local/bin/setup && chmod 755 /usr/local/bin/setup' <"${ROOT}/airootfs/usr/local/bin/setup"
    vm root@127.0.0.1 'cat >/root/test-host.env' <"${WORK}/host.env"
    vm root@127.0.0.1 'umask 077 && cat >/root/test-passwords' <"${WORK}/passwords"

    phase "setup host"
    vm root@127.0.0.1 setup host --from /root/test-host.env

    phase "setup disk"
    if [[ ${ENCRYPT} == yes ]]; then
        # cryptsetup reads the passphrase from the terminal: give it one,
        # and type the passphrase three times (set, verify, open).
        printf '%s\n%s\n%s\n' "${PASSWORD}" "${PASSWORD}" "${PASSWORD}" \
            | vm -tt root@127.0.0.1 setup --yes disk --confirm-wipe "${HOST}"
    else
        vm root@127.0.0.1 setup --yes disk --confirm-wipe "${HOST}"
    fi

    phase "setup install"
    vm root@127.0.0.1 setup --yes install --passwords /root/test-passwords

    phase "setup reboot"
    vm root@127.0.0.1 setup --yes reboot || true
    wait_exit

    phase "Boot the installed disk"
    if [[ ${ENCRYPT} == yes ]]; then
        echo "ENCRYPT=yes: the installed system waits for its passphrase on the console,"
        echo "which this test cannot type yet. Stopping after the install."
        echo "PASS (install only)"
        return
    fi
    boot_vm "${WORK}/serial-installed.log"
    wait_ssh admin "${WORK}/serial-installed.log"

    phase "Check the installed system"
    vm admin@127.0.0.1 bash -s <<'EOF'
set -u
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "hostname is setuptest"     '[ "$(cat /etc/hostname)" = setuptest ]'
check "/ is the @ subvolume"      'findmnt -no SOURCE / | grep -q "\[/@\]$"'
check "/home is @home"            'findmnt -no SOURCE /home | grep -q "\[/@home\]$"'
check "swap is on"                'swapon --show=NAME --noheadings | grep -qx /swap/swapfile'
check "admin has passwordless sudo" 'sudo -n true'
check "user exists, not in wheel" 'id user && ! id -nG user | grep -qw wheel'
check "root cannot ssh"           'sudo -n sshd -T | grep -qix "permitrootlogin no"'
check "passwords are refused"     'sudo -n sshd -T | grep -qix "passwordauthentication no"'
check "host repo is admin's"      '[ "$(stat -c %U ~/arch/host.env)" = admin ]'
check "no failed units"           '[ -z "$(systemctl --failed --no-legend)" ]'
systemctl --failed --no-legend
exit $fail
EOF
    vm admin@127.0.0.1 sudo -n systemctl poweroff || true
    wait_exit
    echo
    echo "PASS ($(elapsed))"
}

main "$@"
