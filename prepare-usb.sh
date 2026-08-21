#!/bin/bash
# Prepare a USB stick for flashing the Ubiquiti EdgeRouter 12.
# Wipes the given device and copies the two firmware images (+ sha256sums).
#
# Usage: ./prepare-usb.sh [firmware-dir]
#   firmware-dir must contain:
#     openwrt-octeon-generic-ubnt_edgerouter-12-initramfs-kernel.bin
#     openwrt-octeon-generic-ubnt_edgerouter-12-squashfs-sysupgrade.tar
#     (optionally) sha256sums
set -euo pipefail

FIRMWARE_DIR="${1:-.}"
INITRAMFS="openwrt-octeon-generic-ubnt_edgerouter-12-initramfs-kernel.bin"
SYSUPGRADE="openwrt-octeon-generic-ubnt_edgerouter-12-squashfs-sysupgrade.tar"

echo "=== Prepare USB stick for EdgeRouter 12 flashing ==="
echo ""

for f in "$INITRAMFS" "$SYSUPGRADE"; do
    if [ ! -f "$FIRMWARE_DIR/$f" ]; then
        echo "Error: $FIRMWARE_DIR/$f not found"
        echo "Usage: $0 [firmware-dir]"
        exit 1
    fi
done

echo "Available devices:"
lsblk -d -o NAME,SIZE,MODEL | grep -vE "loop|sr"
echo ""
read -r -p "Enter device name (e.g. sdb): " DEVICE
DEVICE="/dev/${DEVICE}"

if [ ! -b "${DEVICE}" ]; then
    echo "Error: ${DEVICE} not found"
    exit 1
fi

echo ""
echo "WARNING: all data on ${DEVICE} will be erased!"
read -r -p "Continue? (yes/no): " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted"; exit 0; }

echo "Unmounting..."
sudo umount "${DEVICE}"* 2>/dev/null || true

echo "Formatting FAT32..."
sudo mkfs.vfat -F 32 "${DEVICE}1"

echo "Mounting..."
MOUNT_POINT="/tmp/er12-usb"
sudo mkdir -p "$MOUNT_POINT"
sudo mount "${DEVICE}1" "$MOUNT_POINT"

echo "Copying initramfs..."
sudo cp "$FIRMWARE_DIR/$INITRAMFS" "$MOUNT_POINT/"
echo "Copying sysupgrade image..."
sudo cp "$FIRMWARE_DIR/$SYSUPGRADE" "$MOUNT_POINT/"
if [ -f "$FIRMWARE_DIR/sha256sums" ]; then
    echo "Copying sha256sums..."
    sudo cp "$FIRMWARE_DIR/sha256sums" "$MOUNT_POINT/"
    echo "Verifying checksums on the stick..."
    sudo chown "$USER" "$MOUNT_POINT/sha256sums" 2>/dev/null || true
    ( cd "$MOUNT_POINT" && sha256sum -c sha256sums 2>&1 | grep -v "buildinfo\|manifest\|profiles.json\|version.buildinfo" ) || true
fi

echo ""
echo "=== Files on the stick ==="
ls -lh "$MOUNT_POINT/"

sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

echo ""
echo "=== Done ==="
echo "Safely remove the stick and plug it into the router."
echo "See INSTALL.md for the U-Boot flashing commands."
