# teamfight-tactics-nix

Reproducible Wine builds for Teamfight Tactics on Linux.

The current release is based on Wine 11.15 Staging with unified new WoW64.
It carries the two focused compatibility fixes found by the TFT investigation:

- report WRITECOPY image pages as shared through Linux `QueryWorkingSetEx`;
- include host PKRU state when Wine sizes xstate buffers.

GitHub releases also bundle DXVK 2.7.1 and VKD3D-Proton 3.0.1. Release assets
are built by `.github/workflows/release.yml` and include a SHA-256 checksum.
