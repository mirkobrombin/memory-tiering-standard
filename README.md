# Memory Tiering Standard

MTS makes anonymous memory a schedulable resource with explicit page cost,
declarative tiers and measurable cgroup service-level objectives. It is not a
new swap compressor. The kernel owns admission, placement safety and forward
progress; userspace declares desired state and reports reproducible evidence.

This monorepo keeps the frozen v0.2 specification, the Linux-facing ABI, the Zig
control tools, the evaluation harness and the Linux patch series that implements
them in one place.

## Build and test

MTS pins Zig 0.16.0.

```sh
./build.sh
./test.sh
```

The kernel patch series is separate from the Zig build. The seven patches in
`linux/patches/` apply in order to Linux 7.1.3 and build the complete
`mm/built-in.a`. See `linux/README.md` for the implemented reclaim path.

## Transports

The policy is written against a transport, not against a kernel, and the
transport is chosen at build time:

```sh
./build.sh                     # the kernel transport, needs linux/patches
MTS_BACKEND=damon ./build.sh   # DAMON through sysfs, on a stock kernel
```

The DAMON backend exists so the policy can be measured before anyone is asked
to carry a patched kernel. It is deliberately weaker: no `SWP_MTS`, no per-page
reuse label, no reservation. The gap between the two is the argument for the
patch series, so it is reported rather than hidden. See
`Documentation/userspace-api/mts-damon.rst`.

## Licensing

Licensing is per path because this tree contains kernel code, UAPI, software and
standards text. See `LICENSES/README.md`.
