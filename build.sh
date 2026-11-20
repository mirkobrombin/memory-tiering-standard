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
# The transport is chosen here and nowhere else. The default needs the patch
# series in linux/patches; damon needs nothing but a kernel with DAMON built
# in, which is every mainline kernel since 5.15, and is how the policy gets
# measured before anybody is asked to carry a patched kernel.
MTS_BACKEND="${MTS_BACKEND:-kernel}"
case "$MTS_BACKEND" in
  kernel|damon) ;;
  *) echo "ERROR: MTS_BACKEND must be kernel or damon, got $MTS_BACKEND" >&2; exit 1 ;;
esac
echo "backend: $MTS_BACKEND"
# The chosen transport reaches the code as a module of one declaration, so
# that both implementations stay in the ordinary source tree and Zig does not
# have to be told that config.zig belongs to two modules at once.
options_dir="zig-out/options"
mkdir -p "$options_dir"
printf 'pub const Backend = enum { kernel, damon };\npub const backend: Backend = .%s;\n' \
  "$MTS_BACKEND" > "$options_dir/build_options.zig"
backend_dep="--dep build_options"

target_flag=""
if [ -n "${MTS_TARGET:-}" ]; then
  target_flag="-target $MTS_TARGET"
fi
mkdir -p zig-out/bin
"$ZIG" build-exe $target_flag $backend_dep -Mroot=src/mtsctl.zig "-Mbuild_options=$options_dir/build_options.zig" -O ReleaseSafe -femit-bin=zig-out/bin/mtsctl
"$ZIG" build-exe $target_flag $backend_dep -Mroot=src/mtsd.zig "-Mbuild_options=$options_dir/build_options.zig" -O ReleaseSafe -femit-bin=zig-out/bin/mtsd
"$ZIG" build-exe $target_flag $backend_dep -Mroot=src/mts-generator.zig "-Mbuild_options=$options_dir/build_options.zig" -O ReleaseSafe -femit-bin=zig-out/bin/mts-generator
"$ZIG" build-exe $target_flag $backend_dep -Mroot=src/mts-eval.zig "-Mbuild_options=$options_dir/build_options.zig" -O ReleaseSafe -femit-bin=zig-out/bin/mts-eval
"$ZIG" build-exe $target_flag $backend_dep -Mroot=src/mts-workload.zig "-Mbuild_options=$options_dir/build_options.zig" -O ReleaseSafe -femit-bin=zig-out/bin/mts-workload
