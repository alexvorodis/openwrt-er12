#!/bin/bash
# Build OpenWrt firmware for the Ubiquiti EdgeRouter 12.
#
# Usage: ./build.sh
#
# Prerequisites (Debian/Ubuntu):
#   sudo apt install build-essential git python3 rsync wget libncurses-dev \
#     flex bison gawk unzip file subversion quilt gettext zlib1g-dev \
#     libssl-dev xsltproc libxml-parser-perl
#
# The build takes ~2-4 hours on a modern machine and needs ~30 GB disk.
# Output: openwrt/bin/targets/octeon/generic/openwrt-octeon-generic-ubnt_edgerouter-12-*
set -euo pipefail

REPO_URL="https://github.com/dmascord/openwrt.git"
REPO_BRANCH="openwrt/add-ubiquiti-er-12"
BASE_COMMIT="2cd1a10829"  # merge-base with upstream OpenWrt master (before ER-12 commits)
BUILD_DIR="openwrt"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== OpenWrt EdgeRouter 12 build ==="
echo ""

# Check prerequisites
for cmd in git make gcc python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd not found. Install build dependencies first."; exit 1; }
done

# Clone or update
if [ -d "$BUILD_DIR/.git" ]; then
    echo "Updating existing clone..."
    cd "$BUILD_DIR"
    git fetch origin
    git checkout "$REPO_BRANCH"
    git reset --hard "$BASE_COMMIT"
else
    echo "Cloning OpenWrt (dmascord fork, branch $REPO_BRANCH)..."
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$BUILD_DIR"
    cd "$BUILD_DIR"
    git checkout "$BASE_COMMIT"
fi

# Copy kernel patches (703-716 + 900 device definition) — OpenWrt applies them automatically
echo "Copying ER-12 patches..."
cp "$SCRIPT_DIR"/patches/6.18/*.patch target/linux/octeon/patches-6.18/

# Copy DTS
echo "Copying device tree..."
cp "$SCRIPT_DIR"/dts/cn7130_ubnt_edgerouter-12.dts \
   target/linux/octeon/files/arch/mips/boot/dts/cavium-octeon/

# Copy base-files overlay (er12-fabric, uci-defaults, board.d, upgrade hooks)
echo "Copying base-files overlay..."
cp -a "$SCRIPT_DIR"/base-files/* target/linux/octeon/base-files/

# Feeds
echo "Updating and installing feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# Copy build config (after feeds — .config references package symbols)
echo "Copying .config..."
cp "$SCRIPT_DIR"/config/.config .

# Build
echo ""
echo "=== Starting build ($(nproc) jobs) ==="
make -j"$(nproc)" world

echo ""
echo "=== Build complete ==="
echo "Images:"
ls -lh bin/targets/octeon/generic/openwrt-octeon-generic-ubnt_edgerouter-12-* 2>/dev/null || echo "(check bin/targets/octeon/generic/)"
