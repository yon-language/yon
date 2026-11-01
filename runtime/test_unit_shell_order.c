/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_shell_order.c — the index of the shell is ordered by structure.
 *
 * Over every one of the 196,560 points:
 *   - the index is a bijection onto [0, 196560), both ways;
 *   - the shapes are the intervals Octadic, Golay, Axial, in that order, and
 *     inside each shape its orbits are consecutive intervals;
 *   - every point is in the interval of its shape (its subtype) and of its
 *     orbit (the union-find orbit under M24 of its raw index);
 *   - within an orbit the order is the raw order;
 *   - the classes agree with XTower at levels 1, 2 and 3 and with
 *     LatticePoint.orbit. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "xleech2_mphf.h"
#include "leech_orbits.h"

extern uint32_t gen_leech2_subtype(uint64_t v2);
double yon_rt_xtower_class(double point, double level);
double yon_rt_lattice_orbit(int64_t p);
double yon_rt_lattice_index(int64_t p);
int64_t yon_rt_lattice_unchecked_index(double i);

static int failures = 0;
static void check(int ok, const char *what) {
    printf("[%s] %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) failures++;
}

int main(void) {
    const uint32_t N = 196560u;
    uint8_t *seen = calloc(N, 1);
    uint32_t *last_raw = malloc(12 * sizeof(uint32_t));
    for (int o = 0; o < 12; o++) last_raw[o] = 0;
    int bij = 1, back = 1, in_shape = 1, in_orbit = 1, raw_order = 1;
    int tower1 = 1, tower2 = 1, tower3 = 1, lat = 1, lat_index = 1;
    for (uint32_t raw = 0; raw < N; raw++) {
        uint32_t v = (uint32_t)yon_mphf_raw_unindex(raw);
        uint32_t i = yon_mphf_index(v);
        if (i >= N || seen[i]) { bij = 0; continue; }
        seen[i] = 1;
        if ((uint32_t)yon_mphf_unindex(i) != v) back = 0;
        uint32_t shape = gen_leech2_subtype((uint64_t)v) & 0xFu;
        uint32_t o = yon_leech_m24_orbit_of_raw(raw);
        if (yon_shell_shape_of_index(i) != shape) in_shape = 0;
        if (i < yon_shell_shape_first(shape)
            || i >= yon_shell_shape_first(shape) + yon_shell_shape_count(shape)) in_shape = 0;
        if (yon_shell_orbit_of_index(i) != o || yon_shell_orbit_shape(o) != shape) in_orbit = 0;
        if (i < yon_shell_orbit_first(o)
            || i >= yon_shell_orbit_first(o) + yon_shell_orbit_count(o)) in_orbit = 0;
        /* the raw indices come in increasing order: within the orbit the
           index is the next of its interval */
        if (i != yon_shell_orbit_first(o) + last_raw[o]) raw_order = 0;
        last_raw[o]++;
        if (yon_rt_xtower_class((double)v, 1.0) != (double)shape) tower1 = 0;
        if (yon_rt_xtower_class((double)v, 2.0) != (double)o) tower2 = 0;
        if (yon_rt_xtower_class((double)v, 3.0) != (double)i) tower3 = 0;
        if (yon_rt_lattice_orbit((int64_t)v) != (double)o) lat = 0;
        if (yon_rt_lattice_index((int64_t)v) != (double)i
            || yon_rt_lattice_unchecked_index((double)i) != (int64_t)v) lat_index = 0;
    }
    for (uint32_t i = 0; i < N; i++) if (!seen[i]) bij = 0;
    check(bij, "the index is a bijection of the 196560 points onto [0, 196560)");
    check(back, "the point of the index of a point is the point");
    check(in_shape, "every point is in the interval of its shape");
    check(in_orbit, "every point is in the interval of its orbit, inside its shape");
    check(raw_order, "within an orbit the order is the raw order");
    check(tower1, "the class at level 1 of XTower is the shape of the interval");
    check(tower2, "the class at level 2 of XTower is the orbit of the interval");
    check(tower3, "the class at level 3 of XTower is the index");
    check(lat, "LatticePoint.orbit is the orbit of the interval");
    check(lat_index, "LatticePoint.index and at_index are the index, both ways");
    /* the intervals tile [0, N) in the order Octadic, Golay, Axial, and the
       orbits of a shape tile the shape */
    int tile = yon_shell_shape_first(2) == 0
            && yon_shell_shape_first(1) == yon_shell_shape_count(2)
            && yon_shell_shape_first(0) == yon_shell_shape_count(2) + yon_shell_shape_count(1)
            && yon_shell_shape_first(0) + yon_shell_shape_count(0) == N
            && yon_shell_shape_count(2) == 97152 && yon_shell_shape_count(1) == 98304
            && yon_shell_shape_count(0) == 1104;
    uint32_t per_shape[3] = {0, 0, 0};
    for (uint32_t o = 0; o < 12; o++) per_shape[yon_shell_orbit_shape(o)] += yon_shell_orbit_count(o);
    tile = tile && per_shape[0] == 1104 && per_shape[1] == 98304 && per_shape[2] == 97152;
    check(tile, "the shapes tile the shell Octadic, Golay, Axial; the orbits tile each shape");
    free(seen);
    free(last_raw);
    if (failures == 0) { printf("SHELL_ORDER: PASS\n"); return 0; }
    printf("SHELL_ORDER: FAIL (%d)\n", failures);
    return 1;
}
