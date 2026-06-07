#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_VERSION="${WINE_VERSION:-11.4}"
DXVK_VERSION="${DXVK_VERSION:-2.7.1}"
VKD3D_VERSION="${VKD3D_VERSION:-3.0.1}"

# Wine 11.x series mapping
WINE_SERIES="11.x"
WINE_URL="https://dl.winehq.org/wine/source/${WINE_SERIES}/wine-${WINE_VERSION}.tar.xz"
STAGING_URL="https://gitlab.winehq.org/wine/wine-staging/-/archive/v${WINE_VERSION}/wine-staging-v${WINE_VERSION}.tar.gz"

BUILD_DIR="/tmp/wine-build-ci"
SRC_DIR="$BUILD_DIR/wine-src"
BUILD_OUT="$BUILD_DIR/wine-build"
INSTALL_DIR="$BUILD_DIR/wine-install"
PREFIX="/opt/wine"
PATCHES_DIR="$SCRIPT_DIR/wine-patches"

JOBS="$(nproc)"

echo "=== Wine CI Build ==="
echo "Version:  ${WINE_VERSION}"
echo "Series:   ${WINE_SERIES}"
echo "Prefix:   ${PREFIX}"
echo "Jobs:     ${JOBS}"
echo ""

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Fetch Wine source
# ---------------------------------------------------------------------------
fetch_source() {
    echo ">>> Downloading Wine ${WINE_VERSION} from ${WINE_URL}"
    curl -L --retry 3 "$WINE_URL" | tar xJ -C "$BUILD_DIR"
    mv "$BUILD_DIR/wine-${WINE_VERSION}" "$SRC_DIR"
    echo ">>> Wine source ready: $SRC_DIR"
}

# ---------------------------------------------------------------------------
# Fetch Wine Staging
# ---------------------------------------------------------------------------
fetch_staging() {
    echo ">>> Downloading Wine Staging ${WINE_VERSION}"
    curl -L --retry 3 "$STAGING_URL" | tar xz -C "$BUILD_DIR"
    mv "$BUILD_DIR/wine-staging-v${WINE_VERSION}" "$BUILD_DIR/wine-staging"
    echo ">>> Wine staging ready"
}

# ---------------------------------------------------------------------------
# Apply staging patches
# ---------------------------------------------------------------------------
apply_staging() {
    echo ">>> Applying staging patches..."
    cd "$SRC_DIR"
    cp -r "$BUILD_DIR/wine-staging/patches" "$BUILD_DIR/wine-staging/staging" .

    chmod +w patches
    if head -1 patches/gitapply.sh 2>/dev/null | grep -qv '/usr/bin/env'; then
        sed -i '1s|.*|#!/bin/bash|' patches/gitapply.sh
    fi

    # patchinstall.py needs git repo
    if [ ! -d .git ]; then
        git init -q
        git config user.email "ci@wine-build.local"
        git config user.name "Wine CI"
        git add -A
        git commit -q -m "clean wine source"
    fi

    python3 ./staging/patchinstall.py DESTDIR="$PWD" --all
    echo ">>> Staging patches applied"
}

# ---------------------------------------------------------------------------
# Run autogen (make_requests + autoconf)
# ---------------------------------------------------------------------------
run_autogen() {
    echo ">>> Running autogen..."
    cd "$SRC_DIR"

    for f in tools/make_requests tools/make_makefiles tools/makedep; do
        if [ -f "$f" ]; then
            chmod +x "$f"
            sed -i '1s|^#!.*perl.*|#!/usr/bin/env perl|' "$f"
        fi
    done

    tools/make_requests
    autoconf
    echo ">>> Autogen done"
}

# ---------------------------------------------------------------------------
# Apply a single patch (skip if already applied)
# ---------------------------------------------------------------------------
apply_patch() {
    local patch="$PATCHES_DIR/$1"
    if [ -f "$patch" ]; then
        echo "    Applying $1..."
        if ! patch -p1 --forward --no-backup-if-mismatch -d "$SRC_DIR" < "$patch"; then
            echo "    WARNING: $1 failed to apply (may already be included)"
        fi
    else
        echo "    WARNING: $1 not found, skipping"
    fi
}

# ---------------------------------------------------------------------------
# Apply custom LoL/TFT patches
# ---------------------------------------------------------------------------
apply_custom_patches() {
    echo ">>> Applying custom patches..."
    cd "$SRC_DIR"

    # Combined patch for this specific Wine version (bundles several fixes)
    local combined="$PATCHES_DIR/wine-${WINE_VERSION}-combined.patch"
    if [ -f "$combined" ]; then
        echo "    Applying wine-${WINE_VERSION}-combined.patch..."
        if ! patch -p1 --forward --no-backup-if-mismatch < "$combined"; then
            echo "    WARNING: combined patch failed (may already be applied)"
        fi
    else
        echo "    NOTE: no combined patch found for version ${WINE_VERSION}"
    fi

    # Individual patches (--forward skips if already applied via combined patch)
    apply_patch "0001-resolve-drive-symlink.patch"
    apply_patch "LoL-client-slow-start-fix.patch"
    apply_patch "LoL-ntdll-fix-signal-set-full-context.patch"
    apply_patch "LoL-ntdll-nopguard-call_vectored_handlers.patch"
    apply_patch "0010-kernelbase-Correct-return-value-in-VirtualProtect-fo.patch"
    apply_patch "0011-kernelbase-Handle-NULL-old_prot-parameter-in-Virtual.patch"

    # VEH debug logging (applied on top of all patches)
    if [ -f "$SCRIPT_DIR/add-veh-logging.py" ]; then
        echo "    Adding VEH logging..."
        python3 "$SCRIPT_DIR/add-veh-logging.py" "$SRC_DIR/dlls/ntdll/exception.c"
    fi

    echo ">>> Custom patches applied"
}

# ---------------------------------------------------------------------------
# Configure (wow64 build)
# ---------------------------------------------------------------------------
configure_wine() {
    mkdir -p "$BUILD_OUT"
    cd "$BUILD_OUT"

    echo ">>> Configuring Wine (wow64 build)..."
    CFLAGS="-std=gnu17 -O2" \
    "$SRC_DIR/configure" \
        --enable-archs=x86_64,i386 \
        --with-wayland \
        --with-vulkan \
        --prefix="$PREFIX"
    echo ">>> Configuration complete"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build_wine() {
    cd "$BUILD_OUT"
    echo ">>> Building Wine (${JOBS} jobs)..."
    make -j"$JOBS"
    echo ">>> Build complete"
}

# ---------------------------------------------------------------------------
# Install into staging area (DESTDIR for packaging)
# ---------------------------------------------------------------------------
install_wine() {
    cd "$BUILD_OUT"
    echo ">>> Installing to $INSTALL_DIR (prefix=$PREFIX)..."
    make install DESTDIR="$INSTALL_DIR"

    # Strip debug symbols to reduce tarball size
    echo ">>> Stripping debug symbols..."
    find "$INSTALL_DIR" -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
    find "$INSTALL_DIR" -name "*.so" -exec strip --strip-unneeded {} + 2>/dev/null || true

    echo ">>> Installed. Binary at: $INSTALL_DIR/$PREFIX/bin/wine64"
}

# ---------------------------------------------------------------------------
# Bundle DXVK and VKD3D-proton DLLs into the wine install tree
# ---------------------------------------------------------------------------
bundle_dxvk() {
    local share="$INSTALL_DIR/$PREFIX/share"

    # --- DXVK ---
    echo ">>> Bundling DXVK ${DXVK_VERSION}..."
    local dxvk_url="https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VERSION}/dxvk-${DXVK_VERSION}.tar.gz"
    local dxvk_tmp="$BUILD_DIR/dxvk-${DXVK_VERSION}"

    curl -L --retry 3 "$dxvk_url" | tar xz -C "$BUILD_DIR"

    mkdir -p "$share/dxvk/x64" "$share/dxvk/x32"
    for f in d3d9.dll d3d10core.dll d3d11.dll dxgi.dll; do
        cp "$dxvk_tmp/x64/$f" "$share/dxvk/x64/"
        cp "$dxvk_tmp/x32/$f" "$share/dxvk/x32/"
    done
    rm -rf "$dxvk_tmp"
    echo ">>> DXVK ${DXVK_VERSION} bundled"

    # --- VKD3D-proton ---
    echo ">>> Bundling vkd3d-proton ${VKD3D_VERSION}..."
    local vkd3d_url="https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v${VKD3D_VERSION}/vkd3d-proton-${VKD3D_VERSION}.tar.zst"
    local vkd3d_tmp="$BUILD_DIR/vkd3d-proton-${VKD3D_VERSION}"

    curl -L --retry 3 "$vkd3d_url" | zstd -d | tar x -C "$BUILD_DIR"

    mkdir -p "$share/vkd3d-proton/x64" "$share/vkd3d-proton/x32"
    for f in d3d12.dll d3d12core.dll; do
        if [ -f "$vkd3d_tmp/x64/$f" ]; then
            cp "$vkd3d_tmp/x64/$f" "$share/vkd3d-proton/x64/"
        fi
        if [ -f "$vkd3d_tmp/x32/$f" ]; then
            cp "$vkd3d_tmp/x32/$f" "$share/vkd3d-proton/x32/"
        fi
    done
    rm -rf "$vkd3d_tmp"
    echo ">>> vkd3d-proton ${VKD3D_VERSION} bundled"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
fetch_source
fetch_staging
run_autogen
apply_staging
apply_custom_patches
configure_wine
build_wine
install_wine
bundle_dxvk

echo ""
echo "=== Build Complete ==="
echo "Output: $INSTALL_DIR/$PREFIX"
echo "Binary: $INSTALL_DIR/$PREFIX/bin/wine64"
