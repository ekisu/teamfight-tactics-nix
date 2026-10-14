#!/usr/bin/env bash
# Opt-in, offline test. On NixOS invoke the Windows executables inside steam-run.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
runtime=$(realpath "${1:?usage: test-timer-queue.sh RUNTIME NEW_SCRATCH_DIRECTORY}")
scratch=${2:?usage: test-timer-queue.sh RUNTIME NEW_SCRATCH_DIRECTORY}
ulimit -c 0
mkdir -m 700 "$scratch"
scratch=$(realpath "$scratch")

x86_64-w64-mingw32-gcc -std=gnu17 -Wall -Wextra -Werror -static -o "$scratch/timer-queue-x64.exe" "$script_dir/timer_queue.c"
i686-w64-mingw32-gcc -std=gnu17 -Wall -Wextra -Werror -static -o "$scratch/timer-queue-x86.exe" "$script_dir/timer_queue.c"

python3 "$script_dir/run-owned-wine-tests.py" "$runtime" "$scratch" \
    "$scratch/timer-queue-x64.exe" "$scratch/timer-queue-x86.exe"
