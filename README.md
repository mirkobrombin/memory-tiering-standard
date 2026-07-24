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

## Licensing

Licensing is per path because this tree contains kernel code, UAPI, software and
standards text. See `LICENSES/README.md`.
