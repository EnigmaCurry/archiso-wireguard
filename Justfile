# List recipes
default:
    @just --list

# Create missing secret files as commented-out templates
config:
    ./config.sh

# Generate a new WireGuard key pair for the ISO (prints private and public key)
keygen:
    podman run --rm docker.io/library/archlinux:latest sh -c \
      'pacman -Sy --noconfirm wireguard-tools >/dev/null && k=$(wg genkey) && echo "private: $k" && echo "public:  $(echo $k | wg pubkey)"'

# Build the ISO (with secrets) into secrets/out/, inside a Podman container
build:
    ./build.sh x86_64

# Build the Raspberry Pi 5 USB/SD image (with secrets) into secrets/out/, inside a Podman container
build-rpi5:
    ./build.sh rpi5

# Build one USB image that boots x86_64 PCs (UEFI) and the Raspberry Pi 5 into secrets/out/ (builds the ISO first)
build-usb:
    ./build.sh usb

# List secrets and overlay files in an ISO or .img (owner/mode only) and check secrets are root-only
inspect *image:
    ./inspect.sh {{image}}

# Remove the containers' cached pacman packages (next build re-downloads)
clean:
    podman volume rm --force archiso-wireguard-pacman-cache archiso-wireguard-pacman-cache-arm64
