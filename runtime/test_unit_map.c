/* test_unit_map.c — oracle for the yon_rt_map_* family (open-addressed HashMap,
 * yon_rt.c:3166+). Keys and values are both f64; entries live in xheap slots,
 * the directory is an arena strip of slot ids with linear probing.
 *
 * Signatures grounded on the header / impl:
 *   yon_rt.h:554  double yon_rt_map_empty(void);
 *                 -> id+1 (0.0 = pool/arena exhausted; +1 keeps 0 as the
 *                    "empty/invalid" sentinel, yon_rt.c:3190).
 *   yon_rt.h:556  double yon_rt_map_put(double map_id, double key, double value);
 *                 -> map_id. Lazy-inits if map_id<0.5. Same key overwrites the
 *                    value (yon_rt.c:3275), size unchanged on update.
 *   yon_rt.h:558  double yon_rt_map_get(double map_id, double key);
 *                 -> stored value; MISS sentinel is 0.0 (empty slot or bad id,
 *                    yon_rt.c:3294/3289). NOTE: a stored value of 0.0 is
 *                    indistinguishable from a miss here — so presence is probed
 *                    with map_contains, and get is checked with NON-ZERO values.
 *   yon_rt.h:560  double yon_rt_map_contains(double map_id, double key);
 *                 -> 1.0 if present, 0.0 otherwise / bad id (yon_rt.c:3303).
 *   yon_rt.h:562  double yon_rt_map_size(double map_id);
 *                 -> n_entries; bad id -> 0.0 (yon_rt.c:3320).
 *
 * Marker on success: "MAP: PASS".
 */

#include "yon_rt.h"
#include <stdio.h>

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-48s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

int main(void) {
    printf("=== yon_rt_map_* oracle ===\n");

    /* empty -> valid id, size 0. */
    double m = yon_rt_map_empty();
    check(m != 0.0, "empty() -> valid id (!= 0.0 sentinel)");
    check(yon_rt_map_size(m) == 0.0, "fresh map size == 0");

    /* put then get returns the value (non-zero so it is distinct from miss). */
    m = yon_rt_map_put(m, 10.0, 111.0);
    m = yon_rt_map_put(m, 20.0, 222.0);
    m = yon_rt_map_put(m, 30.0, 333.0);
    check(yon_rt_map_get(m, 10.0) == 111.0, "get(10) == 111 (put then get)");
    check(yon_rt_map_get(m, 20.0) == 222.0, "get(20) == 222");
    check(yon_rt_map_get(m, 30.0) == 333.0, "get(30) == 333");
    check(yon_rt_map_size(m) == 3.0, "size after 3 distinct puts == 3");

    /* contains: true for a present key, false for an absent one. */
    check(yon_rt_map_contains(m, 20.0) == 1.0, "contains(20) -> 1.0 (present)");
    check(yon_rt_map_contains(m, 99.0) == 0.0, "contains(99) -> 0.0 (absent)");

    /* get of an absent key -> the miss sentinel 0.0. */
    check(yon_rt_map_get(m, 99.0) == 0.0, "get(absent) -> 0.0 (miss sentinel)");

    /* add same key twice -> size stays, value updates (overwrite path
     * yon_rt.c:3275). */
    {
        double before = yon_rt_map_size(m);
        m = yon_rt_map_put(m, 20.0, 999.0);
        check(yon_rt_map_size(m) == before, "re-put existing key: size unchanged");
        check(yon_rt_map_get(m, 20.0) == 999.0, "re-put existing key: value updated");
    }

    /* a stored value can legitimately be 0.0: contains still reports presence
     * even though get returns the miss-shaped 0.0 (documents the sentinel). */
    {
        m = yon_rt_map_put(m, 40.0, 0.0);
        check(yon_rt_map_contains(m, 40.0) == 1.0,
              "contains(key->0.0 value) -> 1.0 (presence via contains)");
        check(yon_rt_map_get(m, 40.0) == 0.0,
              "get(key->0.0 value) == 0.0 (value == miss sentinel)");
    }

    /* negative-key handling: f64 keys are hashed by bit pattern, so distinct
     * doubles are distinct keys including negatives and fractions. */
    {
        m = yon_rt_map_put(m, -7.5, 55.0);
        check(yon_rt_map_get(m, -7.5) == 55.0, "get(-7.5) == 55 (f64 key)");
        check(yon_rt_map_contains(m, -7.5) == 1.0, "contains(-7.5) -> 1.0");
    }

    /* wild / invalid map id -> defined zeros, no crash. */
    check(yon_rt_map_get(0.0, 10.0) == 0.0, "get on invalid id -> 0.0");
    check(yon_rt_map_contains(0.0, 10.0) == 0.0, "contains on invalid id -> 0.0");
    check(yon_rt_map_size(0.0) == 0.0, "size on invalid id -> 0.0");
    check(yon_rt_map_get(1e9, 10.0) == 0.0, "get on huge bogus id -> 0.0");

    /* growth under load: insert enough distinct keys to force at least one
     * rehash (DIR_INIT growth at 70% load, yon_rt.c:3257) and confirm every
     * value survives the rehash. */
    {
        double g = yon_rt_map_empty();
        int N = 200;
        for (int i = 0; i < N; i++)
            g = yon_rt_map_put(g, (double)(1000 + i), (double)(i + 1));
        int ok = (yon_rt_map_size(g) == (double)N);
        for (int i = 0; i < N; i++)
            if (yon_rt_map_get(g, (double)(1000 + i)) != (double)(i + 1)) ok = 0;
        check(ok, "200 distinct keys survive rehash (get == value, size == 200)");
    }

    if (fails == 0) {
        printf("MAP: PASS\n");
        return 0;
    }
    printf("MAP: FAIL (%d)\n", fails);
    return 1;
}
