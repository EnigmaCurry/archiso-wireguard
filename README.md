# archiso-wireguard

Build a personal Arch Linux live ISO that comes up **online and on your
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

The ISO boots without any prompts.

> [!WARNING]
> **The ISO contains secrets**: your WiFi passwords, the WireGuard
> private key, and the SSH host keys. Anyone with the ISO or the USB
> stick can join your WiFi and your VPN. Keep it in your possession, and
> give each image its own WireGuard key so you can revoke it alone. Built
> ISOs are named `arch-iso-CONTAINS-SECRETS-*.iso` as a reminder.

## Requirements

 * Linux (any distro) on x86_64. Other hosts (arm64 Linux, macOS with
   `podman machine`) also work: see
   [Building for the other architecture](#building-for-the-other-architecture).
 * [Podman](https://podman.io/), working rootless. Your user needs
   subordinate uid/gid ranges (`grep $USER /etc/subuid /etc/subgid`),
   which most distros set up when the user is created.
 * [just](https://github.com/casey/just).
 * About 8 GB of free disk space (build workspace, package cache and the
   ISO) and an internet connection.

You don't need archiso or any Arch packages on the host: the build runs
inside an `archlinux` container.

On Arch Linux:

```
sudo pacman -S --needed podman just git
```

You also need a **WireGuard peer** (a server, router, or VPN hub) with a
public IP or DNS name that the ISO can connect to, unless you build
without WireGuard (see step 3).

## Bootstrap

### 1. Clone the repo

```
git clone https://github.com/EnigmaCurry/archiso-wireguard.git
cd archiso-wireguard
```

### 2. Create the secret templates

```
just config
```

This creates a git-ignored `secrets/` directory with commented-out
templates. It never overwrites files that already exist, so it is safe
to run again.

```
secrets/
  wireguard/wg0.conf          # WireGuard config (optional)
  ssh/authorized_keys         # SSH public keys allowed in as root (required)
  wifi/EXAMPLE.psk.example    # WiFi network template (optional)
  webhook.env                 # boot webhook URL (optional)
```

Fill them in as described in the next steps.

### 3. WireGuard (optional)

To build without WireGuard, leave `secrets/wireguard/wg0.conf` empty
or fully commented out and skip to step 4. The ISO then only has SSH
on the LAN, and the webhook reports `WireGuard: not configured`.

Make a new key pair just for this ISO:

```
just keygen
```

Edit `secrets/wireguard/wg0.conf` and uncomment and fill in the
template:

```ini
[Interface]
PrivateKey = <the ISO's private key>
Address = 10.0.0.2/32

[Peer]
PublicKey = <your server's public key>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

 * `PersistentKeepalive` is **required** (the build checks for it).
   Without it, the ISO is unreachable behind NAT until it sends traffic
   first, so you couldn't SSH in.
 * `Endpoint` may be a DNS name; the tunnel keeps retrying until it
   resolves.
 * `DNS = ...` is supported if you want to resolve names through the
   VPN.

Then add the ISO as a peer **on your WireGuard server**, using the ISO's
*public* key and the address you gave it:

```ini
[Peer]
# arch-iso
PublicKey = <the ISO's public key>
AllowedIPs = 10.0.0.2/32
```

### 4. SSH

Add the public key(s) you will log in with:

```
cat ~/.ssh/id_ed25519.pub >> secrets/ssh/authorized_keys
```

The SSH host keys are generated automatically into `secrets/ssh/host/`
on the first build and reused after that.

### 5. WiFi (optional)

Without any WiFi files, the ISO is wired-only. Add one file per network
in iwd's format:

```
cp secrets/wifi/EXAMPLE.psk.example "secrets/wifi/My Network.psk"
```

```ini
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

See `man 5 iwd.network` for everything else.

### 6. Boot webhook (optional)

To get notified when the ISO boots, set a URL in `secrets/webhook.env`:

```
WEBHOOK_URL=https://ntfy.sh/<a-long-random-topic>
```

Once the network is up and WireGuard connects (or gives up after two
minutes), the ISO POSTs a plain-text message like this:

```
arch-iso is up (arch-iso-CONTAINS-SECRETS 2026.10.24)
LAN: 192.168.1.50/24 on enp1s0
Public: 203.0.113.4
WireGuard: 10.0.0.2/32 on wg0 (handshake 3s ago)
```

The message contains your IP addresses. On a public service like
ntfy.sh, anyone who knows the topic name can read it, so use a long
random topic or a server with access control.

### 7. Build

```
just build
```

The first build pulls the `archlinux` image and downloads about 1 GB of
packages; later builds reuse a package cache and take a few minutes.
The ISO is written to
`secrets/out/arch-iso-CONTAINS-SECRETS-<date>-x86_64.iso`.

The build refuses to start if a required secret is missing or still a
template, and warns if there is no WireGuard config, WiFi network or
webhook.

### 8. Check the ISO

```
just inspect
```

Lists the secrets and files this repo added to the ISO, with owner and
mode (never contents), and fails if any secret is readable by anyone but
root.

### 9. Write it to a USB stick

Find the device with `lsblk`, then (this erases the stick):

```
sudo dd if=secrets/out/arch-iso-CONTAINS-SECRETS-<date>-x86_64.iso \
  of=/dev/sdX bs=4M status=progress oflag=sync
```

### 10. Boot and connect

Boot the target machine from the stick. Plug in ethernet, or be in
range of one of your WiFi networks. Once the webhook arrives (or after a
minute or two), SSH in over the VPN:

```
ssh root@10.0.0.2
```

Without WireGuard, SSH to the LAN address from the webhook (or from
`ip addr` on the console) instead.

To confirm the host key on first connect, compare with:

```
ssh-keygen -lf secrets/ssh/host/ssh_host_ed25519_key.pub
```

From there, install Arch as usual (`archinstall`, or the
[installation guide](https://wiki.archlinux.org/title/Installation_guide)).

## Raspberry Pi 5

`just build-rpi5` builds the same live environment for the Raspberry
Pi 5, from [Arch Linux ARM](https://archlinuxarm.org/), as a disk image
for a USB stick or SD card. It is for installing to a Pi 5 whose NVMe
drive you can't easily take out: boot the stick, SSH in over the VPN,
and install to `/dev/nvme0n1` with `pacstrap`.

It uses the same `secrets/` (WiFi, WireGuard key, SSH keys, webhook) as
the x86_64 ISO, so both images are "the arch-iso installer" on your VPN
and present the same host key. Don't boot both at once: they would fight
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

Then, after the bootstrap steps 2-6 above:

```
just build-rpi5
just inspect
```

On an arm64 host, the first build downloads the Arch Linux ARM rootfs
(about 830 MB), checks its signature, and imports it as the
`localhost/archlinuxarm` Podman image for the build container. The
image is written to
`secrets/out/arch-rpi5-CONTAINS-SECRETS-<date>-aarch64.img` (the date is
UTC). Write it to a USB stick or SD card (this erases it). On macOS, find the disk with
`diskutil list`:

```
diskutil unmountDisk /dev/diskN
sudo dd if=secrets/out/arch-rpi5-CONTAINS-SECRETS-<date>-aarch64.img \
  of=/dev/rdiskN bs=4m
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
   it is copied to RAM, so the stick can be pulled after boot.
 * When installing, use the Pi kernel, not `linux`:
   `pacstrap -K /mnt base linux-rpi-16k firmware-raspberrypi ...`, with
   a FAT32 `/boot` partition and `root=PARTUUID=...` in
   `/mnt/boot/cmdline.txt`.

## One stick for both (x86_64 + Raspberry Pi 5)

`just build-usb` builds one disk image that boots **x86_64 PCs (UEFI)**
and the **Raspberry Pi 5**:

```
just build-usb
just inspect
```

It builds the x86_64 ISO first (`secrets/out/arch-iso-*.iso`, kept),
then the Pi image with the ISO's UEFI boot files and live system merged
into its FAT32 partition, as
`secrets/out/arch-usb-CONTAINS-SECRETS-<date>-x86_64+rpi5.img` (about
2.7 GB). Write it to a stick the same way as the Pi image above.

The two systems share the partition without colliding:

```
config.txt cmdline.txt kernel8.img initramfs-linux.img *.dtb overlays/  # Pi 5 firmware
EFI/BOOT/BOOTx64.EFI loader/ arch/boot/x86_64/                          # x86_64 UEFI (systemd-boot)
arch/x86_64/airootfs.sfs  arch/aarch64/airootfs.sfs                     # the two live systems
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
 * Both systems are the same installer with the same secrets and SSH
   host keys, as with the separate images.

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
| `just config` | Create missing secret files as commented-out templates |
| `just keygen` | Generate a WireGuard key pair for the ISO (in a Podman container) |
| `just build` | Build the ISO into `secrets/out/` (in a Podman container) |
| `just build-rpi5` | Build the Raspberry Pi 5 image into `secrets/out/` (in a Podman container) |
| `just build-usb` | Build one image for x86_64 (UEFI) and the Pi 5 into `secrets/out/` (builds the ISO first) |
| `just inspect [IMAGE]` | Show secrets/overlay files in an ISO or `.img` and check permissions |
| `just clean` | Remove the cached pacman packages volumes |

## If the ISO is lost

Remove the ISO's `[Peer]` from your WireGuard server, and change the
passwords of the WiFi networks it contained. Before building a
replacement, generate a new WireGuard key (step 3), and delete
`secrets/ssh/host/` to get new SSH host keys.

## How it works

`build.sh` starts a throwaway `archlinux` container (rootless Podman,
`--privileged`) with this repo bind-mounted, so secrets never end up in
a container image. Inside, it copies archiso's stock `releng` profile,
lays [`airootfs/`](airootfs) and the secrets on top, and runs `mkarchiso`.
Every step, decision and problem along the way is recorded in
[LOG.md](LOG.md).

```
airootfs/        # files added to the live system
build.sh         # build (host side starts the container)
config.sh        # creates secret templates
inspect.sh       # checks a built ISO or .img
packages.extra   # packages added to releng's list
packages.rpi5    # rpi5 changes to releng's packages.aarch64
rpi5/airootfs/   # files added to the rpi5 live system only
secrets/         # git-ignored: your secrets and built images
```
