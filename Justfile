# List recipes
default:
    @just --list

# Create missing secret files as commented-out templates
config:
    ./config.sh

# Build the ISO (with secrets) into secrets/out/, inside a Podman container
build:
    ./build.sh

# Remove the container's cached pacman packages (next build re-downloads)
clean:
    podman volume rm --force archiso-wireguard-pacman-cache
