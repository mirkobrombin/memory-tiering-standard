<!-- SPDX-License-Identifier: CC-BY-4.0 -->

# Linux M0 patch set

The series targets Linux 7.1.3 and implements observe mode only. It allocates
the eight-byte page extension, collects delayed ISO16 labels, calibrates reuse
probabilities and exports Brier telemetry. It never moves a page.

Apply and build:

```sh
git am /path/to/memory-tiering-standard/linux/patches/*.patch
scripts/config --enable MTS_OBSERVE
make olddefconfig
make -j"$(nproc)" mm/
make headers_install INSTALL_HDR_PATH=/tmp/mts-headers
```

At runtime, read `/sys/kernel/debug/mts/observe`. `sample_attempts`,
`sample_collisions` and `labels` make sampling loss visible; `brier_sum_q32`
is the sum required to compute the normative out-of-sample Brier score.

The local verification gate builds the complete `mm/` archive and installs
the UAPI headers. Strict `checkpatch.pl` reports only its known `TRACE_EVENT`
macro-shape checks and the per-patch MAINTAINERS warning for patch 2; patch 1
adds the matching MAINTAINERS entry for the series.

The hardware exit gate remains separate: run `redis-zipf` with the normative
manifest and accept M0 only when Brier skill is positive and throughput
overhead is below 0.5 percent.
