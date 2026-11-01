/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* xleech2_mphf.c — the index of a point of the shell, ordered by structure.
 *
 * The raw bijection comes from two mmgroup functions (no tables of our own):
 * raw = 2 * (extern - 300) + sign. The index is the rank of the point in the
 * order of the shell's structure: first by shape under N (Octadic, Golay,
 * Axial), within a shape by M24 orbit (the pure orbits, in the order of their
 * classes on the tower), within an orbit by raw index. Every shape and every
 * orbit is an interval of indices, given by the constant table below.
 *
 * The rank is a permutation of [0, 196560) composed with the raw bijection,
 * kept in two tables (raw -> index, index -> raw) of 196,560 words of 32 bits
 * each: built once per process, on the first ask, from the shell itself (the
 * orbits by union-find under M24, the shapes by subtype), then only read. */

#include "xleech2_mphf.h"
#include "leech_theta.h"
#include "leech_orbits.h"
#include "yon_refusals.h"
#include "yon_mmap.h"
#include <pthread.h>

/* libmmgroup_mm_op.so symbols */
extern uint32_t mm_aux_index_leech2_to_sparse(uint32_t v2);
extern int32_t  mm_aux_index_sparse_to_extern(uint32_t sparse);
extern uint32_t mm_aux_index_extern_to_sparse(uint32_t extern_idx);
extern uint32_t mm_aux_index_sparse_to_leech2(uint32_t sparse);
extern uint32_t gen_leech2_subtype(uint64_t v2);

extern pthread_mutex_t mmgroup_mutex;

/* extern in [300, 98579] covers the 98,280 unsigned type-2 vectors */
#define EXTERN_OFFSET 300u
#define EXTERN_MAX    98579u

uint32_t yon_mphf_raw_index(yon_xcoord_t v) {
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

yon_xcoord_t yon_mphf_raw_unindex(uint32_t raw) {
    if (raw >= YON_LEECH_TYPE2_COUNT) return YON_XCOORD_INVALID;

    uint32_t ext = (raw >> 1) + EXTERN_OFFSET;
    uint32_t sign = raw & 1u;

    pthread_mutex_lock(&mmgroup_mutex);
    uint32_t sparse = mm_aux_index_extern_to_sparse(ext);
    uint32_t v_unsigned = mm_aux_index_sparse_to_leech2(sparse);
    pthread_mutex_unlock(&mmgroup_mutex);

    return (yon_xcoord_t)(v_unsigned | (sign ? YON_XCOORD_SIGN_BIT : 0u));
}

/* ─── The intervals: one per orbit, in the order of the shell ─────────── */

/* the orbits in index order: Octadic (classes 4, 5, 6), Golay (7 to 11),
   Axial (0 to 3); each with its shape (its class at level 1 of the tower),
   its first index and its points */
static const uint32_t ORDER_ORBIT[YON_LEECH_PURE_ORBITS] = { 4, 5, 6, 7, 8, 9, 10, 11, 0, 1, 2, 3 };
static const uint32_t ORBIT_SHAPE[YON_LEECH_PURE_ORBITS] = { 0, 0, 0, 0, 2, 2, 2, 1, 1, 1, 1, 1 };
static const uint32_t ORBIT_FIRST[YON_LEECH_PURE_ORBITS] = {
    195456, 195732, 196008, 196284,          /* Axial   */
    0, 1518, 44022,                          /* Octadic */
    97152, 97176, 97200, 109344, 133632 };   /* Golay   */
static const uint32_t ORBIT_COUNT[YON_LEECH_PURE_ORBITS] = {
    276, 276, 276, 276,
    1518, 42504, 53130,
    24, 24, 12144, 24288, 61824 };
/* the shapes, by their class at level 1 (0 Axial, 1 Golay, 2 Octadic) */
static const uint32_t SHAPE_FIRST[3] = { 195456, 97152, 0 };
static const uint32_t SHAPE_COUNT[3] = { 1104, 98304, 97152 };

uint32_t yon_shell_orbit_first(uint32_t o) { return o < YON_LEECH_PURE_ORBITS ? ORBIT_FIRST[o] : 0u; }
uint32_t yon_shell_orbit_count(uint32_t o) { return o < YON_LEECH_PURE_ORBITS ? ORBIT_COUNT[o] : 0u; }
uint32_t yon_shell_orbit_shape(uint32_t o) { return o < YON_LEECH_PURE_ORBITS ? ORBIT_SHAPE[o] : 0u; }
uint32_t yon_shell_shape_first(uint32_t s) { return s < 3u ? SHAPE_FIRST[s] : 0u; }
uint32_t yon_shell_shape_count(uint32_t s) { return s < 3u ? SHAPE_COUNT[s] : 0u; }

/* the orbit whose interval holds index i: the last orbit in index order
   starting at or before i */
uint32_t yon_shell_orbit_of_index(uint32_t i) {
    if (i >= YON_LEECH_TYPE2_COUNT) return YON_LEECH_ORBIT_INVALID;
    uint32_t o = ORDER_ORBIT[0];
    for (uint32_t k = 0; k < YON_LEECH_PURE_ORBITS; k++) {
        if (ORBIT_FIRST[ORDER_ORBIT[k]] <= i) o = ORDER_ORBIT[k];
    }
    return o;
}

uint32_t yon_shell_shape_of_index(uint32_t i) {
    uint32_t o = yon_shell_orbit_of_index(i);
    return o == YON_LEECH_ORBIT_INVALID ? YON_LEECH_ORBIT_INVALID : ORBIT_SHAPE[o];
}

/* ─── The permutation ─────────────────────────────────────────────────── */

static uint32_t *g_rank;      /* raw -> index */
static uint32_t *g_unrank;    /* index -> raw */
static pthread_once_t g_order_once = PTHREAD_ONCE_INIT;

static void build_order(void) {
    uint32_t N = YON_LEECH_TYPE2_COUNT;
    uint32_t *rank = (uint32_t *)yon_map((size_t)N * sizeof(uint32_t));
    uint32_t *unrank = (uint32_t *)yon_map((size_t)N * sizeof(uint32_t));
    uint32_t next[YON_LEECH_PURE_ORBITS];
    for (uint32_t o = 0; o < YON_LEECH_PURE_ORBITS; o++) next[o] = ORBIT_FIRST[o];
    /* the raw indices in increasing order: within an orbit, the raw order */
    for (uint32_t raw = 0; raw < N; raw++) {
        uint32_t o = yon_leech_m24_orbit_of_raw(raw);
        uint32_t v = (uint32_t)yon_mphf_raw_unindex(raw);
        uint32_t shape = gen_leech2_subtype((uint64_t)(v & YON_XCOORD_VALID_MASK)) & 0xFu;
        if (o >= YON_LEECH_PURE_ORBITS || shape != ORBIT_SHAPE[o]
            || next[o] >= ORBIT_FIRST[o] + ORBIT_COUNT[o]) {
            yon_rt_refuse_with(YON_REFUSAL_ShellOrderDrifted, o, raw, shape);
        }
        rank[raw] = next[o];
        unrank[next[o]] = raw;
        next[o]++;
    }
    for (uint32_t o = 0; o < YON_LEECH_PURE_ORBITS; o++) {
        if (next[o] != ORBIT_FIRST[o] + ORBIT_COUNT[o])
            yon_rt_refuse_with(YON_REFUSAL_ShellOrderDrifted, o, next[o] - ORBIT_FIRST[o], 0);
    }
    g_unrank = unrank;
    g_rank = rank;
}

uint32_t yon_mphf_index(yon_xcoord_t v) {
    uint32_t raw = yon_mphf_raw_index(v);
    if (raw == YON_MPHF_INVALID) return YON_MPHF_INVALID;
    pthread_once(&g_order_once, build_order);
    return g_rank[raw];
}

yon_xcoord_t yon_mphf_unindex(uint32_t idx) {
    if (idx >= YON_LEECH_TYPE2_COUNT) return YON_XCOORD_INVALID;
    pthread_once(&g_order_once, build_order);
    return yon_mphf_raw_unindex(g_unrank[idx]);
}
