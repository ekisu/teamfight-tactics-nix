#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_VERSION="${WINE_VERSION:-11.19}"
WINE_TAG_COMMIT="455e3509b98a6919fd4ad1def4803e08c41c03b2"
WINE_SHA256="4820066eda68e553d330239ffc628164a348d1c623e49d058e011c5a7cda95f1"
DXVK_VERSION="${DXVK_VERSION:-2.7.1}"
DXVK_SHA256="d85ce7c79f57ecd765aaa1b9e7007cb875e6fde9f6d331df799bce73d513ce87"
VKD3D_VERSION="${VKD3D_VERSION:-3.0.1}"
VKD3D_SHA256="3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c"

WINE_SERIES="11.x"
WINE_URL="https://dl.winehq.org/wine/source/${WINE_SERIES}/wine-${WINE_VERSION}.tar.xz"

if [ "$WINE_VERSION" != "11.19" ] || [ "$DXVK_VERSION" != "2.7.1" ] || [ "$VKD3D_VERSION" != "3.0.1" ]; then
    echo "ERROR: this recipe pins Wine 11.19, DXVK 2.7.1, and VKD3D-Proton 3.0.1" >&2
    exit 2
fi

ulimit -c 0

BUILD_DIR="/tmp/wine-build-ci"
SRC_DIR="$BUILD_DIR/wine-src"
BUILD_OUT="$BUILD_DIR/wine-build"
INSTALL_DIR="$BUILD_DIR/wine-install"
PREFIX="/opt/wine"
PATCHES_DIR="$SCRIPT_DIR/wine-patches"

JOBS="$(nproc)"

if [ -d /usr/lib/ccache ]; then
    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
    export PATH="/usr/lib/ccache:$PATH"
    ccache -z
    echo "ccache: enabled (dir=$CCACHE_DIR)"
else
    echo "ccache: not available, skipping"
fi

echo "=== Wine CI Build ==="
echo "Version:  ${WINE_VERSION}"
echo "Series:   ${WINE_SERIES}"
echo "Prefix:   ${PREFIX}"
echo "Jobs:     ${JOBS}"
echo ""

for directory in "$SRC_DIR" "$BUILD_OUT" "$INSTALL_DIR"; do
    [ ! -e "$directory" ] || { echo "ERROR: nonfresh build tree: $directory" >&2; exit 2; }
done
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Fetch Wine source
# ---------------------------------------------------------------------------
fetch_source() {
    local archive="$BUILD_DIR/wine-${WINE_VERSION}.tar.xz"
    echo ">>> Downloading Wine ${WINE_VERSION} from ${WINE_URL}"
    curl -fL --retry 3 -o "$archive" "$WINE_URL"
    echo "$WINE_SHA256  $archive" | sha256sum --check --status
    tar xJf "$archive" -C "$BUILD_DIR"
    mv "$BUILD_DIR/wine-${WINE_VERSION}" "$SRC_DIR"
    [ "$(cat "$SRC_DIR/VERSION")" = "Wine version ${WINE_VERSION}" ]
    echo ">>> Wine source ready: $SRC_DIR"
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
# Apply the exact Wine 11.19 compatibility patch manifest
# ---------------------------------------------------------------------------
apply_custom_patches() {
    local patches=(
        "0003-kernel32-implement-settimerqueuetimer.patch"
        "0004-ntdll-match-native-x64-dispatcher-layout.patch"
        "0005-dbgcore-forward-minidump-exports.patch"
    )
    local expected_hashes=(
        "eac0d5c97b6bb7e5c4be63d9235b82285af55f94012332543b9ce35602c165d0"
        "3fb7a7da54877dfc9269d6414e0da719701828a69101195847e33e8b881b7442"
        "5a6b3794afe06006dcc4fbc9a44269f2d358c1166af13e4be84ac7cb44a4773c"
    )

    echo ">>> Applying accepted Wine 11.19 API compatibility patches (no Staging)..."
    for i in "${!patches[@]}"; do
        local patch="$PATCHES_DIR/${patches[$i]}"
        [ -f "$patch" ] || { echo "ERROR: missing patch ${patches[$i]}" >&2; exit 1; }
        echo "${expected_hashes[$i]}  $patch" | sha256sum --check --status || {
            echo "ERROR: checksum mismatch for ${patches[$i]}" >&2
            exit 1
        }
        echo "    Applying ${patches[$i]}"
        patch -d "$SRC_DIR" -p1 --fuzz=0 --forward --batch < "$patch"
    done

    if find "$SRC_DIR" -name '*.rej' -print -quit | grep -q .; then
        echo "ERROR: rejected custom patch hunks found" >&2
        exit 1
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
    CFLAGS="-std=gnu17 -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0" \
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

    # Preserve PE/API and upstream graphics DLL bytes; strip native ELF only.
    echo ">>> Stripping debug symbols..."
    while IFS= read -r -d '' file; do
        if readelf --file-header "$file" >/dev/null 2>&1; then
            strip --strip-unneeded "$file"
        fi
    done < <(find "$INSTALL_DIR" -type f -print0)

    echo ">>> Installed. Binary at: $INSTALL_DIR/$PREFIX/bin/wine"
}

# ---------------------------------------------------------------------------
# Bundle DXVK and VKD3D-proton DLLs into the wine install tree
# ---------------------------------------------------------------------------
bundle_dxvk() {
    local share="$INSTALL_DIR/$PREFIX/share"

    # --- DXVK ---
    echo ">>> Bundling DXVK ${DXVK_VERSION}..."
    local dxvk_url="https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VERSION}/dxvk-${DXVK_VERSION}.tar.gz"
    local dxvk_archive="$BUILD_DIR/dxvk-${DXVK_VERSION}.tar.gz"
    local dxvk_tmp="$BUILD_DIR/dxvk-${DXVK_VERSION}"

    curl -fL --retry 3 -o "$dxvk_archive" "$dxvk_url"
    echo "$DXVK_SHA256  $dxvk_archive" | sha256sum --check --status
    tar xzf "$dxvk_archive" -C "$BUILD_DIR"

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
    local vkd3d_archive="$BUILD_DIR/vkd3d-proton-${VKD3D_VERSION}.tar.zst"
    local vkd3d_tmp="$BUILD_DIR/vkd3d-proton-${VKD3D_VERSION}"

    curl -fL --retry 3 -o "$vkd3d_archive" "$vkd3d_url"
    echo "$VKD3D_SHA256  $vkd3d_archive" | sha256sum --check --status
    tar --zstd -xf "$vkd3d_archive" -C "$BUILD_DIR"

    mkdir -p "$share/vkd3d-proton/x64"
    for f in d3d12.dll d3d12core.dll; do
        [ -f "$vkd3d_tmp/x64/$f" ]
        cp "$vkd3d_tmp/x64/$f" "$share/vkd3d-proton/x64/"
    done
    rm -rf "$vkd3d_tmp"
    echo ">>> vkd3d-proton ${VKD3D_VERSION} bundled"
}

# ---------------------------------------------------------------------------
# Validate and record the accepted build topology and provenance
# ---------------------------------------------------------------------------
validate_and_manifest() {
    local runtime="$INSTALL_DIR/$PREFIX"

    [ -x "$runtime/bin/wine" ]
    [ -x "$runtime/bin/wineserver" ]
    readelf --file-header "$runtime/bin/wine" | grep -Eq 'Class:.*ELF64'
    [ -f "$runtime/lib/wine/x86_64-unix/ntdll.so" ]
    [ -f "$runtime/lib/wine/x86_64-windows/ntdll.dll" ]
    [ -f "$runtime/lib/wine/i386-windows/ntdll.dll" ]
    [ ! -e "$runtime/lib/wine/i386-unix" ]

    [ -f "$runtime/lib/wine/x86_64-windows/dbgcore.dll" ]
    [ -f "$runtime/lib/wine/i386-windows/dbgcore.dll" ]
    [ "$(find "$runtime/share/dxvk" "$runtime/share/vkd3d-proton" -type f -name '*.dll' | wc -l)" -eq 10 ]
    (cd "$runtime"; find share/dxvk share/vkd3d-proton -type f -name '*.dll' -print0 | sort -z | xargs -0 sha256sum) > "$runtime/graphics-dlls.sha256"
    cp "$SCRIPT_DIR/wine-build-manifest.json" "$runtime/source-recipe.json"

    cat > "$runtime/build-manifest.txt" <<EOF
candidate=wine-11.19-upstream-native-api-fortify-disabled
wine_version=$WINE_VERSION
wine_corresponding_tag_commit=$WINE_TAG_COMMIT
wine_source_sha256=$WINE_SHA256
staging=false
staging_patchsets=0
custom_patches=0003-kernel32-implement-settimerqueuetimer.patch 0004-ntdll-match-native-x64-dispatcher-layout.patch 0005-dbgcore-forward-minidump-exports.patch
custom_patch_0003_sha256=eac0d5c97b6bb7e5c4be63d9235b82285af55f94012332543b9ce35602c165d0
custom_patch_0004_sha256=3fb7a7da54877dfc9269d6414e0da719701828a69101195847e33e8b881b7442
custom_patch_0005_sha256=5a6b3794afe06006dcc4fbc9a44269f2d358c1166af13e4be84ac7cb44a4773c
fortify=disabled-local-reproduction-profile-not-memory-safety-proof
forced_shared=false
custom_pkru_patch=false
custom_diagnostic_traces=false
nix_definition_pin=c59305bab2065cfecc4944690d9eedbb56f3a9fa
ci_builder_libc=$(getconf GNU_LIBC_VERSION)
ci_compiler_version=$(gcc -dumpfullversion)
abi_acceptance=separate-from-the-locally-tested-Mesa-26.2.3-glibc-2.44-host
build_topology=unified new WoW64 (x86_64,i386)
dxvk_version=$DXVK_VERSION
dxvk_archive_sha256=$DXVK_SHA256
vkd3d_proton_version=$VKD3D_VERSION
vkd3d_archive_sha256=$VKD3D_SHA256
wine_binary_sha256=$(sha256sum "$runtime/bin/wine" | cut -d' ' -f1)
wineserver_binary_sha256=$(sha256sum "$runtime/bin/wineserver" | cut -d' ' -f1)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
fetch_source
apply_custom_patches
run_autogen
configure_wine
build_wine
install_wine
bundle_dxvk
validate_and_manifest
bash "$SCRIPT_DIR/tests/test-dispatcher.sh" "$INSTALL_DIR/$PREFIX" "$BUILD_DIR/dispatcher-tests"
bash "$SCRIPT_DIR/tests/test-timer-queue.sh" "$INSTALL_DIR/$PREFIX" "$BUILD_DIR/timer-queue-tests"

if command -v ccache &>/dev/null; then
    echo ""
    ccache -s
fi

echo ""
echo "=== Build Complete ==="
echo "Output: $INSTALL_DIR/$PREFIX"
echo "Binary: $INSTALL_DIR/$PREFIX/bin/wine"
