# List recipes
default:
    @just --list

# Build the ISO (with secrets) into secrets/out/
build:
    ./build.sh

# Delete the transient build directory (keeps secrets and built ISOs)
clean:
    [ ! -e secrets/build ] || unshare --map-auto --map-root-user -- rm -rf -- secrets/build
