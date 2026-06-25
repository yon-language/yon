/* test_unit_voyagerlist.c — oracle for the yon_rt_voyagerlist_* family
 * (yon_rt.c:6021+). The family wraps the Golay (24,12,8) code: a 12-bit datum
 * is "sealed" into a 24-bit codeword, and "opened" back via syndrome decoding,
 * which corrects up to 3 bit errors.
 *
 * Pure-function trio (in yon_rt.h):
 *   yon_rt.h:789  double yon_rt_voyagerlist_seal(double data12);
 *                 -> mat24_gcode_to_vect(data & 0xFFF) (yon_rt.c:6021).
 *   yon_rt.h:794  double yon_rt_voyagerlist_open(double codeword24);
 *                 -> mat24_vect_to_gcode(cw ^ syndrome(cw)) (yon_rt.c:6031).
 *                    open(seal(d)) == d for d < 4096 (syndrome of a true
 *                    codeword is 0).
 *   yon_rt.h:799  double yon_rt_voyagerlist_corrupt(double codeword24, double n_bits);
 *                 -> flips n_bits DISTINCT bits (clamped to [0,24]) (yon_rt.c:6042).
 *
 * Collection API (non-static in yon_rt.c, NOT in the header -> declared extern):
 *   yon_rt.c:6104 double yon_rt_voyagerlist_empty(void);
 *                 -> id+1 (0.0 = pool/arena exhausted; +1 keeps 0 as the sentinel).
 *   yon_rt.c:6135 double yon_rt_voyagerlist_append(double vl_id, double data12);
 *                 -> auto-seals data12; lazy-inits if vl_id<0.5; returns vl_id.
 *   yon_rt.c:6172 double yon_rt_voyagerlist_get(double vl_id, double idx);
 *                 -> auto-opens (with error correction); idx>=size or bad id -> 0.0.
 *   yon_rt.c:6189 double yon_rt_voyagerlist_size(double vl_id);
 *                 -> n_entries; bad id -> 0.0.
 *   yon_rt.c:6196 double yon_rt_voyagerlist_corrupt_at(double vl_id, double idx, double n_bits);
 *                 -> in-place corrupt of codeword idx; idx>=size or bad id ->
 *                    returns vl_id unchanged, NO OOB write (yon_rt.c:6200).
 *
 * Marker on success: "VOYAGERLIST: PASS".
 */

#include "yon_rt.h"
#include <stdio.h>

/* Collection functions: non-static in yon_rt.c, no header declarations. */
extern double yon_rt_voyagerlist_empty(void);
extern double yon_rt_voyagerlist_append(double vl_id, double data12);
extern double yon_rt_voyagerlist_get(double vl_id, double idx);
extern double yon_rt_voyagerlist_size(double vl_id);
extern double yon_rt_voyagerlist_corrupt_at(double vl_id, double idx, double n_bits);

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-46s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

int main(void) {
    printf("=== yon_rt_voyagerlist_* oracle ===\n");

    /* 1) seal/open round-trips the 12-bit datum exactly for several values. */
    {
        int ok = 1;
        double samples[] = { 0.0, 1.0, 42.0, 0xABC, 0xFFF };
        for (int i = 0; i < 5; i++) {
            double cw = yon_rt_voyagerlist_seal(samples[i]);
            double back = yon_rt_voyagerlist_open(cw);
            if (back != samples[i]) ok = 0;
        }
        check(ok, "seal->open round-trips data12 exactly");
    }

    /* 1b) data >= 4096 is clipped to 12 bits before sealing (yon_rt.c:6024). */
    {
        double back = yon_rt_voyagerlist_open(yon_rt_voyagerlist_seal(4096.0 + 42.0));
        check(back == 42.0, "seal clips data to 12 bits (4096+42 -> 42)");
    }

    /* 2) Golay error correction: corrupt 1 or 2 bits of a codeword, open still
     *    recovers the original datum (distance 8 corrects up to 3 errors). */
    {
        int ok = 1;
        double data = 0x5A5; /* arbitrary 12-bit datum */
        double cw = yon_rt_voyagerlist_seal(data);
        for (int nb = 1; nb <= 2; nb++) {
            double bad = yon_rt_voyagerlist_corrupt(cw, (double)nb);
            if (bad == cw && nb > 0) ok = 0;          /* must have actually flipped */
            double recovered = yon_rt_voyagerlist_open(bad);
            if (recovered != data) ok = 0;             /* must still decode to data */
        }
        check(ok, "corrupt 1-2 bits -> open still recovers datum");
    }

    /* 3) collection: empty -> valid id (non-zero sentinel). */
    double vl = yon_rt_voyagerlist_empty();
    check(vl != 0.0, "empty() -> valid id (!= 0.0 sentinel)");
    check(yon_rt_voyagerlist_size(vl) == 0.0, "fresh list size == 0");

    /* 4) append auto-seals; get auto-opens; size tracks count. */
    {
        double data[] = { 7.0, 1234.0, 0.0, 0xFFF };
        for (int i = 0; i < 4; i++) vl = yon_rt_voyagerlist_append(vl, data[i]);
        check(yon_rt_voyagerlist_size(vl) == 4.0, "size after 4 appends == 4");
        int ok = 1;
        for (int i = 0; i < 4; i++)
            if (yon_rt_voyagerlist_get(vl, (double)i) != data[i]) ok = 0;
        check(ok, "get(i) returns the appended datum (seal/open round-trip)");
    }

    /* 5) get out-of-range index -> defined sentinel 0.0, no OOB read. */
    {
        double a = yon_rt_voyagerlist_get(vl, 4.0);      /* == size */
        double b = yon_rt_voyagerlist_get(vl, 1000.0);   /* far past */
        check(a == 0.0 && b == 0.0, "get(idx >= size) -> 0.0 (no OOB)");
    }

    /* 6) get / size on a wild (invalid) list id -> 0.0, no crash. */
    {
        double g = yon_rt_voyagerlist_get(0.0, 0.0);
        double gbig = yon_rt_voyagerlist_get(1e9, 0.0);
        double sz = yon_rt_voyagerlist_size(0.0);
        check(g == 0.0 && gbig == 0.0 && sz == 0.0,
              "wild list id -> get/size 0.0");
    }

    /* 7) corrupt_at on a real index: 1-bit flip is still error-corrected on get. */
    {
        /* element 0 was 7.0; flip 1 bit -> get must still recover 7.0. */
        (void)yon_rt_voyagerlist_corrupt_at(vl, 0.0, 1.0);
        check(yon_rt_voyagerlist_get(vl, 0.0) == 7.0,
              "corrupt_at(0,1 bit) -> get still recovers 7 (Golay)");
    }

    /* 8) corrupt_at with idx >= size -> bounds-safe (returns vl, no OOB write).
     *    Verify by confirming the list is untouched (size + element still read). */
    {
        double before_sz = yon_rt_voyagerlist_size(vl);
        double r1 = yon_rt_voyagerlist_corrupt_at(vl, 4.0, 3.0);    /* == size */
        double r2 = yon_rt_voyagerlist_corrupt_at(vl, 1000.0, 3.0); /* far past */
        double r3 = yon_rt_voyagerlist_corrupt_at(0.0, 0.0, 3.0);   /* bad id */
        int ok = (r1 == vl) && (r2 == vl) && (r3 == 0.0)
               && (yon_rt_voyagerlist_size(vl) == before_sz)
               && (yon_rt_voyagerlist_get(vl, 1.0) == 1234.0);
        check(ok, "corrupt_at(idx>=size / bad id) -> bounds-safe no-op");
    }

    if (fails == 0) {
        printf("VOYAGERLIST: PASS\n");
        return 0;
    }
    printf("VOYAGERLIST: FAIL (%d)\n", fails);
    return 1;
}
