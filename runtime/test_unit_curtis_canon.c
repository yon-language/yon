/* test_unit_curtis_canon.c — oracle for the precomputed Curtis canonicalisation
 * LUTs (yon_curtis_canon.c / .o).
 *
 * These two build-time tables (yon_curtis_canon.h) key on the MPHF index of a
 * type-2 vector and give its class representative for the FIXED Curtis frame:
 *
 *   YON_CURTIS_CANON_IDX[i] = MPHF index of the representative (the SMALLEST
 *                             MPHF index) of the relational class of the type-2
 *                             vector at slot i.                        (XRelSet)
 *   YON_CURTIS_CANON_XC[i]  = the xcoord of that same representative,
 *                             i.e. unindex(IDX[i]).                    (XRelMap)
 *
 * The runtime binds XRelSet->canon at these LUTs and reduces every vector to its
 * class rep before touching the bitmap / arena (yon_rt.c:4587, 4746). The map
 * canon(x) is therefore XC[index(x)] and the set canon(idx) is IDX[idx].
 *
 * PUBLIC SYMBOLS UNDER TEST (yon_curtis_canon.h):
 *   extern const uint32_t YON_CURTIS_CANON_XC[196560];
 *   extern const uint32_t YON_CURTIS_CANON_IDX[196560];
 * cross-checked against the MPHF bijection (yon_mphf_index / yon_mphf_unindex).
 *
 * WHAT THIS ASSERTS
 *   A. Range: IDX[i] in [0,196560) for all i.
 *   B. Minimality: IDX[i] <= i (the representative is the smallest idx in the
 *      class, and i belongs to its own class).
 *   C. IDEMPOTENCE (the headline invariant, canon(canon(x)) == canon(x)):
 *      IDX[IDX[i]] == IDX[i] for all i — every representative is a fixed point.
 *   D. Boundary vectors: IDX[0] == 0 (global-minimum slot is its own rep);
 *      slot N-1 has a valid, minimal, idempotent representative.
 *   E. XC/IDX coupling via MPHF: index(XC[i]) == IDX[i] and XC[i] ==
 *      unindex(IDX[i]) for all i; every XC[i] is a valid type-2 xcoord.
 *   F. XC idempotence: XC[IDX[i]] == XC[i] (the map form of C).
 *   G. Partition sanity: the number of distinct representatives (fixed points)
 *      is a nontrivial class count, 0 < classes < N, and equals the number of
 *      values actually reached in IDX[].
 *
 * Marker on success: "CURTIS_CANON: PASS".
 */

#include "yon_curtis_canon.h"
#include "xleech2_mphf.h"
#include "xleech2_coord.h"
#include "leech_theta.h"
#include <stdio.h>
#include <stdint.h>

static int fails = 0;
static void check(int ok, const char *what) {
    printf("  %-58s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

#define N YON_LEECH_TYPE2_COUNT  /* 196560 */

/* Marks which slots appear as a representative value in IDX[]. */
static uint8_t is_value[N];

int main(void) {
    printf("=== Curtis canonicalisation LUT oracle (%u type-2 slots) ===\n", N);

    /* A + B + C: single sweep over the IDX table. */
    {
        int range_ok = 1, minimal_ok = 1, idem_ok = 1;
        uint32_t fixed_points = 0;
        for (uint32_t i = 0; i < N; i++) {
            uint32_t r = YON_CURTIS_CANON_IDX[i];
            if (r >= N) { range_ok = 0; continue; }
            if (r > i) minimal_ok = 0;                 /* rep is the smallest idx */
            if (YON_CURTIS_CANON_IDX[r] != r) idem_ok = 0;   /* rep is a fixed point */
            if (r == i) fixed_points++;
            is_value[r] = 1;
        }
        check(range_ok,   "IDX[i] in [0,196560) for all i");
        check(minimal_ok, "IDX[i] <= i for all i (representative is minimal)");
        check(idem_ok,    "IDX[IDX[i]] == IDX[i] for all i (idempotence)");

        /* G: partition sanity. */
        uint32_t distinct_values = 0;
        for (uint32_t i = 0; i < N; i++) if (is_value[i]) distinct_values++;
        printf("    (distinct representatives / classes = %u ; fixed points = %u)\n",
               distinct_values, fixed_points);
        check(distinct_values == fixed_points,
              "distinct IDX values == fixed-point count (values ARE the reps)");
        check(fixed_points > 0 && fixed_points < N,
              "nontrivial partition: 0 < classes < N");
        /* Every value reached in IDX must itself be a fixed point. */
        int values_are_fixed = 1;
        for (uint32_t i = 0; i < N; i++)
            if (is_value[i] && YON_CURTIS_CANON_IDX[i] != i) values_are_fixed = 0;
        check(values_are_fixed, "every representative value is a fixed point");
    }

    /* D: boundary vectors. */
    {
        check(YON_CURTIS_CANON_IDX[0] == 0, "IDX[0] == 0 (global-min slot is its own rep)");
        uint32_t rL = YON_CURTIS_CANON_IDX[N - 1];
        check(rL < N && rL <= N - 1, "IDX[N-1] valid and minimal");
        check(YON_CURTIS_CANON_IDX[rL] == rL, "IDX[N-1] representative is idempotent");
    }

    /* E: XC/IDX coupling through the MPHF bijection (full sweep). */
    {
        int idx_match = 1, xc_match = 1, xc_type2 = 1;
        for (uint32_t i = 0; i < N; i++) {
            uint32_t r   = YON_CURTIS_CANON_IDX[i];
            uint32_t xc  = YON_CURTIS_CANON_XC[i];
            if (!yon_xcoord_is_type2((yon_xcoord_t)xc)) { xc_type2 = 0; }
            if (yon_mphf_index((yon_xcoord_t)xc) != r) idx_match = 0;
            if (xc != (uint32_t)yon_mphf_unindex(r))    xc_match = 0;
        }
        check(xc_type2,  "every XC[i] is a valid type-2 xcoord");
        check(idx_match, "index(XC[i]) == IDX[i] for all i (XC/IDX coupled)");
        check(xc_match,  "XC[i] == unindex(IDX[i]) for all i");
    }

    /* F: XC idempotence — the map form of the invariant. */
    {
        int xc_idem = 1;
        for (uint32_t i = 0; i < N; i++) {
            uint32_t r = YON_CURTIS_CANON_IDX[i];
            if (YON_CURTIS_CANON_XC[r] != YON_CURTIS_CANON_XC[i]) xc_idem = 0;
        }
        check(xc_idem, "XC[IDX[i]] == XC[i] for all i (map canon idempotent)");
    }

    /* Concrete map-form idempotence on sampled vectors: canon(canon(x))==canon(x)
     * where canon(x) = XC[index(x)] for a type-2 x. */
    {
        int ok = 1;
        for (uint32_t j = 0; j < N; j += 5003 /* prime stride */) {
            yon_xcoord_t x = yon_mphf_unindex(j);
            uint32_t c1 = YON_CURTIS_CANON_XC[yon_mphf_index(x)];
            uint32_t c2 = YON_CURTIS_CANON_XC[yon_mphf_index((yon_xcoord_t)c1)];
            if (c1 != c2) ok = 0;
        }
        check(ok, "canon(canon(x)) == canon(x) on sampled vectors (map form)");
    }

    if (fails == 0) { printf("CURTIS_CANON: PASS\n"); return 0; }
    printf("CURTIS_CANON: FAIL (%d)\n", fails);
    return 1;
}
