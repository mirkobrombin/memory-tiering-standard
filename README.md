# Memory Tiering Standard

MTS makes anonymous memory a schedulable resource with explicit page cost,
declarative tiers and measurable cgroup service-level objectives. It is not a
new swap compressor. The kernel owns admission, placement safety and forward
progress; userspace declares desired state and reports reproducible evidence.

This private monorepo is the pre-upstream integration tree. It keeps the frozen
v0.2 specification, Linux-facing ABI, Zig control tools and evaluation harness
together while the first end-to-end implementation is measured.

## Status

- Architecture: MTS v0.2 frozen, including the append-only admission ABI.
- M0: observe collector, ISO16/Brier model, MRC and executable gate complete.
- M1: native file/NVMe object tier and `SWP_MTS` reclaim/fork/zap/fault path
  compile-verified against Linux 7.1.3.
- M2: four-resource cgroup admission, PD1 reference controller, provider-loss
  transitions, normalized telemetry and machine-checkable gates implemented.
- Hardware acceptance: not claimed; the normative 128-core/NVMe trials have
  not run in this workspace.

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

The kernel patch series is intentionally separate from the Zig build. The seven
patches apply in order to Linux 7.1.3 and build the complete `mm/built-in.a`.
See `linux/README.md` for the supported first path and its explicit limits.

## Contribution rule

Changes are small, tested and additive. Comments explain why an invariant or
fail-safe exists, not what a line already says. Every commit carries a
`Signed-off-by` trailer under DCO 1.1.

## Licensing

Licensing is per path because this tree contains kernel code, UAPI, software and
standards text. See `LICENSES/README.md`.
