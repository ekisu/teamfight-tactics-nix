#!/usr/bin/env bash
# Owned offline fixtures only. Never use an existing game/account prefix.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
runtime="$(realpath "${1:?usage: test-dispatcher.sh RUNTIME NEW_SCRATCH}")"
scratch="${2:?usage: test-dispatcher.sh RUNTIME NEW_SCRATCH}"
ulimit -c 0
mkdir -m 700 "$scratch"
scratch="$(realpath "$scratch")"

x86_64-w64-mingw32-gcc -std=gnu17 -O2 -fno-strict-aliasing -Wall -Wextra -static-libgcc \
    -o "$scratch/dispatcher-x64.exe" "$script_dir/dispatcher-regression-x64.c" "$script_dir/dispatcher-regression-x64.S"
i686-w64-mingw32-gcc -std=gnu17 -O2 -fno-strict-aliasing -Wall -Wextra -static-libgcc \
    -o "$scratch/dispatcher-x86.exe" "$script_dir/dispatcher-regression-x86.c" "$script_dir/dispatcher-regression-x86.S"
x86_64-w64-mingw32-gcc -std=gnu17 -O2 -Wall -Wextra -static-libgcc \
    -o "$scratch/dispatcher-layout.exe" "$script_dir/dispatcher-layout.c"

python3 "$script_dir/run-owned-wine-tests.py" "$runtime" "$scratch" \
    "$scratch/dispatcher-x64.exe" "$scratch/dispatcher-x86.exe" "$scratch/dispatcher-layout.exe"
