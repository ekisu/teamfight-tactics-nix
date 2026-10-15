# teamfight-tactics-nix

Reproducible Wine builds for Teamfight Tactics on Linux.

The build is based on upstream Wine **11.19**, without Staging, with unified
new WoW64. Its exact source/patch/graphics hashes are in
`wine-build-manifest.json`. It carries three genuine API compatibility fixes:

- implement the legacy `kernel32.SetTimerQueueTimer` export using Wine's
  existing timer queues (including `PreferIo` callback scheduling);
- match the native x64 exception-dispatcher argument setup and CALL-at-0x29
  layout without replacing dispatch behavior;
- provide `dbgcore`'s two public MiniDump exports as forwards to real `dbghelp`
  implementations.

Both the local 11.19 build and the clean **Nix package** reached current-client
**Home** using the user's genuine Spatula browser session and client-config proxy,
observed at 120 and 180 seconds (60-second hold). The host used default
Mesa 26.2.3/glibc 2.44, without driver/capability overrides. The exact Ubuntu CI
archive also passed this authenticated Home check before publication as
**[wine-11.19-r1](https://github.com/ekisu/teamfight-tactics-nix/releases/tag/wine-11.19-r1)**.
Provenance and results are in `tests/acceptance/wine-11.19-nix.json` and
`tests/acceptance/wine-11.19-ci.json`.
Offline x64/x86 timer, exception/continuation, and `dbgcore` export tests pass
on that package. This is launch acceptance, not match gameplay or universal
host compatibility; another artifact still requires its own validation.

Build the package from the Git checkout (without copying ignored investigation
trees into the Nix store):

```sh
nix build .#wine
```

The Nix pin matches that host libc ABI; universal host-driver compatibility is
not claimed. FORTIFY is explicitly disabled to match the accepted local build.
This does not prove complete PKRU preservation or xstate-copy memory safety.
Legacy forced-Shared/PKRU patch files are preserved but are not activated.
No investigation-only loader, exception-trace, or startup-pause patches are used.

The package also bundles DXVK 2.7.1 and VKD3D-Proton 3.0.1.
`.github/workflows/release.yml` builds **workflow artifacts only**, with SHA-256
checksums and an explicitly supplied revision (`wine-11.19-rN`). Publication is
a separate promotion of the **exact accepted tarball**, not a rebuild. The
published `wine-11.19-r1` retains the original validated CI bytes and checksum;
its tag identifies the actual build commit. Future publication also requires
artifact acceptance, bound provenance and a new unused identity. Do not
overwrite releases. Spatula's normal verified updater receives published
runtimes through GitHub's `releases/latest`, not workflow artifacts.

Existing Spatula versions reject a different installed Wine instead of upgrading
it in place. While Spatula and that prefix are not running, preserve the entire
old `wine` directory (runtime, prefix and state) as a backup. The next normal
Run downloads the new release and creates a fresh matching prefix. Keep the
native `auth-profile`, account presentation, client state and TFT install in
place; do not clear sign-in data or run another Wine over the old prefix.

The exact graphics bundle is eight DXVK DLLs (x64/x32) and two x64 VKD3D DLLs.
Bundling does not alter existing prefixes. As in Spatula, a launcher installs
the x64 DLLs into `system32`, x32 DXVK into `syswow64`, selects native
`d3d9,d3d10core,d3d11,dxgi,d3d12,d3d12core`, and uses per-prefix shader caches.
The CI artifact build runs `tests/test-dispatcher.sh` and `tests/test-timer-queue.sh`
against owned offline fixtures and both PE architectures.
The same offline tests can be run locally with Python, Xvfb, and both MinGW
compilers on `PATH`:

```sh
bash tests/test-dispatcher.sh /absolute/path/to/wine /absolute/path/to/new-dispatcher-scratch
bash tests/test-timer-queue.sh /absolute/path/to/wine /absolute/path/to/new-timer-scratch
```

Each creates its own prefix and Xvfb display, runs owned offline fixtures, and
stops only that prefix's wineserver and its own display. Cleanup failures fail
acceptance. Never point them at an existing game prefix.

CI's Ubuntu-built artifact and the Nix-store package are distinct artifacts;
host graphics/auth acceptance and Nix closure/relocation requirements must not
be inferred from a headless CI pass.

## Historical startup investigation (not production)

An earlier Wine 11.19 Staging investigation used the ignored
`build-startup-1119/{src,out,install}` tree. Public source revisions and archive
hashes are recorded in that tree's `source-identity.txt`. It is an experimental
runtime, not the release artifact: it also contains diagnostic-only tracing and
a candidate `dbgcore.dll` forwarding its real minidump APIs to `dbghelp`.

These older diagnostic trees are not the production source recipe or a build
instruction. For any local Nix evaluation, use a tiny, explicitly allowlisted
public source/toolchain snapshot; never snapshot the whole checkout with a
`path:` flake, since ignored runtime/client trees may be present. Preserve
existing object trees, avoid concurrent builds in one tree, and use only fresh
owned prefixes. The separate local upstream/host-ABI runtime has the Home
acceptance described above.
