/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* bench_wire_collection.c — what a collection costs on the wire, in memory.
 *
 * Builds a HashMap and an XRelMap of N Number keys (k -> 3k) and a List of N
 * numbers, then times the two halves of a crossing within one process: the
 * frame written (yon_rt_wire_encode) and the value rebuilt from it
 * (yon_rt_wire_decode), as the in-memory transport between two Spaces of one
 * binary does. The rebuilt value is checked against the original (size and
 * every value). The types are registered by hand, under fixed roots. The
 * first run is reported apart: on the FNV heap the later runs rebuild content
 * the heap already holds.
 *
 * Build it in runtime/ against the runtime objects, as bench_trie_nodes.c
 * is. Output: one line per collection: N, frame bytes, encode and decode ms
 * (best of 5, and the first run). */
#include "yon_rt.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

double yon_rt_map_empty(void);
double yon_rt_map_put(double, double, double);
double yon_rt_map_size(double);
double yon_rt_map_value(double, double);
double yon_rt_xrelmap_empty(void);
double yon_rt_xrelmap_set(double, double, double);
double yon_rt_xrelmap_size(double);
double yon_rt_xrelmap_value(double, double);
double yon_rt_list_empty(double);
double yon_rt_list_cons(double, double);
double yon_rt_list_length(double);

#define R_NUM  0x1111u
#define R_MAP  0x2222u
#define R_XMAP 0x3333u
#define R_LIST 0x4444u

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void bench(const char *name, uint64_t root, double v, int n,
                  double (*size)(double), double (*value)(double, double)) {
    yon_wire_buf_t b = { 0 };
    double enc = 1e18, dec = 1e18, enc1 = 0, dec1 = 0, out = 0;
    for (int rep = 0; rep < 5; rep++) {
        double t0 = now_ms();
        if (yon_rt_wire_encode(&b, root, v) != 0) { fprintf(stderr, "encode failed\n"); exit(1); }
        double t1 = now_ms();
        if (yon_rt_wire_decode(b.p, b.len, 0, root, &out) != 0) { fprintf(stderr, "decode failed\n"); exit(1); }
        double t2 = now_ms();
        if (rep == 0) { enc1 = t1 - t0; dec1 = t2 - t1; }
        if (t1 - t0 < enc) enc = t1 - t0;
        if (t2 - t1 < dec) dec = t2 - t1;
    }
    if (size(out) != n) { fprintf(stderr, "%s: size %g, not %d\n", name, size(out), n); exit(1); }
    if (value)
        for (int k = 0; k < n; k++)
            if (value(out, k) != 3.0 * k) { fprintf(stderr, "%s: wrong value at %d\n", name, k); exit(1); }
    printf("%-8s N=%d  frame %zu bytes  encode %.1f ms (first %.1f)  "
           "decode %.1f ms (first %.1f)\n", name, n, b.len, enc, enc1, dec, dec1);
    yon_rt_wire_buf_free(&b);
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 100000;
    static const uint64_t map_kids[2] = { R_NUM, R_NUM };
    static const uint64_t list_kids[1] = { R_NUM };
    yon_rt_register_type(R_NUM, YON_WIRE_KIND_SCALAR, 0, NULL);
    yon_rt_register_type(R_MAP, YON_WIRE_KIND_MAP, 2, map_kids);
    yon_rt_register_type(R_XMAP, YON_WIRE_KIND_XMAP, 2, map_kids);
    yon_rt_register_type(R_LIST, YON_WIRE_KIND_LIST, 1, list_kids);
    double m = yon_rt_map_empty(), x = yon_rt_xrelmap_empty(), l = yon_rt_list_empty(0);
    for (int k = 0; k < n; k++) {
        m = yon_rt_map_put(m, k, 3.0 * k);
        x = yon_rt_xrelmap_set(x, k, 3.0 * k);
        l = yon_rt_list_cons(3.0 * k, l);
    }
    bench("HashMap", R_MAP, m, n, yon_rt_map_size, yon_rt_map_value);
    bench("XRelMap", R_XMAP, x, n, yon_rt_xrelmap_size, yon_rt_xrelmap_value);
    bench("List", R_LIST, l, n, yon_rt_list_length, NULL);
    return 0;
}
