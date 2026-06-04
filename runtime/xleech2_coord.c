/* xleech2_coord.c — implementation of the native XLeech2 type. */

#include "xleech2_coord.h"
#include <pthread.h>

/* Forward declaration from libmmgroup_mat24.so */
extern uint32_t gen_leech2_type(uint32_t v);

/* Mutex shared with xleech2_move.c to serialize calls into libmmgroup.
 * libmmgroup is not thread-safe by default. Defined in xleech2_move.c. */
extern pthread_mutex_t mmgroup_mutex;

int yon_xcoord_type(yon_xcoord_t v) {
    /* Bit 25+ should always be 0 for valid encoding */
    if (v & ~YON_XCOORD_VALID_MASK) return -1;
    pthread_mutex_lock(&mmgroup_mutex);
    int t = (int)gen_leech2_type(v);
    pthread_mutex_unlock(&mmgroup_mutex);
    return t;
}

bool yon_xcoord_is_type2(yon_xcoord_t v) {
    return yon_xcoord_type(v) == 2;
}

int yon_xcoord_to_int24(yon_xcoord_t v, int16_t out[24]) {
    /* Stub: future implementation.
     *
     * To implement:
     * - mmgroup has gen_leech2_short_vector(...) or similar (check the docs)
     * - Alternatively: extract the Golay code part + cocode part and
     *   reconstruct the vector per Theorem 6.1 of the Seysen paper.
     *
     * For now: return -1, declaring the gap honestly. The human-readable
     * export is not needed for runtime operations; it is only for
     * debug/display.
     */
    (void)v;
    (void)out;
    return -1;
}
