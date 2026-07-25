# Contributing to MTS

MTS sits in reclaim and fault paths, where a convenient fallback can become
silent data loss or an unbounded stall. Keep changes small, explicit and tested.

## Before sending a change

```sh
./test.sh
git diff --check
```

- UAPI and tracepoint schemas are append-only until v0.3.
- Never add a synchronous userspace dependency to reclaim or fault handling.
- Reject partial configuration reloads.
- Comments explain why; tests name the invariant they protect.
- Commit subjects use `component: outcome`, followed by a short body describing
  the reason and the evidence.
