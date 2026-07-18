/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* leech_orbits.c — see leech_orbits.h. */
#include "leech_orbits.h"
#include "xleech2_mphf.h"    /* yon_mphf_index / unindex, YON_MPHF_INVALID */
#include "leech_theta.h"     /* YON_LEECH_TYPE2_COUNT */
#include "yon_mmap.h"        /* yon_map / yon_unmap */

#include <stdio.h>
#include <stdlib.h>

/* A fixed generating set of M24 (m24num < MAT24_ORDER = 244823040), verified to
 * yield exactly the 12 pure orbits. */
static const uint32_t LEECH_M24_GENS[4] = { 1000003u, 50000063u, 150000001u, 200000017u };

static uint32_t *g_pure_orbit = NULL;   /* [196560] -> orbit id in [0,12), mmap-backed */

static uint32_t puf_find(uint32_t *p, uint32_t x) {
    while (p[x] != x) { p[x] = p[p[x]]; x = p[x]; }
    return x;
}

static void build_pure_orbits(void) {
    extern uint32_t gen_leech2_op_atom(uint32_t q0, uint32_t g);
    if (g_pure_orbit) return;
    uint32_t N = YON_LEECH_TYPE2_COUNT;
    uint32_t *parent = (uint32_t *)yon_map((size_t)N * sizeof(uint32_t));
    for (uint32_t i = 0; i < N; i++) parent[i] = i;
    for (uint32_t idx = 0; idx < N; idx++) {
        uint32_t p = yon_mphf_unindex(idx);
        for (int k = 0; k < 4; k++) {
            uint32_t q = gen_leech2_op_atom(p, 0x20000000u | LEECH_M24_GENS[k]);  /* g_k . p */
            uint32_t j = yon_mphf_index(q);
            if (j == YON_MPHF_INVALID) continue;
            uint32_t a = puf_find(parent, idx), b = puf_find(parent, j);
            if (a != b) parent[a] = b;
        }
    }
    uint32_t *tab = (uint32_t *)yon_map((size_t)N * sizeof(uint32_t));
    uint32_t roots[YON_LEECH_PURE_ORBITS]; uint32_t nroots = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint32_t r = puf_find(parent, i);
        uint32_t id = YON_LEECH_PURE_ORBITS;
        for (uint32_t k = 0; k < nroots; k++) if (roots[k] == r) { id = k; break; }
        if (id == YON_LEECH_PURE_ORBITS) {
            if (nroots >= YON_LEECH_PURE_ORBITS) {   /* generators drifted: refuse silent error */
                fprintf(stderr, "[leech_orbits] pure-orbit drift: more than %u classes\n",
                        YON_LEECH_PURE_ORBITS);
                abort();
            }
            id = nroots; roots[nroots++] = r;
        }
        tab[i] = id;
    }
    yon_unmap(parent, (size_t)N * sizeof(uint32_t));
    g_pure_orbit = tab;   /* publish last: a reader sees either NULL or a complete table */
}

uint32_t yon_leech_m24_orbit_pure(yon_xcoord_t point) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return YON_LEECH_ORBIT_INVALID;
    if (!g_pure_orbit) build_pure_orbits();
    return g_pure_orbit[idx];
}
