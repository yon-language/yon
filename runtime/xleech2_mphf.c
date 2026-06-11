/* xleech2_mphf.c — MPHF implementation via the mmgroup mm_op tables.
 *
 * Composition of 2 C functions already in libmmgroup_mm_op.so to obtain a
 * perfect hash xleech2 <-> idx without any tables of our own.
 */

#include "xleech2_mphf.h"
#include "leech_theta.h"
#include <pthread.h>

/* libmmgroup_mm_op.so symbols */
extern uint32_t mm_aux_index_leech2_to_sparse(uint32_t v2);
extern int32_t  mm_aux_index_sparse_to_extern(uint32_t sparse);
extern uint32_t mm_aux_index_extern_to_sparse(uint32_t extern_idx);
extern uint32_t mm_aux_index_sparse_to_leech2(uint32_t sparse);

extern pthread_mutex_t mmgroup_mutex;

/* Empirical offset: extern in [300, 98579] covers all 98,280 unsigned type-2
 * vectors. Verified exhaustively in Python (see test_mphf.c for the C recheck).
 *
 * idx in [0, 196560) = 2 * (extern - EXTERN_OFFSET) + sign  */
#define EXTERN_OFFSET 300u
#define EXTERN_MAX    98579u

uint32_t yon_mphf_index(yon_xcoord_t v) {
    if (!yon_xcoord_is_type2(v)) return YON_MPHF_INVALID;

    uint32_t sign = (v & YON_XCOORD_SIGN_BIT) ? 1u : 0u;
    uint32_t v_unsigned = (uint32_t)v & YON_XCOORD_ATOM_MASK;

    pthread_mutex_lock(&mmgroup_mutex);
    uint32_t sparse = mm_aux_index_leech2_to_sparse(v_unsigned);
    int32_t ext = mm_aux_index_sparse_to_extern(sparse);
    pthread_mutex_unlock(&mmgroup_mutex);

    if (ext < (int32_t)EXTERN_OFFSET || ext > (int32_t)EXTERN_MAX) {
        return YON_MPHF_INVALID;
    }

    return 2u * ((uint32_t)ext - EXTERN_OFFSET) + sign;
}

yon_xcoord_t yon_mphf_unindex(uint32_t idx) {
    if (idx >= YON_LEECH_TYPE2_COUNT) return YON_XCOORD_INVALID;

    uint32_t ext = (idx >> 1) + EXTERN_OFFSET;
    uint32_t sign = idx & 1u;

    pthread_mutex_lock(&mmgroup_mutex);
    uint32_t sparse = mm_aux_index_extern_to_sparse(ext);
    uint32_t v_unsigned = mm_aux_index_sparse_to_leech2(sparse);
    pthread_mutex_unlock(&mmgroup_mutex);

    return (yon_xcoord_t)(v_unsigned | (sign ? YON_XCOORD_SIGN_BIT : 0u));
}
