<!-- SPDX-License-Identifier: CC-BY-4.0 -->

# Linux M0-M2 patch set

The series targets Linux 7.1.3. M0 allocates the eight-byte page extension,
collects delayed ISO16 labels, calibrates reuse probabilities and exports
Brier telemetry. M1 adds `/dev/mts`, declarative file-backed native tiers,
generation-checked objects, sticky fork references and integrity validation.
M2 adds atomic cgroup-v2 admission across capacity, read bandwidth, write
bandwidth and queue slots, plus the frozen tracepoint schemas.
The fifth patch reserves ``SWP_MTS`` and connects eligible anonymous folios to
the native object transport through reclaim, fork, zap and major-fault paths.
Patch 6 feeds calibrated ISO16 probability into PD1 tier ranking and updates
the four projected-dual prices when reservations change.
Patch 7 rejects duplicate UUIDs, retires exhausted generation slots and clones
sticky-frozen objects on fork instead of losing exact reference accounting.
Patch 8 lets a domain admitted for a cgroup cover every cgroup below it and
converts the PTEs of a folio after it has been unmapped for migration.
Patch 9 allocates object slots from a free mark in the XArray, so demoting n
pages no longer costs O(n^2).

Apply and build:

```sh
git am /path/to/memory-tiering-standard/linux/patches/*.patch
scripts/config --enable MTS_OBSERVE
scripts/config --enable MTS_TIER
scripts/config --enable MEMCG
scripts/config --enable CGROUPS
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

The patch set is a compile-verified research prototype, not yet an
upstream-ready replacement for the complete Linux swap path. The first
correctness path intentionally demotes only base anonymous folios with one
resident mapping. It freezes that mapping with a migration entry and immediate
TLB flush before provider I/O; large or multiply mapped resident folios fall
back. Once nonresident, fork sharing and lazy COW are supported. Batched
multi-mapping conversion, MTS-cache folios and the normative 128-core/NVMe
hardware gates remain unclaimed.
