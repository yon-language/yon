/* leech_orbits.h — pure M24 orbits over the Leech type-2 shell.
 *
 * mmgroup gives Co_0 (transitive: one orbit) and N_0 (the three shapes /
 * subtypes), but no direct reduction under the Mathieu group M24 alone. The
 * shell is small (196560 points), so the orbits are precomputed once by
 * union-find under a fixed generating set of M24, then indexed by the MPHF: an
 * exact, deterministic O(1) lookup. There are exactly 12 orbits (4 in shape
 * (4^2 0^22), 5 in (3 1^23), 3 in (2^8 0^16)). A proper subgroup would yield
 * MORE than 12 (orbits only split under a smaller group), so reaching 12
 * certifies the generating set covers all of M24.
 *
 * This is the single source of truth for "the M24 orbit of a point": both the
 * arena and the runtime primitive Leech.m24_orbit read it, so the language has
 * one notion of orbit, not two. */
#ifndef YON_LEECH_ORBITS_H
#define YON_LEECH_ORBITS_H

#include <stdint.h>
#include "xleech2_coord.h"   /* yon_xcoord_t */

#define YON_LEECH_PURE_ORBITS   12u
#define YON_LEECH_ORBIT_INVALID 0xFFFFFFFFu

/* Pure M24 orbit id of a point, in [0, 12), or YON_LEECH_ORBIT_INVALID if the
 * point is not type-2. The table is built lazily on first use. */
uint32_t yon_leech_m24_orbit_pure(yon_xcoord_t point);

#endif /* YON_LEECH_ORBITS_H */
