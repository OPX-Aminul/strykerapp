/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * passt is built against the Android NDK, whose headers are bionic's, not
 * glibc's, and the gaps are not the ones passt's Makefile knows about.
 * build-passt.sh puts this header on the command line with -include, so it
 * lands ahead of every translation unit. Each entry says what is missing and
 * which passt source hits it:
 *
 *   <inttypes.h>      PRIu16/PRIu32/... and strtoimax(). passt uses both
 *                     without including this header; on glibc they arrive
 *                     through the chain it includes, on bionic they do not
 *                     (conf.c, util.c).
 *   MAXNS             bionic's <resolv.h> has no MAXNS/MAXDNSRCH/NS_MAXDNAME.
 *   MAXDNSRCH         The values below are glibc's (bits/types/res_state.h,
 *   NS_MAXDNAME       arpa/nameser.h), and they are what passt sizes its
 *                     resolver and DHCP option buffers with (passt.h, dhcp.c,
 *                     dhcpv6.c, ndp.c).
 *   _PATH_LOG         bionic's <paths.h> has no /dev/log entry; log.c wants to
 *                     send to it and falls back to stderr when the connect
 *                     fails, which is what happens on the device anyway.
 *   struct udphdr     bionic's <linux/udp.h> defines __kernel_udphdr only and
 *                     keeps struct udphdr in <netinet/udp.h>; checksum.c
 *                     includes the uapi header alone (its forward declaration
 *                     in checksum.h then stays incomplete).
 *   vring_need_event  bionic's <linux/virtio_ring.h> carries the ring
 *                     structures but not the ring helpers the kernel ships
 *                     beside them; virtio.c calls this one.
 *
 * The fixes that cannot live here -- passt's own struct ipv6hdr/ipv6_opt_hdr
 * and its tcp_repair_opt enum colliding with bionic's <linux/ipv6.h> and
 * <linux/tcp.h>, and IN6_IS_ADDR_UNSPECIFIED() reaching for the glibc member
 * name of struct in6_addr -- are in images/patches/passt-bionic.patch.
 */
#ifndef STRYKER_PASST_BIONIC_H
#define STRYKER_PASST_BIONIC_H

#include <inttypes.h>
#include <netinet/udp.h>
#include <linux/virtio_ring.h>

#ifndef MAXNS
#define MAXNS		3
#endif
#ifndef MAXDNSRCH
#define MAXDNSRCH	6
#endif
#ifndef NS_MAXDNAME
#define NS_MAXDNAME	1025
#endif
#ifndef _PATH_LOG
#define _PATH_LOG	"/dev/log"
#endif

/*
 * From the kernel's <linux/virtio_ring.h> (bionic drops it): whether the other
 * side of the ring needs to be told about the new index, i.e. whether the
 * event index is passed -- all arithmetic in 16 bits, as the ring indices are.
 */
static inline int vring_need_event(uint16_t event_idx, uint16_t new_idx,
				   uint16_t old)
{
	return (uint16_t)(new_idx - event_idx - 1) < (uint16_t)(new_idx - old);
}

#endif /* STRYKER_PASST_BIONIC_H */
