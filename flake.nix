{
  description = "A flake containing packages needed to run Teamfight Tactics by Riot Games";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    # Nixpkgs with Wine 9.16
    # Wine 9.16 is required because the game won't even start on Wine 9.17+. my best guess is that
    # something related to exception handling hooks broke in Wine 9.16, most likely KiUserExceptionDispatcher:
    # https://www.unknowncheats.me/forum/league-of-legends/620637-packman-stub-dll-hooks-ntdll-dll-v14-1-a.html
    nixpkgs.url = "github:NixOS/nixpkgs?ref=448c32f75aaee222908abd3a8ec84172b3f040bf";
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
        packages.wine = (wineWowPackages.staging.overrideAttrs (oldAttrs: {
          patches = oldAttrs.patches ++ [
            # those are patches specific to league
            # ./wine-patches/LoL-broken-client-update-fix.patch
            ./wine-patches/0001-resolve-drive-symlink.patch
            # ./wine-patches/0001-GetMappedFileName-Return-nt-filename-and-resolve-DOS.patch
            ./wine-patches/LoL-client-slow-start-fix.patch
            ./wine-patches/LoL-ntdll-fix-signal-set-full-context.patch
            ./wine-patches/ntdll-implement-ntcontinueex-wine-9.16.patch
            ./wine-patches/LoL-ntdll-nopguard-call_vectored_handlers.patch
            # those two fix an error while creating a X11 window with client windows. not sure if they're needed?
            ./wine-patches/6398.patch
            ./wine-patches/6467.patch
            # those fix a regression in Wine 9.16-9.17 which makes CEF applications not work correctly.
            ./wine-patches/ntdll-WRITECOPY/0010-kernelbase-Correct-return-value-in-VirtualProtect-fo.patch
            ./wine-patches/ntdll-WRITECOPY/0011-kernelbase-Handle-NULL-old_prot-parameter-in-Virtual.patch
          ];
        }));
    });
}
