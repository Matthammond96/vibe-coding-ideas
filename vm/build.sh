#!/bin/bash
set -e

ALPINE_VERSION="3.19"

# Determine architecture (from arg or auto-detect)
if [ -n "$1" ]; then
    ARCH="$1"
else
    case "$(uname -m)" in
        "arm64" | "aarch64") ARCH="arm64" ;;
        "x86_64" | "amd64") ARCH="x86_64" ;;
        *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
fi

# Set arch-specific variables
case "$ARCH" in
    "arm64")
        ALPINE_ARCH="aarch64"
        DOCKER_PLATFORM="linux/arm64"
        ;;
    "x86_64")
        ALPINE_ARCH="x86_64"
        DOCKER_PLATFORM="linux/amd64"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64]"
        exit 1
        ;;
esac

# Separate build artifacts from runtime images
BUILD_DIR="build/$ARCH"
OUTPUT_DIR="images/$ARCH"

echo "=== Building $ARCH Alpine VM Image ==="

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# Download kernel to runtime dir (needed at runtime)
if [ ! -f "$OUTPUT_DIR/vmlinuz" ]; then
    echo "Downloading $ARCH kernel..."
    wget -q "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/netboot/vmlinuz-virt" \
        -O "$OUTPUT_DIR/vmlinuz"
fi

# Download modloop to build dir (only needed for module extraction)
if [ ! -f "$BUILD_DIR/modloop-virt" ]; then
    echo "Downloading $ARCH modules..."
    wget -q "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/netboot/modloop-virt" \
        -O "$BUILD_DIR/modloop-virt"
fi

# Extract modules to build dir (using Docker for cross-platform compatibility)
if [ ! -d "$BUILD_DIR/modules" ]; then
    echo "Extracting $ARCH kernel modules..."
    mkdir -p "$BUILD_DIR/modules"
    docker run --rm --platform "$DOCKER_PLATFORM" \
        -v "$(pwd)/$BUILD_DIR/modloop-virt:/modloop.squashfs:ro" \
        -v "$(pwd)/$BUILD_DIR/modules:/output" \
        alpine:latest sh -c '
            apk add --no-cache squashfs-tools > /dev/null 2>&1
            cd /output
            unsquashfs -f -d . /modloop.squashfs > /dev/null 2>&1
            mkdir -p lib/modules
            mv modules/* lib/modules/ 2>/dev/null || true
            rmdir modules 2>/dev/null || true
        '
fi

# Build container image
echo "Building $ARCH container image..."
docker buildx build --platform "$DOCKER_PLATFORM" --build-arg TARGETPLATFORM="$DOCKER_PLATFORM" \
    -t "vibecodes/host-vm:$ARCH" --load .

# Export filesystem to build dir
docker rm -f "temp-$ARCH" 2>/dev/null || true
docker create --platform "$DOCKER_PLATFORM" --name "temp-$ARCH" "vibecodes/host-vm:$ARCH"
docker export "temp-$ARCH" -o "$BUILD_DIR/rootfs.tar"
docker rm "temp-$ARCH"

# Create initramfs (output to runtime dir)
echo "Creating $ARCH initramfs..."
docker run --rm --platform "$DOCKER_PLATFORM" \
    -v "$(pwd)/$BUILD_DIR/rootfs.tar:/rootfs.tar:ro" \
    -v "$(pwd)/$BUILD_DIR/modules:/modules:ro" \
    -v "$(pwd)/$OUTPUT_DIR:/output" \
    alpine:latest sh -c '
        cd /tmp
        tar -xf /rootfs.tar

        # Copy modules
        mkdir -p lib
        cp -r /modules/lib/modules lib/

        # Verify init
        if [ ! -f init ]; then
            echo "ERROR: /init not found!"
            exit 1
        fi
        chmod +x init

        # Create cpio archive
        find . | cpio -o -H newc 2>/dev/null | gzip > /output/rootfs.cpio.gz
    '

echo "=== $ARCH build complete ==="
echo ""
echo "Runtime images (needed for VM):"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "Build artifacts (can be cleaned with: rm -rf build/):"
du -sh "$BUILD_DIR"
