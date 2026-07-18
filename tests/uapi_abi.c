// SPDX-License-Identifier: Apache-2.0
#include <linux/mts_uapi_v2.h>

_Static_assert(sizeof(struct mts_tier_desc_v2) == 200, "tier ABI drift");
_Static_assert(sizeof(struct mts_register_tier_v2) == 264, "register ABI drift");
_Static_assert(sizeof(struct mts_tier_reservation_v2) == 40, "reservation ABI drift");
_Static_assert(sizeof(struct mts_admit_domain_v2) == 104, "admission ABI drift");

int main(void)
{
	return 0;
}
