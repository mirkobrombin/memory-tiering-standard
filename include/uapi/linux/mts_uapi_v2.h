/* SPDX-License-Identifier: (GPL-2.0 WITH Linux-syscall-note) OR MIT */
#ifndef _UAPI_LINUX_MTS_UAPI_V2_H
#define _UAPI_LINUX_MTS_UAPI_V2_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define MTS_UAPI_VERSION 2U
#define MTS_UUID_BYTES 16U
#define MTS_HISTOGRAM_BUCKETS 32U
#define MTS_MAX_DOMAIN_TIERS 8U
#define MTS_TIER_SLOT_DRAM 0U
#define MTS_TIER_SLOT_NONE 255U

#define MTS_TRACE_FAULT_BEGIN "mts:fault_begin"
#define MTS_TRACE_FAULT_END "mts:fault_end"
#define MTS_TRACE_BATCH_SUBMIT "mts:batch_submit"
#define MTS_TRACE_BATCH_COMPLETE "mts:batch_complete"
#define MTS_TRACE_SLO_TRANSITION "mts:slo_transition"

#define MTS_ATTR_VERSION_SHIFT 0U
#define MTS_ATTR_STATE_SHIFT 4U
#define MTS_ATTR_REUSE_Q12_SHIFT 8U
#define MTS_ATTR_REBUILD_LOG_Q12_SHIFT 20U
#define MTS_ATTR_CURRENT_TIER_SHIFT 32U
#define MTS_ATTR_TARGET_TIER_SHIFT 40U
#define MTS_ATTR_POLICY_CLASS_SHIFT 48U
#define MTS_ATTR_SAMPLE_AGE_SHIFT 56U

#define MTS_ATTR_VERSION_MASK (0xfull << MTS_ATTR_VERSION_SHIFT)
#define MTS_ATTR_STATE_MASK (0xfull << MTS_ATTR_STATE_SHIFT)
#define MTS_ATTR_REUSE_Q12_MASK (0xfffull << MTS_ATTR_REUSE_Q12_SHIFT)
#define MTS_ATTR_REBUILD_LOG_Q12_MASK (0xfffull << MTS_ATTR_REBUILD_LOG_Q12_SHIFT)
#define MTS_ATTR_CURRENT_TIER_MASK (0xffull << MTS_ATTR_CURRENT_TIER_SHIFT)
#define MTS_ATTR_TARGET_TIER_MASK (0xffull << MTS_ATTR_TARGET_TIER_SHIFT)
#define MTS_ATTR_POLICY_CLASS_MASK (0xffull << MTS_ATTR_POLICY_CLASS_SHIFT)
#define MTS_ATTR_SAMPLE_AGE_MASK (0xffull << MTS_ATTR_SAMPLE_AGE_SHIFT)

#define MTS_ATTR_GET(word, field) \
	(((word) & MTS_ATTR_##field##_MASK) >> MTS_ATTR_##field##_SHIFT)
#define MTS_ATTR_SET(value, field) \
	((((__u64)(value)) << MTS_ATTR_##field##_SHIFT) & MTS_ATTR_##field##_MASK)

enum mts_page_state_v2 {
	MTS_PAGE_RESIDENT = 0,
	MTS_PAGE_QUEUED = 1,
	MTS_PAGE_MIGRATING = 2,
	MTS_PAGE_EXTERNAL = 3,
	MTS_PAGE_RECONSTRUCTIBLE = 4,
	MTS_PAGE_PINNED = 5,
	MTS_PAGE_FAILED = 6,
};

enum mts_tier_kind_v2 {
	MTS_TIER_DRAM = 0,
	MTS_TIER_COMPRESSED_MEMORY = 1,
	MTS_TIER_PERSISTENT_LOCAL_MEMORY = 2,
	MTS_TIER_CXL_MEMORY = 3,
	MTS_TIER_LOCAL_STORAGE = 4,
	MTS_TIER_REMOTE_MEMORY = 5,
	MTS_TIER_LEGACY_SWAP = 6,
};

enum mts_tier_flags_v2 {
	MTS_TIER_F_PERSISTENT = 1U << 0,
	MTS_TIER_F_FD_SCOPED = 1U << 1,
};

enum mts_confidentiality_v2 {
	MTS_CONF_NONE = 0,
	MTS_CONF_DOMAIN_ISOLATED = 1U << 0,
	MTS_CONF_BOUNDED = 1U << 1,
};

enum mts_domain_status_v2 {
	MTS_SLO_UNADMITTED = 0,
	MTS_SLO_ADMITTED = 1,
	MTS_SLO_AT_RISK = 2,
	MTS_SLO_VIOLATED = 3,
	MTS_SLO_UNKNOWN = 4,
};

enum mts_event_cause_v2 {
	MTS_CAUSE_NONE = 0,
	MTS_CAUSE_PROVIDER_FD_CLOSED = 1,
	MTS_CAUSE_PROVIDER_IO = 2,
	MTS_CAUSE_RESERVATION_REVOKED = 3,
	MTS_CAUSE_MODEL_UNCALIBRATED = 4,
};

struct mts_tier_desc_v2 {
	__u16 version;
	__u16 kind;
	__u32 flags;
	__u8 uuid[MTS_UUID_BYTES];
	__u64 capacity_bytes;
	__u64 allocation_granule_bytes;
	__u64 read_latency_p50_ns;
	__u64 read_latency_p99_ns;
	__u64 write_latency_p50_ns;
	__u64 write_latency_p99_ns;
	__u64 read_bandwidth_bytes_s;
	__u64 write_bandwidth_bytes_s;
	__u64 write_cost_nj_per_kib;
	__u64 endurance_cost_ppb_per_kib;
	__u32 volatility_class;
	__u32 failure_domain;
	__u32 max_batch_pages;
	__u32 max_inflight_batches;
	__u32 confidentiality_caps;
	__u16 compression_size_classes;
	__u16 compression_leakage_bits_q8;
	__u64 completion_release_quantum_ns;
	__u64 reserved[8];
};

struct mts_register_tier_v2 {
	__u16 version;
	__u16 size;
	__u32 reserved0;
	struct mts_tier_desc_v2 tier;
	__s32 provider_fd;
	__s32 mtsfd;
	__u64 reserved[6];
};

struct mts_query_attr_v2 {
	__u16 version;
	__u16 size;
	__u32 flags;
	__u64 start;
	__u64 length;
	__u64 attrs_ptr;
	__u64 recover_ns_ptr;
	__u32 attr_stride;
	__u32 entries;
	__u64 reserved[4];
};

struct mts_histogram_v2 {
	__u64 buckets[MTS_HISTOGRAM_BUCKETS];
	__u64 sum_ns;
	__u64 samples;
};

struct mts_tier_reservation_v2 {
	__s32 tier_fd;
	__u32 reserved0;
	__u64 capacity_bytes;
	__u64 read_bandwidth_bytes_s;
	__u64 write_bandwidth_bytes_s;
	__u32 queue_slots;
	__u32 reserved1;
};

struct mts_admit_domain_v2 {
	__u16 version;
	__u16 size;
	__u32 flags;
	__s32 cgroup_fd;
	__s32 domain_fd;
	__u64 fault_service_p99_ns;
	__u64 reuse_horizon_us;
	__u64 reservations_ptr;
	__u32 reservation_count;
	__u32 status;
	__u64 stable_cgroup_id;
	__u64 reserved[6];
};

/* Inclusive upper bounds in ns. Instantiate this initializer in userspace. */
#define MTS_HISTOGRAM_UPPER_NS_V2_INIT { \
	1000ULL, 2000ULL, 4000ULL, 8000ULL, \
	16000ULL, 32000ULL, 64000ULL, 128000ULL, \
	256000ULL, 512000ULL, 1000000ULL, 2000000ULL, \
	4000000ULL, 8000000ULL, 16000000ULL, 32000000ULL, \
	64000000ULL, 128000000ULL, 256000000ULL, 512000000ULL, \
	1000000000ULL, 2000000000ULL, 4000000000ULL, 8000000000ULL, \
	16000000000ULL, 32000000000ULL, 64000000000ULL, 128000000000ULL, \
	256000000000ULL, 512000000000ULL, 1000000000000ULL, ~0ULL, \
}

#define MTS_IOC_MAGIC 0xBC
#define MTS_IOC_REGISTER_TIER \
	_IOWR(MTS_IOC_MAGIC, 0x01, struct mts_register_tier_v2)
#define MTS_IOC_UNREGISTER_TIER _IOW(MTS_IOC_MAGIC, 0x02, __u8[MTS_UUID_BYTES])
#define MTS_IOC_QUERY_ATTR _IOWR(MTS_IOC_MAGIC, 0x03, struct mts_query_attr_v2)
#define MTS_IOC_ADMIT_DOMAIN \
	_IOWR(MTS_IOC_MAGIC, 0x04, struct mts_admit_domain_v2)

#endif /* _UAPI_LINUX_MTS_UAPI_V2_H */
