# archiso-wireguard

Build a personal Arch Linux live USB that comes up **online and on your
WireGuard VPN by itself**, so you can SSH in from anywhere and drive the
install remotely.

It is the stock Arch Linux installer (archiso's `releng` profile) plus:

 * **WiFi** networks that iwd joins automatically (wired ethernet is
   preferred when both are available).
 * A **WireGuard** tunnel (`wg-quick@wg0`) to your own peer, brought up
   at boot, retrying until the endpoint's DNS name resolves.
 * **SSH** as root with your `authorized_keys` (key-only, no passwords)
   and fixed host keys, so the fingerprint is the same on every boot.
 * Hostname `arch-iso`.
 * An optional **boot webhook** (e.g. ntfy or matrix-hookshot) that
   reports the LAN, public and WireGuard addresses, or the WireGuard
   error if the tunnel didn't come up.

The image boots without any prompts.

**The image itself is generic and contains no secrets.** Your WiFi
passwords, WireGuard key and SSH keys live in an `archiso-config/`
directory on the stick's FAT32 partition, which you fill in *after*
writing the image. The same image works for everyone; the stick is what
is yours.

> [!WARNING]
> **A configured stick contains secrets**, in plain text, readable by
> any computer it is plugged into. Anyone holding it can join your WiFi
> and your VPN. Keep it in your possession, and give each stick its own
> WireGuard key so you can revoke one on its own.

## Requirements

 * Linux (any distro) on x86_64. Other hosts (arm64 Linux, macOS with
   `podman machine`) also work: see
   [Building for the other architecture](#building-for-the-other-architecture).
 * [Podman](https://podman.io/), working rootless. Your user needs
   subordinate uid/gid ranges (`grep $USER /etc/subuid /etc/subgid`),
   which most distros set up when the user is created.
 * [just](https://github.com/casey/just).
 * About 8 GB of free disk space (build workspace, package cache and the
   image) and an internet connection.

You don't need archiso or any Arch packages on the host: the build runs
inside an `archlinux` container.

On Arch Linux:

```
sudo pacman -S --needed podman just git
```

You also need a **WireGuard peer** (a server, router, or VPN hub) with a
public IP or DNS name that the stick can connect to, unless you use it
without WireGuard.

## Bootstrap

### 1. Clone the repo

```
git clone https://github.com/EnigmaCurry/archiso-wireguard.git
cd archiso-wireguard
```

### 2. Build the image

```
just build-usb
```

This builds one image that boots **x86_64 PCs (UEFI)** and the
**Raspberry Pi 5**, into
`out/arch-usb-<date>-x86_64+rpi5.img` (about 2.7 GB). The first build
pulls the `archlinux` image and downloads about 1 GB of packages; later
builds reuse a package cache and take a few minutes.

There is nothing to configure yet: the build takes no input and the
result is the same for everybody. `just build` (x86_64 ISO only) and
`just build-rpi5` (Pi only) build the other two targets.

### 3. Write it to a USB stick

Find the device with `lsblk`, then (this erases the stick):

```
sudo dd if=out/arch-usb-<date>-x86_64+rpi5.img \
  of=/dev/sdX bs=4M status=progress oflag=sync
```

### 4. Configure the stick

Replug the stick. Its FAT32 partition (labelled `ARCH_CONFIG`) mounts on
any computer and contains:

```
archiso-config/
  README.txt             what this directory is
  ssh/authorized_keys    public keys allowed in as root (required)
  wifi/<SSID>.psk        one file per WiFi network (optional)
  wireguard/wg0.conf     WireGuard tunnel (optional)
  webhook.env            boot webhook URL (optional)
```

Every file starts out as a commented-out template. Edit them in place
with any editor, on any OS, and keep the stick for later edits: the live
system reads them on **every** boot, so you can move the stick to a new
WiFi network without rebuilding anything.

What to put in each file is described in
[Configuration](#configuration) below. Files you leave commented out are
ignored and the feature is skipped.

Instead of editing by hand, you can keep the files in the repo and copy
them over:

```
just config                                  # create secrets/ templates
$EDITOR secrets/...                          # fill them in
just provision /run/media/you/ARCH_CONFIG    # copy them to the stick
```

`just provision` checks the files before copying (a `wg0.conf` without a
`PersistentKeepalive`, an `authorized_keys` with no key) so a typo fails
here instead of leaving a headless machine unreachable. Its argument may
be a mounted config partition, a `/dev/sdX` device, or an image in
`out/` you are about to write; with no argument it uses the newest image
in `out/`.

### 5. Boot and connect

Boot the target machine from the stick. Plug in ethernet, or be in range
of one of your WiFi networks. On the **first** boot the live system
generates its SSH host keys and writes them back to
`archiso-config/ssh/host/` on the stick, so every later boot presents
the same fingerprint.

Once the webhook arrives (or after a minute or two), SSH in over the
VPN:

```
ssh root@10.0.0.2
```

Without WireGuard, SSH to the LAN address from the webhook (or from
`ip addr` on the console) instead.

To confirm the host key on first connect, compare with the fingerprint
the live system printed on the console, or compute it from the stick:

```
ssh-keygen -lf /run/media/you/ARCH_CONFIG/archiso-config/ssh/host/ssh_host_ed25519_key.pub
```

From there, install Arch as usual (`archinstall`, or the
[installation guide](https://wiki.archlinux.org/title/Installation_guide)).

## Configuration

These are the files in `archiso-config/` on the stick (or in `secrets/`
in the repo, if you use `just provision`).

### WireGuard (optional)

Leave `wireguard/wg0.conf` empty or fully commented out to boot without
WireGuard: the stick then only has SSH on the LAN, and the webhook
reports `WireGuard: not configured`.

Make a new key pair just for this stick:

```
just keygen
```

(or `wg genkey | tee /dev/stderr | wg pubkey` anywhere you have
`wireguard-tools`). Then fill in the template:

```ini
[Interface]
PrivateKey = <this stick's private key>
Address = 10.0.0.2/32

[Peer]
PublicKey = <your server's public key>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

 * `PersistentKeepalive` is **required** (`just provision` checks for
   it). Without it, the stick is unreachable behind NAT until it sends
   traffic first, so you couldn't SSH in.
 * `Endpoint` may be a DNS name; the tunnel keeps retrying until it
   resolves.
 * `DNS = ...` is supported if you want to resolve names through the
   VPN.

Then add the stick as a peer **on your WireGuard server**, using its
*public* key and the address you gave it:

```ini
[Peer]
# arch-iso
PublicKey = <the stick's public key>
AllowedIPs = 10.0.0.2/32
```

### SSH

Put the public key(s) you will log in with in `ssh/authorized_keys`, one
per line. Without at least one, nobody can log in over SSH at all.

`ssh/host/` is created by the live system on its first boot and holds
that stick's SSH host keys. Delete the directory to get new ones on the
next boot.

### WiFi (optional)

Without any WiFi files, the stick is wired-only. Add one file per
network in iwd's format, next to the `EXAMPLE.psk.example` template:

```ini
# wifi/My Network.psk
[Security]
Passphrase=your wifi password
```

 * Name the file after the SSID if it only contains letters, digits,
   spaces, `-` and `_`. Otherwise use `=` followed by the SSID in hex:

   ```
   echo "=$(printf '%s' 'Café' | od -An -tx1 | tr -d ' \n').psk"
   ```

 * Open networks use `<SSID>.open` (can be empty).
 * For hidden networks, add `[Settings]` with `Hidden=true`.
 * iwd doesn't support comments at the end of a line; put comments on
   their own lines.
 * `.example` files are ignored.

See `man 5 iwd.network` for everything else.

### Boot webhook (optional)

To get notified when the stick boots, set a URL in `webhook.env`:

```
WEBHOOK_URL=https://ntfy.sh/<a-long-random-topic>
```

Once the network is up and WireGuard connects (or gives up after two
minutes), it POSTs a plain-text message like this:

```
arch-iso is up (arch-iso 2026.10.24)
LAN: 192.168.1.50/24 on enp1s0
Public: 203.0.113.4
WireGuard: 10.0.0.2/32 on wg0 (handshake 3s ago)
```

The message contains your IP addresses. On a public service like
ntfy.sh, anyone who knows the topic name can read it, so use a long
random topic or a server with access control.

## How the configuration is loaded

Early in boot, before iwd, `wg-quick@wg0`, sshd and the webhook,
[`arch-iso-config`](airootfs/usr/local/bin/arch-iso-config) finds the
config partition and copies `archiso-config/` into the running system's
tmpfs, root-only:

| on the stick | in the live system |
|---|---|
| `wifi/*.psk` | `/var/lib/iwd/` (0600) |
| `wireguard/wg0.conf` | `/etc/wireguard/wg0.conf` (0600) |
| `ssh/authorized_keys` | `/root/.ssh/authorized_keys` (0600) |
| `webhook.env` | `/etc/arch-iso/webhook.env` (0600) |
| `ssh/host/*` | `/etc/ssh/` (0600), generated and saved back on the first boot |

It looks in two places, in this order:

 1. `/run/archiso/bootmnt/archiso-config`, when archiso left the
    partition it booted from mounted.
 2. Any filesystem labelled **`ARCH_CONFIG`**, which it mounts and
    unmounts again.

The second one is the usual case. archiso boots with `copytoram=auto`:
on a machine with enough RAM the live system is copied to RAM and the
boot partition is unmounted in the initramfs, so by the time anything
runs there is no `bootmnt` left. It is also the only way an **ISO** can
be configured, since ISO 9660 can't be edited after `dd`: format a
second USB stick FAT32 with that label and put `archiso-config/` on it
(copy [`config-templates/`](config-templates) to start from).

The label is therefore load-bearing. Relabel a stick's partition and,
on any machine that copies to RAM, the live system boots unconfigured.

Nothing is written back except the SSH host keys, and only once: the
partition is remounted read-write just long enough to save them, then
read-only again.

A stick with no configuration at all still boots. It just has no WiFi,
no VPN, no SSH login and no webhook, and says so on the console and in
the journal.

## Raspberry Pi 5

`just build-rpi5` builds the same live environment for the Raspberry
Pi 5, from [Arch Linux ARM](https://archlinuxarm.org/), as a disk image
for a USB stick or SD card. It is for installing to a Pi 5 whose NVMe
drive you can't easily take out: boot the stick, SSH in over the VPN,
and install to `/dev/nvme0n1` with `pacstrap`.

It is configured exactly like the x86_64 image, from `archiso-config/`
on its FAT32 partition. Two sticks made from the same configuration are
both "the arch-iso installer" on your VPN, but each generates its own
SSH host keys on first boot. Don't boot two at once: they would fight
over the WireGuard peer address.

Requirements: Podman and just, as above. It builds natively on an
**arm64** host, such as a Mac with Apple Silicon or an arm64 Linux
machine, and also on x86_64 with qemu-user (see
[Building for the other architecture](#building-for-the-other-architecture)).

On macOS:

```
brew install podman just
podman machine init --cpus 4 --memory 3072
podman machine start
```

Then:

```
just build-rpi5
just inspect
```

On an arm64 host, the first build downloads the Arch Linux ARM rootfs
(about 830 MB), checks its signature, and imports it as the
`localhost/archlinuxarm` Podman image for the build container. The
image is written to `out/arch-rpi5-<date>-aarch64.img` (the date is
UTC). Write it to a USB stick or SD card (this erases it). On macOS,
find the disk with `diskutil list`:

```
diskutil unmountDisk /dev/diskN
sudo dd if=out/arch-rpi5-<date>-aarch64.img of=/dev/rdiskN bs=4m
```

To boot the stick ahead of the NVMe, set the Pi's boot order (SD, then
USB, then NVMe) once. The live system has the tool for it:

```
rpi-eeprom-config --edit     # set BOOT_ORDER=0xf641, then reboot
```

With the stick removed, the Pi boots the NVMe as usual. With the
default `BOOT_ORDER=0xf461` (SD, NVMe, USB), a bootable NVMe always
wins and the stick is never tried. You can also run
`sudo rpi-eeprom-config --edit` from the OS on the NVMe.

What's different from the ISO:

 * The package list is releng's `packages.aarch64` with the changes in
   [`packages.rpi5`](packages.rpi5): the Raspberry Pi Foundation kernel
   `linux-rpi-16k` (Pi 5 only), Pi firmware, `rpi5-eeprom` and
   `raspberrypi-utils` instead of the generic arm64 kernel and UEFI
   boot loaders. Packages Arch Linux ARM doesn't have are skipped (the
   build lists them).
 * There is no boot loader: the Pi firmware loads `kernel8.img`, the
   initramfs and `cmdline.txt` from the FAT32 partition, and archiso's
   initramfs finds `arch/aarch64/airootfs.sfs` next to them by the
   partition's volume ID. With enough RAM (the image size plus 2 GiB)
   it is copied to RAM, so the stick can be pulled after boot; the
   configuration is read before that, by label (see
   [How the configuration is loaded](#how-the-configuration-is-loaded)).
 * When installing, use the Pi kernel, not `linux`:
   `pacstrap -K /mnt base linux-rpi-16k firmware-raspberrypi ...`, with
   a FAT32 `/boot` partition and `root=PARTUUID=...` in
   `/mnt/boot/cmdline.txt`.

## One stick for both (x86_64 + Raspberry Pi 5)

`just build-usb` builds one disk image that boots **x86_64 PCs (UEFI)**
and the **Raspberry Pi 5**. It builds the x86_64 ISO first
(`out/arch-iso-*.iso`, kept), then the Pi image with the ISO's UEFI boot
files and live system merged into its FAT32 partition, as
`out/arch-usb-<date>-x86_64+rpi5.img`.

The two systems and the configuration share the partition without
colliding:

```
config.txt cmdline.txt kernel8.img initramfs-linux.img *.dtb overlays/  # Pi 5 firmware
EFI/BOOT/BOOTx64.EFI loader/ arch/boot/x86_64/                          # x86_64 UEFI (systemd-boot)
arch/x86_64/airootfs.sfs  arch/aarch64/airootfs.sfs                     # the two live systems
archiso-config/                                                         # your configuration
boot/<uuid>.uuid                                                        # how each finds the stick
```

The Pi firmware only reads the top-level files and UEFI only `EFI/` and
`loader/`, and each initramfs loads `arch/<its architecture>/`. The
ISO's initramfs finds the stick by its `/boot/<uuid>.uuid` file, which is
archiso's support for copying an ISO onto a FAT32 stick.

Limits:

 * x86_64 boots with **UEFI only**: no legacy BIOS boot (that needs the
   ISO itself). Secure Boot must be off, as for the ISO.
 * The partition is FAT32 with MBR type `0x0c`, which the Pi requires.
   UEFI firmware is meant to boot from an EFI System Partition (type
   `0xef`), but almost all firmware also boots a FAT32 USB stick with
   `EFI/BOOT/BOOTx64.EFI`; a strict one may not.
 * Both systems read the same `archiso-config/`, and so present the
   same SSH host keys and the same WireGuard address.

## Building for the other architecture

The build container always matches the host: Arch Linux on x86_64, and
Arch Linux ARM (imported from its official rootfs, signature checked)
on arm64. When the target is the other architecture, pacman installs
the target's packages into the image, and only the programs that run
inside it (package install scripts, mkinitcpio) go through qemu-user
emulation via binfmt_misc. Downloads, squashfs compression and
everything else run natively, so a cross build is slower, but not by a
lot. `build.sh` says when it is doing one.

Podman on macOS (`podman machine`) already has qemu-user set up. On a
Linux host, install the static qemu-user emulators with binfmt_misc
rules, e.g. on Arch Linux:

```
sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt
```

(Debian/Ubuntu and Fedora: `qemu-user-static`.) The build checks that
it can run a target-architecture binary before it starts. The binfmt
entry (`/proc/sys/fs/binfmt_misc/qemu-aarch64` for rpi5,
`qemu-x86_64` for the ISO) needs the **F** flag, so it works inside
containers; the packages above set it.

## Commands

| Command | Does |
|---|---|
| `just build` | Build the x86_64 ISO into `out/` (in a Podman container) |
| `just build-rpi5` | Build the Raspberry Pi 5 image into `out/` (in a Podman container) |
| `just build-usb` | Build one image for x86_64 (UEFI) and the Pi 5 into `out/` (builds the ISO first) |
| `just config` | Create missing config files under `secrets/` as commented-out templates |
| `just keygen` | Generate a WireGuard key pair for a stick (in a Podman container) |
| `just provision [TARGET]` | Check `secrets/` and copy it onto a stick, device or image |
| `just inspect [IMAGE]` | List an image's overlay files and check it contains no secrets |
| `just clean` | Remove the cached pacman packages volumes |

## If a stick is lost

Remove its `[Peer]` from your WireGuard server, and change the passwords
of the WiFi networks it contained. The next stick should get a new
WireGuard key (`just keygen`); its SSH host keys are new anyway, since
they are generated per stick on first boot.

The built image itself is generic and holds nothing worth protecting:
`just inspect` fails if a secret ever ends up inside one, and tells you
if the image's config partition has been filled in (which makes that
image a secret too, so don't publish a provisioned one).

## How it works

`build.sh` starts a throwaway `archlinux` container (rootless Podman,
`--privileged`) with this repo bind-mounted. Inside, it copies archiso's
stock `releng` profile, lays [`airootfs/`](airootfs) on top, and runs
`mkarchiso`. No secret is involved at any point, so the build is
reproducible by anyone and its output is safe to share. Every step,
decision and problem along the way is recorded in [LOG.md](LOG.md).

```
airootfs/          # files added to the live system
build.sh           # build (host side starts the container)
config.sh          # creates secrets/ templates from config-templates/
config-templates/  # the archiso-config/ skeleton put on every image
inspect.sh         # checks a built ISO or .img
packages.extra     # packages added to releng's list
packages.rpi5      # rpi5 changes to releng's packages.aarch64
provision.sh       # copies secrets/ onto a stick's config partition
rpi5/airootfs/     # files added to the rpi5 live system only
secrets/           # git-ignored: your configuration
out/               # git-ignored: the built images
```
