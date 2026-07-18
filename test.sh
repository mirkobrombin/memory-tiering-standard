#!/usr/bin/env sh
set -eu
ZIG="${ZIG:-zig}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache/global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache/local}"
"$ZIG" fmt --check src tests
"$ZIG" test src/config.zig
"$ZIG" test src/iso16.zig
"$ZIG" test src/feasibility.zig
"$ZIG" test src/statistics.zig
"$ZIG" test src/eval_result.zig
"$ZIG" test src/eval_identity.zig
"$ZIG" test src/mrc.zig
"$ZIG" test src/object_table.zig
"$ZIG" test src/pd1.zig
"$ZIG" test src/telemetry.zig
"$ZIG" test src/engine.zig
"$ZIG" test src/linux_uapi.zig
"$ZIG" test src/workload.zig
"$ZIG" test tests/uapi_layout.zig
mkdir -p .zig-cache/test-bin
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -Iinclude/uapi \
  tests/uapi_abi.c -o .zig-cache/test-bin/uapi-abi
.zig-cache/test-bin/uapi-abi
