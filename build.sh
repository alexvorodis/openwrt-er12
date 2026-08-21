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

LOGFILE="build-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOGFILE") 2>&1
echo "Log: $PWD/$LOGFILE"

REPO_URL="https://github.com/dmascord/openwrt.git"
REPO_BRANCH="openwrt/add-ubiquiti-er-12"
BASE_COMMIT="fd43f49717"  # ER-12 support on top of OpenWrt master 2026-05-26 (kernel 6.18)
BUILD_DIR="openwrt"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== OpenWrt EdgeRouter 12 build ==="
echo ""

# Check prerequisites
for cmd in git make gcc python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd not found. Install build dependencies first."; exit 1; }
done

# Ensure python3 is findable by OpenWrt's prerequisite check (SetupHostCommand).
# OpenWrt runs checks with PATH="$(ORIG_PATH)" which may differ from the
# interactive shell PATH. Pre-create symlinks in staging_dir/host/bin so
# the check passes immediately.
PYTHON_BIN="$(command -v python3)"
PYTHON_DIR="$(dirname "$PYTHON_BIN")"
echo "Python: $PYTHON_BIN"
export PATH="$PYTHON_DIR:$PATH"

# Clone or update
if [ -d "$BUILD_DIR/.git" ]; then
    echo "Updating existing clone..."
    cd "$BUILD_DIR"
    git fetch origin
    # Force-checkout and drop leftovers from older overlay-style builds
    # (previously copied patches/DTS/base-files now live in the tree itself)
    git checkout -f "$REPO_BRANCH"
    git reset -q --hard "$BASE_COMMIT"
    git clean -qfd target tools toolchain package include scripts
else
    echo "Cloning OpenWrt (dmascord fork, branch $REPO_BRANCH)..."
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$BUILD_DIR"
    cd "$BUILD_DIR"
    git checkout "$BASE_COMMIT"
fi

# Wipe build artifacts when the base commit changes — stale toolchain/kernel
# objects from a different base corrupt the build.
BASE_MARKER=".openwrt-base"
if [ ! -f "$BASE_MARKER" ] || [ "$(cat "$BASE_MARKER")" != "$BASE_COMMIT" ]; then
    if [ -d build_dir ] || [ -d staging_dir ]; then
        echo "Base commit changed -> cleaning build artifacts..."
        rm -rf build_dir staging_dir tmp .ccache logs
    fi
    echo "$BASE_COMMIT" > "$BASE_MARKER"
fi

# Apply our fixups on top of the base commit.
# dmascord's ER-12 commit ships patch 711 empty while 709/710/714 call
# its accessors - overwrite it with a working implementation.
echo "Copying extra kernel patches..."
mkdir -p target/linux/octeon/patches-6.18
cp "$SCRIPT_DIR"/patches/6.18/711-*.patch target/linux/octeon/patches-6.18/

# Feeds
echo "Updating and installing feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# Copy build config (after feeds — .config references package symbols)
echo "Copying .config..."
cp "$SCRIPT_DIR"/config/.config .

# Pre-create python symlinks in staging_dir/host/bin so OpenWrt's
# prerequisite check finds them even if ORIG_PATH differs from shell PATH.
echo "Pre-creating python symlinks..."
mkdir -p staging_dir/host/bin
ln -sf "$PYTHON_BIN" staging_dir/host/bin/python 2>/dev/null || true
ln -sf "$PYTHON_BIN" staging_dir/host/bin/python3 2>/dev/null || true

# Build
echo ""
echo "=== Starting build ($(nproc) jobs) ==="
make -j"$(nproc)" world

echo ""
echo "=== Build complete ==="
echo "Images:"
ls -lh bin/targets/octeon/generic/openwrt-octeon-generic-ubnt_edgerouter-12-* 2>/dev/null || echo "(check bin/targets/octeon/generic/)"
