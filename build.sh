#!/usr/bin/env sh
# The compiler is pinned because Zig is pre-1.0 and its build API is not stable.
set -eu
ZIG="${ZIG:-zig}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache/global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache/local}"
version="$($ZIG version)"
case "$version" in
  0.16.*) ;;
  *) echo "ERROR: Zig 0.16.x required, got $version" >&2; exit 1 ;;
esac
mkdir -p zig-out/bin
"$ZIG" build-exe src/mtsctl.zig -O ReleaseSafe -femit-bin=zig-out/bin/mtsctl
"$ZIG" build-exe src/mtsd.zig -O ReleaseSafe -femit-bin=zig-out/bin/mtsd
"$ZIG" build-exe src/mts-generator.zig -O ReleaseSafe -femit-bin=zig-out/bin/mts-generator
"$ZIG" build-exe src/mts-eval.zig -O ReleaseSafe -femit-bin=zig-out/bin/mts-eval
