{
  description = "A flake containing packages needed to run Teamfight Tactics by Riot Games";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs?ref=15f4ee454b1dce334612fa6843b3e05cf546efab";
  };

  outputs = { self, flake-utils, nixpkgs }:
    let
      availableSystems = ["x86_64-linux"];
    in flake-utils.lib.eachSystem availableSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        wineStaging = pkgs.fetchzip {
          url = "https://gitlab.winehq.org/wine/wine-staging/-/archive/634865f9e409c7101adc6809f23af34d2a668525/wine-staging-634865f9e409c7101adc6809f23af34d2a668525.tar.gz";
          hash = "sha256-/mu7seIsrkXzfJjIzyrMavBT6ZC8Gz/6PZPm9TjjekE=";
        };
      in with pkgs; {
        packages.wine = (wineWow64Packages.full.overrideAttrs (oldAttrs: {
          version = "11.15";
          src = fetchurl {
            url = "https://dl.winehq.org/wine/source/11.x/wine-11.15.tar.xz";
            hash = "sha256-UEbzba4hCxmOppeSd01EAf7tl11GXspsJRyTlEAOwnI=";
          };
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [
            autoreconfHook gitMinimal python3
          ];
          prePatch = ''
            patchShebangs tools
            git init -q
            git config user.email "nix-build@localhost"
            git config user.name "Nix Wine build"
            git add -A
            git commit -q -m "Wine 11.15 pristine source"
            wine_source="$PWD"
            (cd ${wineStaging} &&
              ${python3}/bin/python3 ./staging/patchinstall.py --all DESTDIR="$wine_source")
            if find . -name '*.rej' -print -quit | grep -q .; then
              echo "rejected Wine Staging hunks found" >&2
              exit 1
            fi
          '';
          patches = [
            ./wine-patches/0001-ntdll-report-writecopy-image-pages-shared.patch
            ./wine-patches/0002-ntdll-account-for-pkru-xstate.patch
          ];
          preConfigure = (oldAttrs.preConfigure or "") + ''
            patchShebangs tools
            autoreconf -f
          '';
        }));

        devShells.default = mkShell {
          nativeBuildInputs = [
            bison flex fontforge pkg-config autoconf hexdump perl python3 gitMinimal gettext
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

          hardeningDisable = [ "bindnow" "stackclashprotection" "format" ];

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
            echo "Run './build-wine.sh' to build Wine 11.15 with patches"
            echo "Run './test-wine.sh' to test with LoL replay"
          '';
        };
    });
}
