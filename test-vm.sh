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
#   5. Checks the maintenance tools: a pacman transaction leaves a
#      snap-pac pre and post snapshot, and 'admin diff' (aconfmgr save
#      into a copy of ~/arch/aconfmgr) finds nothing the host repo does
#      not describe.
#   6. With DESKTOP=1: adds desktop/ (the book's Desktop chapter) to the
#      host repo, runs 'admin apply', reboots, and checks that greetd
#      greets and that 'user' can reach the Nix daemon. Then, as 'user',
#      installs sway-home with Home Manager (hm-install), has admin run
#      non-nixos-gpu-setup, and checks firefox and /run/opengl-driver,
#      and that 'admin diff' still finds no drift. Logging in to sway is
#      not tested. The Nix store this fills is over 12 GiB, so the disk
#      is 40 GB in this mode, and under TCG it takes hours.
#
# Needs qemu (brew install qemu, or pacman -S qemu-full), podman (as for
# the build, for provisioning) and ssh. On Apple Silicon the VM runs
# under emulation (TCG), so an install takes a while: the timings are
# printed as it goes. On an x86_64 Linux host with /dev/kvm it uses KVM.
#
# Environment:
#   ENCRYPT=yes      install with LUKS, as "setuptest": the passphrase is
#                    typed over a pty for setup disk, and again on the
#                    serial console for every boot of the installed disk.
#                    So that the initramfs asks there, this appends
#                    console=ttyS0 to the installed boot entry -- the one
#                    way the test machine differs from a real install.
#   KEEP=1           leave the VM's disks in test/ afterwards
#   DESKTOP=1        go on to install the desktop (step 6)
#   SWAY_HOME_DIR    a sway-home checkout to install in step 6, as a git
#                    bundle of its SWAY_HOME_REF (default HEAD); without
#                    it, SWAY_HOME_URL (GitHub) at SWAY_HOME_REF (master)
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
DESKTOP=${DESKTOP:-0}
SWAY_HOME_DIR=${SWAY_HOME_DIR:-}
SWAY_HOME_URL=${SWAY_HOME_URL:-https://github.com/EnigmaCurry/sway-home}
SWAY_HOME_REF=${SWAY_HOME_REF:-}
HOST=setuptest
# Deliberately not setup's default of "user": this is what proves a
# customised daily login actually reaches useradd, the check and the
# password file, instead of the default working by accident.
DAILY=${DAILY:-dailytest}
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
# Set while a boot is wired to a FIFO pair instead of a write-only log,
# so that something can be typed back at the VM's console.
CONSOLE_PIPE=
CONSOLE_FD=
CONSOLE_CAT_PID=

stop_vm() {
    [[ -n ${QEMU_PID} ]] || return 0
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
    QEMU_PID=
}

console_stop() {
    if [[ -n ${CONSOLE_FD} ]]; then exec {CONSOLE_FD}>&-; CONSOLE_FD=; fi
    if [[ -n ${CONSOLE_CAT_PID} ]]; then
        kill "${CONSOLE_CAT_PID}" 2>/dev/null || true
        CONSOLE_CAT_PID=
    fi
    if [[ -n ${CONSOLE_PIPE} ]]; then
        rm -f "${CONSOLE_PIPE}.in" "${CONSOLE_PIPE}.out"
        CONSOLE_PIPE=
    fi
}

cleanup() {
    console_stop
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
        # shellcheck disable=SC2012 # names are ours: boomstick-usb-<date>-<arch>.img
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
    # A write-only log file, unless a FIFO pair is up for a console we
    # have to type into (boot_installed under ENCRYPT=yes).
    local serial="file:${log}"
    if [[ -n ${CONSOLE_PIPE} ]]; then serial="pipe:${CONSOLE_PIPE}"; fi
    # shellcheck disable=SC2046 # accel() is a list of words
    qemu-system-x86_64 \
        -machine q35 $(accel) -smp "${CPUS}" -m "${MEM}" \
        -drive if=pflash,format=raw,readonly=on,file="${FW_CODE}" \
        -drive if=pflash,format=raw,file="${WORK}/vars.fd" \
        -drive if=none,id=target,format=qcow2,file="${WORK}/disk.qcow2" \
        -device virtio-blk-pci,drive=target,serial="${DISK_SERIAL}",bootindex=2 \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
        -device virtio-net-pci,netdev=n0 \
        -display none -serial "${serial}" -monitor none \
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

# boot_installed LOG: boot the installed disk. Without encryption that is
# just boot_vm. With it, the initramfs asks for the LUKS passphrase before
# anything else, so this boot gets a FIFO pair -- which can be typed into
# -- in place of the write-only log file, and answers the prompt.
boot_installed() {
    local log=$1
    console_stop
    if [[ ${ENCRYPT} != yes ]]; then
        boot_vm "${log}"
        return
    fi
    CONSOLE_PIPE="${WORK}/console"
    rm -f "${CONSOLE_PIPE}.in" "${CONSOLE_PIPE}.out"
    mkfifo "${CONSOLE_PIPE}.in" "${CONSOLE_PIPE}.out"
    : >"${log}"
    boot_vm "${log}"
    # O_RDWR on a FIFO never blocks, so this cannot hang if QEMU died;
    # holding it open keeps the VM's console from reading EOF in between.
    exec {CONSOLE_FD}<>"${CONSOLE_PIPE}.in"
    cat "${CONSOLE_PIPE}.out" >>"${log}" &
    CONSOLE_CAT_PID=$!
    type_passphrase "${log}"
}

# type_passphrase LOG: wait for the initramfs to ask, then answer it.
type_passphrase() {
    local log=$1 deadline=$((SECONDS + BOOT_WAIT * 60))
    printf 'Waiting for the LUKS passphrase prompt '
    until grep -qa 'Please enter passphrase' "${log}"; do
        kill -0 "${QEMU_PID}" 2>/dev/null \
            || { echo; die "QEMU exited before asking for the passphrase (see ${log})"; }
        ((SECONDS < deadline)) \
            || { echo; die "no passphrase prompt after ${BOOT_WAIT} minutes (see ${log})"; }
        printf .
        sleep 2
    done
    printf ' typing it (%s)\n' "$(elapsed)"
    printf '%s\n' "${PASSWORD}" >&"${CONSOLE_FD}"
}

# --- the test -----------------------------------------------------------------

# Step 6: the Desktop chapter, as the book does it: desktop/ into the
# host repo, admin apply, reboot.
desktop() {
    phase "Desktop: add desktop/ to the host repo and apply"
    # COPYFILE_DISABLE: no macOS ._ files in the archive.
    COPYFILE_DISABLE=1 tar --no-xattrs --exclude .DS_Store -C "${ROOT}/desktop" -cf - etc | vm admin@127.0.0.1 'tar -C ~/arch -xf -'
    vm admin@127.0.0.1 'cat >>~/arch/packages.txt' <"${ROOT}/desktop/packages.txt"
    vm admin@127.0.0.1 'cat >>~/arch/units.txt' <"${ROOT}/desktop/units.txt"
    vm admin@127.0.0.1 'git -C ~/arch add -A && git -C ~/arch -c user.name=test -c user.email=test@setuptest commit -qm Desktop'
    # aconfmgr --yes answers pacman with 'yes': a question it cannot
    # answer (which provider?) repeats forever. Bound it in time and size.
    if ! vm admin@127.0.0.1 'set -o pipefail; timeout 2400 admin apply --yes 2>&1 | head -c 50000000' \
        >"${WORK}/desktop-apply.log" 2>&1; then
        tail -n 20 "${WORK}/desktop-apply.log" >&2
        die "admin apply failed (see ${WORK}/desktop-apply.log)"
    fi
    grep -E '^Enabling units' "${WORK}/desktop-apply.log" || true
    vm admin@127.0.0.1 sudo -n systemctl poweroff || true
    wait_exit

    phase "Boot the desktop"
    boot_installed "${WORK}/serial-desktop.log"
    wait_ssh admin "${WORK}/serial-desktop.log"

    phase "Check the desktop"
    vm admin@127.0.0.1 "DAILY=${DAILY} bash -s" <<'EOF'
set -u
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "sway is installed"          'command -v sway swaylock swayidle'
check "greetd is running"          'systemctl is-active greetd'
check "tuigreet is greeting"       'pgrep -u greeter tuigreet'
check "nix-daemon.socket listens"  'systemctl is-active nix-daemon.socket'
check "${DAILY} can use the daemon" 'sudo -n -u "${DAILY}" nix store info'
check "flakes are on"              'nix config show experimental-features | grep -qw flakes'
check "no failed units"            '[ -z "$(systemctl --failed --no-legend)" ]'
systemctl --failed --no-legend
exit $fail
EOF

    phase "Desktop: sway-home for ${DAILY} (Home Manager)"
    # As the book does it: hm-install in the daily user's own systemd user
    # manager, which has a session bus. (Under a bare 'sudo -iu' there is none,
    # and home-manager's dconf step starts Nix's dbus-daemon, which looks
    # for /etc/dbus-1/session.conf: Arch keeps it under /usr/share.)
    # hm-install asks for git's name and email unless this file exists.
    local src ref=${SWAY_HOME_REF}
    if [[ -n ${SWAY_HOME_DIR} ]]; then
        # A local checkout (unpushed work): a branch of it, as a bundle.
        [[ -n ${ref} ]] || ref=$(git -C "${SWAY_HOME_DIR}" rev-parse --abbrev-ref HEAD)
        git -C "${SWAY_HOME_DIR}" bundle create "${WORK}/sway-home.bundle" "${ref}" 2>/dev/null
        vm admin@127.0.0.1 'cat >/tmp/sway-home.bundle && chmod 644 /tmp/sway-home.bundle' <"${WORK}/sway-home.bundle"
        src="/tmp/sway-home.bundle"
    else
        src=${SWAY_HOME_URL}
        ref=${ref:-master}
    fi
    # shellcheck disable=SC2016 # expanded on the VM
    vm admin@127.0.0.1 "sudo -n systemctl start user@\$(id -u ${DAILY}).service"
    vm admin@127.0.0.1 sudo -n systemd-run --machine="${DAILY}@.host" --user --pipe --wait --quiet --collect \
        -- bash -l -s <<EOF
set -euo pipefail
cd
git clone --quiet --branch '${ref}' '${src}' ~/git/vendor/enigmacurry/sway-home
mkdir -p ~/.config/git
printf '[user]\n\tname = setup test\n\temail = ${DAILY}@setuptest\n' >~/.config/git/config.local
cd ~/git/vendor/enigmacurry/sway-home
just hm-install
EOF
    # GPU drivers for programs from Nix: admin runs the daily user's command.
    # shellcheck disable=SC2016 # expanded on the VM, as admin
    vm admin@127.0.0.1 "sudo -n \"\$(sudo -n -iu ${DAILY} command -v non-nixos-gpu-setup)\""

    phase "Check sway-home"
    vm admin@127.0.0.1 "DAILY=${DAILY} bash -s" <<'EOF'
set -u
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "firefox (from Nix) runs as ${DAILY}" 'sudo -n -iu "${DAILY}" firefox --version'
check "foot, waybar and rofi are ${DAILY}'s" 'sudo -n -iu "${DAILY}" sh -c "command -v foot && command -v waybar && command -v rofi"'
check "/run/opengl-driver is linked"     '[ -e /run/opengl-driver ]'
check "sway config is in place"          'sudo -n test -e "$(getent passwd "${DAILY}" | cut -d: -f6)/.config/sway/config"'
sudo -n -iu "${DAILY}" firefox --version
exit $fail
EOF

    phase "admin diff after the desktop"
    vm admin@127.0.0.1 admin diff 2>/dev/null \
        || die "admin diff found drift after the desktop: the host repo does not describe it"
}

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
    if ! BOOMSTICK_SECRETS="${WORK}/secrets" "${ROOT}/provision.sh" --test-image "${WORK}/stick.img" \
        >"${WORK}/provision.log" 2>&1; then
        cat "${WORK}/provision.log" >&2
        die "provisioning the test stick failed"
    fi
    # The test stick has no WiFi, WireGuard or webhook on purpose.
    grep -v '^WARNING:' "${WORK}/provision.log" || true
    # The desktop's Nix store alone is over 12 GiB.
    [[ ${DESKTOP} == 1 ]] && DISK_SIZE=40G
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
DAILY=${DAILY}
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
ADMIN_NOPASSWD=yes
EOF
    # No root line: setup locks root and never asks for it.
    printf 'admin:%s\n%s:%s\n' "${PASSWORD}" "${DAILY}" "${PASSWORD}" >"${WORK}/passwords"

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
        # For LUKS, cryptsetup reads the passphrase from stdin up to the
        # first newline whenever stdin is not a terminal -- so send it on
        # a pipe and do NOT ask ssh for a pty (-tt). With a pty it prompts
        # on the terminal instead and flushes what is already buffered
        # there, which is what used to hang this step forever.
        # Three lines covers both cryptsetup calls (luksFormat, then open)
        # whether or not luksFormat asks a second time to verify; any line
        # left over is simply never read.
        printf '%s\n%s\n%s\n' "${PASSWORD}" "${PASSWORD}" "${PASSWORD}" \
            | vm root@127.0.0.1 setup --yes disk --confirm-wipe "${HOST}"
    else
        vm root@127.0.0.1 setup --yes disk --confirm-wipe "${HOST}"
    fi

    phase "setup install"
    vm root@127.0.0.1 setup --yes install --passwords /root/test-passwords

    if [[ ${ENCRYPT} == yes ]]; then
        # systemd-cryptsetup asks on /dev/console, which with no console=
        # is the virtual console -- which QEMU is not showing and this
        # test cannot type into. Point it at the serial line instead.
        phase "Point the installed console at ttyS0 (ENCRYPT=yes only)"
        vm root@127.0.0.1 \
            "sed -i '/^options/ s/\$/ console=ttyS0,115200/' /mnt/boot/loader/entries/arch.conf \
             && grep ^options /mnt/boot/loader/entries/arch.conf"
    fi

    phase "setup reboot"
    vm root@127.0.0.1 setup --yes reboot || true
    wait_exit

    phase "Boot the installed disk"
    boot_installed "${WORK}/serial-installed.log"
    wait_ssh admin "${WORK}/serial-installed.log"

    phase "Check the installed system"
    vm admin@127.0.0.1 "DAILY=${DAILY} bash -s" <<'EOF'
set -u
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "hostname is setuptest"     '[ "$(cat /etc/hostname)" = setuptest ]'
check "/ is the @ subvolume"      'findmnt -no SOURCE / | grep -q "\[/@\]$"'
check "/home is @home"            'findmnt -no SOURCE /home | grep -q "\[/@home\]$"'
check "swap is on"                'swapon --show=NAME --noheadings | grep -qx /swap/swapfile'
check "admin has passwordless sudo" 'sudo -n true'
check "root is locked"            'sudo -n passwd -S root | awk "{exit !(\$2 == \"L\")}"'
# The daily user starts with the administrator's keys, so you can log
# in as yourself on the first boot.
check "${DAILY} has admin's keys"  'sudo -n cmp -s ~admin/.ssh/authorized_keys "$(getent passwd "${DAILY}" | cut -d: -f6)/.ssh/authorized_keys"'
check "${DAILY} exists, not in wheel" 'id "${DAILY}" && ! id -nG "${DAILY}" | grep -qw wheel'
check "root cannot ssh"           'sudo -n sshd -T | grep -qix "permitrootlogin no"'
check "passwords are refused"     'sudo -n sshd -T | grep -qix "passwordauthentication no"'
check "host repo is admin's"      '[ "$(stat -c %U ~/arch/host.env)" = admin ]'
check "no failed units"           '[ -z "$(systemctl --failed --no-legend)" ]'
check "admin and aconfmgr are installed" 'command -v admin && aconfmgr --help'
check "snapper has a root config" 'sudo -n snapper --no-dbus -c root list'
systemctl --failed --no-legend
exit $fail
EOF

    phase "snap-pac snapshots pacman"
    # Reinstalling a package changes nothing aconfmgr looks at.
    vm admin@127.0.0.1 sudo -n pacman -S --noconfirm vim >/dev/null
    vm admin@127.0.0.1 sudo -n snapper --no-dbus -c root list
    [[ $(vm admin@127.0.0.1 sudo -n snapper --no-dbus -c root list --columns type) =~ pre.*post ]] \
        || die "no pre and post snapshot after a pacman transaction"

    phase "admin diff (aconfmgr)"
    # stderr is aconfmgr's progress; stdout says whether it found drift.
    vm admin@127.0.0.1 admin diff 2>/dev/null \
        || die "admin diff found drift: the host repo does not describe the fresh install"

    [[ ${DESKTOP} == 1 ]] && desktop

    vm admin@127.0.0.1 sudo -n systemctl poweroff || true
    wait_exit
    echo
    echo "PASS ($(elapsed))"
}

main "$@"
