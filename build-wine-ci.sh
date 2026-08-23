#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINE_VERSION="${WINE_VERSION:-11.15}"
WINE_TAG_COMMIT="2df1ee28039cf84776eb1421ed90bd154cebb65f"
WINE_SHA256="5046f36dae210b198ea69792774d4401feed975d465eca6c251c9394400ec272"
STAGING_TAG_COMMIT="634865f9e409c7101adc6809f23af34d2a668525"
STAGING_REPOSITORY="https://gitlab.winehq.org/wine/wine-staging.git"
DXVK_VERSION="${DXVK_VERSION:-2.7.1}"
DXVK_SHA256="d85ce7c79f57ecd765aaa1b9e7007cb875e6fde9f6d331df799bce73d513ce87"
VKD3D_VERSION="${VKD3D_VERSION:-3.0.1}"
VKD3D_SHA256="3cf2315522af5e43605ef6d3c41dad91387040bf97199934f3f7ab76caaa2f0c"

WINE_SERIES="11.x"
WINE_URL="https://dl.winehq.org/wine/source/${WINE_SERIES}/wine-${WINE_VERSION}.tar.xz"

if [ "$WINE_VERSION" != "11.15" ]; then
    echo "ERROR: this build definition and its patches are pinned to Wine 11.15" >&2
    exit 2
fi

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
# Fetch the exact accepted Wine Staging revision
# ---------------------------------------------------------------------------
fetch_staging() {
    echo ">>> Fetching Wine Staging ${WINE_VERSION} (${STAGING_TAG_COMMIT})"
    git clone --quiet --no-checkout "$STAGING_REPOSITORY" "$BUILD_DIR/wine-staging"
    git -C "$BUILD_DIR/wine-staging" checkout --quiet "$STAGING_TAG_COMMIT"
    [ "$(git -C "$BUILD_DIR/wine-staging" rev-parse HEAD)" = "$STAGING_TAG_COMMIT" ]
    [ "$(git -C "$BUILD_DIR/wine-staging" describe --tags --exact-match HEAD)" = "v${WINE_VERSION}" ]
    echo ">>> Wine staging ready"
}

# ---------------------------------------------------------------------------
# Apply staging patches
# ---------------------------------------------------------------------------
apply_staging() {
    echo ">>> Applying all Wine Staging ${WINE_VERSION} patches..."

    # patchinstall.py requires its destination to be a git work tree.
    git -C "$SRC_DIR" init -q
    git -C "$SRC_DIR" config user.email "ci@wine-build.local"
    git -C "$SRC_DIR" config user.name "Wine CI"
    git -C "$SRC_DIR" add -A
    git -C "$SRC_DIR" commit -q -m "Wine ${WINE_VERSION} pristine source"

    (
        cd "$BUILD_DIR/wine-staging"
        python3 ./staging/patchinstall.py --all DESTDIR="$SRC_DIR"
    )

    if find "$SRC_DIR" -name '*.rej' -print -quit | grep -q .; then
        echo "ERROR: rejected Wine Staging hunks found" >&2
        exit 1
    fi
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
# Apply the exact Wine 11.15 compatibility patch manifest
# ---------------------------------------------------------------------------
apply_custom_patches() {
    local patches=(
        "0001-ntdll-report-writecopy-image-pages-shared.patch"
        "0002-ntdll-account-for-pkru-xstate.patch"
    )
    local expected_hashes=(
        "81231df4147caad763bfd255e40cd4b68f0b96992d774ead20588dc3582a45c8"
        "577fefa399b0c1fa8808ddf8c918f1d217595796bdfb3374055760382cd6a523"
    )

    echo ">>> Applying accepted Wine 11.15 TFT compatibility patches..."
    for i in "${!patches[@]}"; do
        local patch="$PATCHES_DIR/${patches[$i]}"
        [ -f "$patch" ] || { echo "ERROR: missing patch ${patches[$i]}" >&2; exit 1; }
        echo "${expected_hashes[$i]}  $patch" | sha256sum --check --status || {
            echo "ERROR: checksum mismatch for ${patches[$i]}" >&2
            exit 1
        }
        echo "    Applying ${patches[$i]}"
        patch -d "$SRC_DIR" -p1 --forward --batch < "$patch"
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
# Validate and record the accepted build topology and provenance
# ---------------------------------------------------------------------------
validate_and_manifest() {
    local runtime="$INSTALL_DIR/$PREFIX"
    local patchsets="$BUILD_DIR/staging-patchsets.txt"

    [ -x "$runtime/bin/wine" ]
    [ -x "$runtime/bin/wineserver" ]
    readelf --file-header "$runtime/bin/wine" | grep -Eq 'Class:.*ELF64'
    [ -f "$runtime/lib/wine/x86_64-unix/ntdll.so" ]
    [ -f "$runtime/lib/wine/x86_64-windows/ntdll.dll" ]
    [ -f "$runtime/lib/wine/i386-windows/ntdll.dll" ]
    [ ! -e "$runtime/lib/wine/i386-unix" ]

    for patchset in "$BUILD_DIR/wine-staging"/patches/*; do
        [ -d "$patchset" ] || continue
        if [ -f "$patchset/definition" ] && grep -qi '^disabled: true$' "$patchset/definition"; then
            continue
        fi
        basename "$patchset"
    done | sort > "$patchsets"
    [ "$(wc -l < "$patchsets")" -eq 97 ]
    cp "$patchsets" "$runtime/staging-patchsets.txt"

    cat > "$runtime/build-manifest.txt" <<EOF
candidate=ubuntu-11.15-staging-working-set-pkru
wine_version=$WINE_VERSION
wine_corresponding_tag_commit=$WINE_TAG_COMMIT
wine_source_sha256=$WINE_SHA256
staging_tag_commit=$STAGING_TAG_COMMIT
staging_patchsets=97 enabled patchsets
custom_patches=0001-ntdll-report-writecopy-image-pages-shared.patch 0002-ntdll-account-for-pkru-xstate.patch
custom_patch_0001_sha256=81231df4147caad763bfd255e40cd4b68f0b96992d774ead20588dc3582a45c8
custom_patch_0002_sha256=577fefa399b0c1fa8808ddf8c918f1d217595796bdfb3374055760382cd6a523
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
fetch_staging
apply_staging
apply_custom_patches
run_autogen
configure_wine
build_wine
install_wine
bundle_dxvk
validate_and_manifest

if command -v ccache &>/dev/null; then
    echo ""
    ccache -s
fi

echo ""
echo "=== Build Complete ==="
echo "Output: $INSTALL_DIR/$PREFIX"
echo "Binary: $INSTALL_DIR/$PREFIX/bin/wine64"
