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

 * Linux (any distro) on x86_64.
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

## Commands

| Command | Does |
|---|---|
| `just config` | Create missing secret files as commented-out templates |
| `just keygen` | Generate a WireGuard key pair for the ISO (in a Podman container) |
| `just build` | Build the ISO into `secrets/out/` (in a Podman container) |
| `just inspect [ISO]` | Show secrets/overlay files in an ISO and check permissions |
| `just clean` | Remove the cached pacman packages volume |

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
inspect.sh       # checks a built ISO
packages.extra   # packages added to releng's list
secrets/         # git-ignored: your secrets and built ISOs
```
