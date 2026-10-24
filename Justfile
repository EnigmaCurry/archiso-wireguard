# List recipes
default:
    @just --list

# Create missing secret files as commented-out templates
config:
    ./config.sh

# Build the ISO (with secrets) into secrets/out/, inside a Podman container
build:
    ./build.sh

# List secrets and overlay files in an ISO (owner/mode only) and check secrets are root-only
inspect *iso:
    ./inspect.sh {{iso}}

# Remove the container's cached pacman packages (next build re-downloads)
clean:
    podman volume rm --force archiso-wireguard-pacman-cache
