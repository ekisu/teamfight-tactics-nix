{
  description = "A flake containing packages needed to run Teamfight Tactics by Riot Games";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/c59305bab2065cfecc4944690d9eedbb56f3a9fa";
  };

  outputs = { self, flake-utils, nixpkgs }:
    let
      availableSystems = ["x86_64-linux"];
    in flake-utils.lib.eachSystem availableSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        manifest = builtins.fromJSON (builtins.readFile ./wine-build-manifest.json);
        customPatches = map (patch: {
          path = ./wine-patches + "/${patch.file}";
          inherit (patch) sha256;
        }) manifest.patches;
        dxvk = pkgs.fetchurl {
          url = "https://github.com/doitsujin/dxvk/releases/download/v${manifest.graphics.dxvk_version}/dxvk-${manifest.graphics.dxvk_version}.tar.gz";
          sha256 = manifest.graphics.dxvk_sha256;
        };
        vkd3d = pkgs.fetchurl {
          url = "https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v${manifest.graphics.vkd3d_proton_version}/vkd3d-proton-${manifest.graphics.vkd3d_proton_version}.tar.zst";
          sha256 = manifest.graphics.vkd3d_proton_sha256;
        };
      in with pkgs; {
        packages.wine = assert builtins.all (patch:
          builtins.hashFile "sha256" patch.path == patch.sha256) customPatches;
          ((wineWow64Packages.full.override { wineRelease = "unstable"; }).overrideAttrs (oldAttrs: {
          version = manifest.wine.version;
          meta = (oldAttrs.meta or {}) // { version = manifest.wine.version; };
          src = fetchurl {
            url = manifest.wine.url;
            hash = manifest.wine.sri;
          };
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
            autoreconfHook perl python3 zstd
          ];
          prePatch = ''
            patchShebangs tools
          '';
          patches = map (patch: patch.path) customPatches;
          patchFlags = [ "-p1" "--fuzz=0" "--forward" "--batch" ];
          # Match the accepted local profile; this is not a PKRU/bounds proof.
          hardeningDisable = lib.unique ((oldAttrs.hardeningDisable or []) ++ [ "fortify" ]);
          env = (oldAttrs.env or {}) // {
            CFLAGS = manifest.build_profile.cflags;
          };
          preConfigure = (oldAttrs.preConfigure or "") + ''
            patchShebangs tools
            tools/make_requests
            autoreconf -f
          '';
          postInstall = (oldAttrs.postInstall or "") + ''
            mkdir -p "$TMPDIR/tft-bundles/dxvk" "$TMPDIR/tft-bundles/vkd3d"
            tar -xzf ${dxvk} -C "$TMPDIR/tft-bundles/dxvk"
            tar --zstd -xf ${vkd3d} -C "$TMPDIR/tft-bundles/vkd3d"
            for arch in x64 x32; do
              mkdir -p "$out/share/dxvk/$arch"
              for dll in d3d9.dll d3d10core.dll d3d11.dll dxgi.dll; do
                install -m644 "$TMPDIR/tft-bundles/dxvk/dxvk-${manifest.graphics.dxvk_version}/$arch/$dll" "$out/share/dxvk/$arch/"
              done
            done
            mkdir -p "$out/share/vkd3d-proton/x64"
            for dll in d3d12.dll d3d12core.dll; do
              install -m644 "$TMPDIR/tft-bundles/vkd3d/vkd3d-proton-${manifest.graphics.vkd3d_proton_version}/x64/$dll" "$out/share/vkd3d-proton/x64/"
            done
            test "$(find "$out/share/dxvk" "$out/share/vkd3d-proton" -type f -name '*.dll' | wc -l)" -eq 10
            (cd "$out"; find share/dxvk share/vkd3d-proton -type f -name '*.dll' -print0 | sort -z | xargs -0 sha256sum) > "$out/graphics-dlls.sha256"
            test -f "$out/lib/wine/x86_64-windows/ntdll.dll"
            test -f "$out/lib/wine/i386-windows/ntdll.dll"
            test -f "$out/lib/wine/x86_64-windows/dbgcore.dll"
            test -f "$out/lib/wine/i386-windows/dbgcore.dll"
            test ! -e "$out/lib/wine/i386-unix"
            cp ${./wine-build-manifest.json} "$out/source-recipe.json"
          '';
        }));

        devShells.default = mkShell {
          nativeBuildInputs = [
            bison flex fontforge pkg-config autoconf hexdump perl python3 gitMinimal gettext
            xvfb
            pkgsCross.mingw32.buildPackages.gcc
            pkgsCross.mingwW64.buildPackages.gcc
          ];

          buildInputs = [
            freetype perl libunwind libcap
            cups dbus cairo ncurses sane-backends libpulseaudio udev
            libxinerama vulkan-loader SDL2 libusb1 ffmpeg-headless
            openssl gnutls
            libGLU libGL libdrm
            alsa-lib
            fontconfig
            libx11 libxcomposite libxcursor libxext libxfixes libxi libxrandr libxrender libxxf86vm
            wayland wayland-scanner libxkbcommon wayland-protocols libgbm
          ];

          hardeningDisable = [ "bindnow" "stackclashprotection" "format" "fortify" ];

          NIX_LDFLAGS = builtins.toString ([
            "-rpath ${lib.makeLibraryPath ([
              stdenv.cc.cc freetype perl libunwind libcap
              cups dbus cairo ncurses sane-backends libpulseaudio udev
              libxinerama vulkan-loader SDL2 libusb1 ffmpeg-headless
              openssl gnutls libGLU libGL libdrm alsa-lib fontconfig
              libx11 libxcomposite libxcursor libxext libxfixes libxi libxrandr libxrender libxxf86vm
              wayland libxkbcommon libgbm
            ] ++ [ stdenv.cc.cc.lib ])}"
          ]);

          shellHook = ''
            export WINE_SRC=$(pwd)/build/wine-src
            export WINE_BUILD=$(pwd)/build/wine-build
            export WINE_PREFIX=$(pwd)/build/wine-install
            echo "=== Wine Development Environment ==="
            echo "Pinned package: Wine 11.19 upstream with three native API patches"
            echo "Run './test-wine.sh' to test with LoL replay"
          '';
        };
    });
}
