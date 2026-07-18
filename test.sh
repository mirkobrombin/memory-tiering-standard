#!/usr/bin/env sh
set -eu
ZIG="${ZIG:-zig}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache/global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache/local}"
"$ZIG" fmt --check src tests
"$ZIG" test src/config.zig
"$ZIG" test src/iso16.zig
"$ZIG" test src/feasibility.zig
"$ZIG" test tests/uapi_layout.zig
