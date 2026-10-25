archiso-config - the configuration for this Arch Linux live USB
===============================================================

The image on this stick is generic and contains no secrets. Everything
that makes it yours lives in this directory and is read on every boot,
before WiFi, WireGuard and SSH start. Edit these files from any
computer, then boot the stick.

  ssh/authorized_keys    public keys allowed to log in as root (required)
  wifi/<SSID>.psk        one file per WiFi network (optional)
  wireguard/wg0.conf     WireGuard tunnel brought up at boot (optional)
  webhook.env            URL notified at boot with this machine's addresses (optional)
  ssh/host/              this stick's SSH host keys (created on first boot)

Files that are missing, empty or entirely commented out are ignored, and
the feature they configure is skipped.

Keep this partition labelled ARCH_CONFIG. That label is how the live
system finds it: on a machine with enough RAM the live system is copied
to RAM and the boot partition is unmounted before anything runs, so the
label is all there is to go on.

On the first boot the live system generates its SSH host keys and writes
them back to ssh/host/ here, so the fingerprint is the same on every
later boot. Delete that directory to get new ones.

WARNING: nothing here is encrypted, and any computer this stick is
plugged into can read it. The stick itself is the secret: whoever holds
it can join your WiFi and your VPN. Give each stick its own WireGuard
key, so you can revoke one without touching the others.

https://github.com/EnigmaCurry/archlinux-boomstick
