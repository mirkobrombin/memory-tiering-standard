// SPDX-License-Identifier: Apache-2.0
const options = @import("build_options");

// The transport MTS drives. Everything above this file, the PD1 controller,
// the object table, the predictor and the evaluation harness, is written
// against the policy and never against a transport, so choosing one is
// choosing this import and nothing else.
//
// The two declarations at the bottom are the whole contract. A transport that
// cannot answer them is not one, and a transport that wanted to answer more
// would be asking the policy to know which of them it is talking to.
//
// The choice is made when the binaries are built. A build carrying both would
// have to say which one spoke when a measurement was recorded, and a
// measurement whose transport is ambiguous is not a measurement.
//
//   ./build.sh                     the kernel transport, needs linux/patches
//   MTS_BACKEND=damon ./build.sh   DAMON through sysfs, on a stock kernel
const impl = switch (options.backend) {
    .kernel => @import("linux_uapi.zig"),
    .damon => @import("damon_backend.zig"),
};

pub const registerTier = impl.registerTier;
pub const admitDomain = impl.admitDomain;
