# Memory Tiering Standard

MTS makes anonymous memory a schedulable resource with explicit page cost,
declarative tiers and measurable cgroup service-level objectives. It is not a
new swap compressor. The kernel owns admission, placement safety and forward
progress; userspace declares desired state and reports reproducible evidence.

This private monorepo is the pre-upstream integration tree. It keeps the frozen
v0.2 specification, Linux-facing ABI, Zig control tools and evaluation harness
together until the M0 observe-mode gate passes.

## Status

- Architecture: MTS v0.2 frozen.
- M0: observe-mode implementation in progress.
- M1: native NVMe object tier planned after M0 gates.
- M2: PD1 admission and the complete evaluation runner follow M1.

## Layout

- `spec/` — normative architecture.
- `include/uapi/linux/` — append-only UAPI from v0.2 through v0.3.
- `Documentation/userspace-api/` — portable configuration and ABI contract.
- `src/` — zero-dependency Zig reference tools and models.
- `linux/patches/` — reviewable Linux patch series.
- `eval/` — machine-checkable protocol and result schema.
- `systemd/` — boot generator integration; never the MTS controller.

## Build and test

MTS pins Zig 0.16.0. Every fallible operation is handled at its call site and
normal paths do not panic.

```sh
./build.sh
./test.sh
```

The kernel patch series is intentionally separate from the Zig build. Apply it
to the kernel release named by `eval/mts-eval-v0.2.yaml` and use the kernel's
normal build and test process.

## Contribution rule

Changes are small, tested and additive. Comments explain why an invariant or
fail-safe exists, not what a line already says. Every commit carries a
`Signed-off-by` trailer under DCO 1.1.

## Licensing

Licensing is per path because this tree contains kernel code, UAPI, software and
standards text. See `LICENSES/README.md`.
