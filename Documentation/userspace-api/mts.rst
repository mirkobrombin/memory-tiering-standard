.. SPDX-License-Identifier: GPL-2.0-only

=======================
Memory Tiering Standard
=======================

MTS exposes native memory tiers through ``/dev/mts`` and policy domains through
cgroup v2. The v0.2 UAPI is append-only until v0.3. Userspace must initialize
``version`` and ``size`` and zero every reserved field.

Portable configuration
======================

``mts.conf`` is shared by systemd and non-systemd implementations. The
administrator file is ``/etc/mts/mts.conf``. Drop-ins are loaded from
``/usr/lib/mts/mts.conf.d``, ``/run/mts/mts.conf.d`` and
``/etc/mts/mts.conf.d`` in increasing precedence, then lexicographically.
Reload is validate-then-commit: one invalid assignment rejects the whole set.

The format is UTF-8 INI. Keys are case-sensitive. Unknown names are fatal unless
prefixed by ``X-``. The three section forms are::

  [MTS]
  Version=2
  Mode=observe

  [Tier "fast-nvme"]
  UUID=018f3f28-7ee0-7dd2-a400-8f847e14c001
  Kind=local-storage
  Provider=/dev/disk/by-id/nvme-example
  Flags=persistent
  CapacityBytes=1099511627776

  [Domain "/workload.slice/redis.service"]
  Mode=enforce
  Tiers=dram,fast-nvme
  FaultServiceP99USec=200
  ReuseHorizonUSec=1000000

``[MTS]`` keys
----------------

``Version`` is required and must be ``2``. ``Mode`` is ``off``, ``observe`` or
``enforce`` and defaults to ``off``.

``[Tier]`` keys
---------------

``UUID``, ``Kind``, ``Provider`` and ``CapacityBytes`` are required. ``Kind`` is
one of ``compressed-memory``, ``persistent-local-memory``, ``cxl-memory``,
``local-storage``, ``remote-memory`` or ``legacy-swap``. ``Flags`` is exactly
one of ``persistent`` or ``fd-scoped``. Capability keys mirror
``mts_tier_desc_v2`` with their UAPI field names converted to UpperCamelCase.
Omitted capability values are unknown, never zero-cost.

``[Domain]`` keys
-----------------

``Mode`` and ``Tiers`` are required. ``FaultServiceP99USec`` is required in
enforce mode. ``ReuseHorizonUSec`` defaults to 1000000. ``Predictor`` defaults
to ``iso16``. ``Controller`` defaults to ``pd1``. Tier names must resolve after
all files are merged.

Provider loss
=============

Closing the control file descriptor of an ``fd-scoped`` provider moves the tier
to draining. Every admitted domain with a reservation on that tier moves to
``AT_RISK`` and emits ``mts:slo_transition`` with
``MTS_CAUSE_PROVIDER_FD_CLOSED``. Userspace cannot acknowledge that event back
into ``ADMITTED``; only successful kernel admission can do so.

Stable tracepoint schema
========================

The v0.2 tracepoints are ``mts:fault_begin``, ``mts:fault_end``,
``mts:batch_submit``, ``mts:batch_complete`` and ``mts:slo_transition``.
Fault events carry cgroup ID, address, object ID, generation, tier UUID and a
per-domain fault sequence. Batch events carry batch ID, operation, page count,
bytes, status and timestamps. SLO transitions carry cgroup ID, old status, new
status, cause and the provider UUID when applicable.

Latency histograms use exactly ``MTS_HISTOGRAM_UPPER_NS_V2_INIT``.
Implementations must not substitute provider-specific bucket boundaries in
normalized output.
