/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* yon_test_quantizer.c — permanent guard for the closest type-2 quantizer.
 * =========================================================================
 *
 * WHAT THIS PROVES
 *
 * yon_leech2_quantize(q) maps an arbitrary q in R^24 to the nearest minimal
 * (norm-4) Leech vector: the type-2 maximising <q,v>. It does so in O(1) by
 * solving the argmax inside each of the three minimal shapes (4^2, 2^8,
 * 3.1^23) and taking the best, instead of scanning the 196560 vectors. On
 * every Voronoi boundary (score ties, within QZ_EPS) the address is made
 * deterministic by the minimum-MPHF-index rule, enforced across shapes AND
 * across the full sign orbit on spent (q_k = 0) coordinates.
 *
 * This guard pins the runtime function against the brute-force oracle that
 * scans all 196560 vectors with the identical tie-break, on three regimes:
 *   A) continuous q       — generic interior of the Voronoi cells;
 *   B) integer q in [-2,2] — frequent exact score ties (tie-break stress);
 *   C) ultra-sparse q      — large free-sign orbits on spent coordinates.
 * Agreement is on the exact MPHF index (the vector identity), not just the
 * score. A single error in any shape's argmax, reconstruction, or tie-break
 * would desync the runtime quantizer from the oracle and fail here.
 *
 * The oracle precomputes the 196560 decoded coordinate vectors once, so each
 * query is pure arithmetic. Seeds are fixed for reproducibility. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "xleech2_coord.h"
#include "xleech2_mphf.h"

/* yon_rt.o (in the regression RTSET) references this; stub it out. */
double __yon_dispatch(double a, double b, double c);
double __yon_dispatch(double a, double b, double c) { (void)a; (void)b; (void)c; return 0.0; }

#define N 196560u
#define EPS 1e-9

static int8_t (*COORDS)[24];
static int g_fail = 0;

static void precompute(void) {
    COORDS = malloc((size_t)N * 24);
    for (uint32_t idx = 0; idx < N; idx++) {
        uint32_t v = yon_mphf_unindex(idx) & 0x1FFFFFFu;
        int16_t c[24];
        if (yon_xcoord_to_int24(v, c)) { for (int k = 0; k < 24; k++) COORDS[idx][k] = 0; }
        else for (int k = 0; k < 24; k++) COORDS[idx][k] = (int8_t)c[k];
    }
}
/* brute oracle: min MPHF index among the score-maximal type-2 (tie-break). */
static uint32_t brute_idx_tb(const double q[24], int *cnt_out) {
    double best = -1e30;
    for (uint32_t idx = 0; idx < N; idx++) { double s = 0; const int8_t *c = COORDS[idx];
        for (int k = 0; k < 24; k++) s += q[k] * (double)c[k]; if (s > best) best = s; }
    int cnt = 0; uint32_t first = 0xFFFFFFFFu;
    for (uint32_t idx = 0; idx < N; idx++) { double s = 0; const int8_t *c = COORDS[idx];
        for (int k = 0; k < 24; k++) s += q[k] * (double)c[k];
        if (s >= best - EPS) { if (first == 0xFFFFFFFFu) first = idx; cnt++; } }
    if (cnt_out) *cnt_out = cnt; return first;
}
static void report(const char *name, long ok, long bad, long ties) {
    int pass = (bad == 0);
    if (!pass) g_fail = 1;
    printf("  [%s] %s: ok=%ld bad=%ld (queries with real ties: %ld)\n",
           pass ? "PASS" : "FAIL", name, ok, bad, ties);
}

int main(void) {
    precompute();
    printf("Quantizer guard: yon_leech2_quantize vs brute(196560) with MPHF-min tie-break\n");

    /* A) continuous q */
    { uint32_t a = 90210u; long ok = 0, bad = 0;
      for (int t = 0; t < 1000; t++) { double q[24];
          for (int k = 0; k < 24; k++) { a = a*1664525u+1013904223u; q[k] = ((double)(a>>8)/(double)(1u<<24))*2.0-1.0; }
          uint32_t qi = yon_mphf_index(yon_leech2_quantize(q) & 0x1FFFFFFu);
          uint32_t bi = brute_idx_tb(q, NULL);
          if (qi == bi) ok++; else bad++; }
      report("continuous", ok, bad, 0); }

    /* B) integer q in [-2,2] — heavy exact ties */
    { uint32_t a = 13579u; long ok = 0, bad = 0, ties = 0;
      for (int t = 0; t < 3000; t++) { double q[24];
          for (int k = 0; k < 24; k++) { a = a*1664525u+1013904223u; q[k] = (double)((int)((a>>8)%5u)-2); }
          int cnt; uint32_t bi = brute_idx_tb(q, &cnt);
          uint32_t qi = yon_mphf_index(yon_leech2_quantize(q) & 0x1FFFFFFu);
          if (cnt > 1) ties++; if (qi == bi) ok++; else bad++; }
      report("integer", ok, bad, ties); }

    /* C) ultra-sparse q (2..6 nonzero coords) — large free-sign orbits */
    { uint32_t a = 24680u; long ok = 0, bad = 0, ties = 0;
      for (int t = 0; t < 1000; t++) { double q[24]; for (int k = 0; k < 24; k++) q[k] = 0.0;
          int m = 2 + (int)((a>>16)%5u); a = a*1664525u+1013904223u;
          for (int r = 0; r < m; r++) { a = a*1664525u+1013904223u; int pos = (int)((a>>8)%24u);
              a = a*1664525u+1013904223u; double val = (double)((int)((a>>8)%5u)-2); if (val == 0) val = 1; q[pos] = val; }
          int cnt; uint32_t bi = brute_idx_tb(q, &cnt);
          uint32_t qi = yon_mphf_index(yon_leech2_quantize(q) & 0x1FFFFFFu);
          if (cnt > 1) ties++; if (qi == bi) ok++; else bad++; }
      report("ultra-sparse", ok, bad, ties); }

    free(COORDS);
    printf("%s\n", g_fail ? "QUANTIZER: FAIL" : "QUANTIZER: PASS");
    return g_fail;
}
