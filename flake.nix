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
      in with pkgs; {
        packages.wine = (wineWow64Packages.full.overrideAttrs (oldAttrs: {
          version = "11.4";
          src = fetchurl {
            url = "https://dl.winehq.org/wine/source/11.x/wine-11.4.tar.xz";
            hash = "sha256-GXCkY4HTvCxE1lHQgzY3Dkme64tT3JPL0c5UT3EV5Zg=";
          };
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [ autoreconfHook ];
          patches = [
            ./wine-patches/wine-11.4-combined.patch
            ./wine-patches/0001-resolve-drive-symlink.patch
            ./wine-patches/0010-kernelbase-Correct-return-value-in-VirtualProtect-fo.patch
            ./wine-patches/0011-kernelbase-Handle-NULL-old_prot-parameter-in-Virtual.patch
            ./wine-patches/LoL-client-slow-start-fix.patch
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
            echo "Run './build-wine.sh' to build Wine 11.4 with patches"
            echo "Run './test-wine.sh' to test with LoL replay"
          '';
        };
    });
}
