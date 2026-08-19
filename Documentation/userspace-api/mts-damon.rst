.. SPDX-License-Identifier: CC-BY-4.0

==========================
MTS on DAMON, without a patched kernel
==========================

The kernel transport needs the seven patches in ``linux/patches``, applied to
Linux 7.1.3 and rebuilt. That is the right place for the mechanism and the
wrong place to start an argument: a runtime asked to adopt MTS is being asked
to make its users carry a kernel, and it will decline before reading the
design.

This backend exists so the argument can start somewhere else. It drives DAMON
through sysfs, which is mainline, so the policy can be put under a real
workload on a stock kernel and measured. What it measures is not the kernel
transport; it is the same policy reaching for the same decisions through a
much blunter instrument, and the gap between the two is the number worth
publishing.

Choosing a transport
====================

One environment variable, read by ``build.sh``, and nothing else in the tree
changes::

    ./build.sh                     # kernel transport, needs linux/patches
    MTS_BACKEND=damon ./build.sh   # DAMON through sysfs

The choice is made when the binaries are built, never at runtime. A build
carrying both would have to say which one spoke when a measurement was
recorded, and a measurement whose transport is ambiguous is not a measurement.

What it needs
=============

A kernel with ``CONFIG_DAMON_SYSFS``, which is every mainline kernel since
5.15, and the sysfs tree present::

    $ ls /sys/kernel/mm/damon/admin
    kdamonds

Writing schemes needs privilege. Nothing else is required: no module, no patch,
no reboot.

What it is not
==============

It is not a second implementation of MTS, and reading it as one produces
numbers that mean nothing.

The kernel transport decides in the fault path. DAMON samples regions on its
own schedule and acts later, so what one decides synchronously the other asks
for and finds out about afterwards. That difference is reported through
telemetry rather than smoothed over in the backend, because it is the thing
being measured.

Three capabilities are absent, and their absence is the argument for the patch
series:

``SWP_MTS``
    A demoted page goes to whatever swap the host has. There is no object
    identity behind it, so nothing can be re-derived, validated or generation
    checked.

Per-page reuse
    ISO16 labels come from the fault path. Here reuse is whatever DAMON's
    access counters saw for a region, which is coarser by orders of magnitude
    and late.

Reservation
    ``admitDomain`` on the kernel transport returns a reservation the kernel
    then honours. Here a domain gets a scheme the kernel will apply when it
    next samples. A caller that reads the second as the first is reading a
    service level nobody promised.

A tier whose kind has no DAMOS action behind it is refused rather than mapped
onto the nearest one. ``remote-memory`` and ``compressed-memory`` have no
action, so a configuration naming them does not run on this backend. A run that
measured something other than what was configured is worse than a run that did
not happen.

What is unchanged
=================

Everything above the transport. The PD1 controller, the object table, the
ISO16 predictor, the MRC, the statistics and the evaluation harness are the
same code and do not know which backend they ran on. That is the point of the
split: the comparison is between two transports carrying one policy, not
between two systems.

The contract
============

``src/backend.zig`` is the seam, and it is two declarations::

    pub const registerTier = impl.registerTier;
    pub const admitDomain = impl.admitDomain;

A transport that cannot answer them is not a transport. One that wanted to
answer more would be asking the policy to know which of them it is talking to.

Both take an ``io``. The kernel transport does not use it and says so; a
transport that touches the filesystem must not have to reach around the
abstraction the rest of the tree uses to do it.

Status
======

The backend validates a configuration, maps tiers onto DAMOS actions and
refuses what it cannot express. Writing the schemes and reading back what DAMON
did are not implemented: ``admitDomain`` returns ``DomainNotAdmitted``. The
seam, the build selection and the boundary are in place; the sysfs writes are
the next piece.
