# List recipes
default:
    @just --list

# Create missing config files under secrets/ as commented-out templates
config:
    ./config.sh

# Generate a new WireGuard key pair for a stick (prints private and public key)
keygen:
    podman run --rm docker.io/library/archlinux:latest sh -c \
      'pacman -Sy --noconfirm wireguard-tools >/dev/null && k=$(wg genkey) && echo "private: $k" && echo "public:  $(echo $k | wg pubkey)"'

# Build the generic x86_64 (UEFI) USB image into out/, inside a Podman container
build:
    ./build.sh x86_64

# Build the generic Raspberry Pi 5 USB/SD image into out/, inside a Podman container
build-rpi5:
    ./build.sh rpi5

# Build one generic USB image that boots x86_64 PCs (UEFI) and the Raspberry Pi 5 into out/ (needs both architectures)
build-usb:
    ./build.sh usb

# Copy secrets/ onto a stick's config partition (default: the mounted ARCH_CONFIG stick)
provision *target:
    ./provision.sh {{target}}

# List the overlay files in an image and check that it contains no secrets
inspect *image:
    ./inspect.sh {{image}}

# Remove the containers' cached pacman packages (next build re-downloads)
clean:
    podman volume rm --force archiso-wireguard-pacman-cache archiso-wireguard-pacman-cache-arm64
