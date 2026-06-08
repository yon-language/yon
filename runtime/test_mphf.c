/* test_mphf.c — the C recheck of the XLeech2 minimal-perfect-hash bijection,
 * referenced by xleech2_mphf.h. Exhaustive over the whole type-2 shell.
 *
 * Claim under test: h : {type-2 xcoord} <-> [0, 196560) is a perfect bijection
 * (zero collisions, full cover, 100% round-trip), with no tables of our own.
 *
 * Build (from runtime/, objects already compiled):
 *   cc -std=c11 -D_DARWIN_C_SOURCE -O2 -I. -Ivendor/mmgroup \
 *      test_mphf.c xleech2_coord.o xleech2_mphf.o xleech2_heap.o \
 *      vendor/mmgroup/*.o -lm -lpthread -o test_mphf
 *   ./test_mphf        # exit 0 iff the bijection holds
 *
 * Method: for every idx in [0, 196560), unindex it to a vector, require the
 * vector to be type-2, require index(vector) == idx (round-trip), and require
 * each idx to be hit exactly once (no collisions, full cover). Round-trip over
 * the whole range establishes injectivity of unindex, hence the bijection.
 */
#include "xleech2_mphf.h"
#include "xleech2_coord.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    static unsigned char seen[196560];
    memset(seen, 0, sizeof(seen));
    long ok = 0, invalid = 0, not_type2 = 0, rt_fail = 0, dup = 0;

    for (unsigned idx = 0; idx < 196560u; idx++) {
        yon_xcoord_t v = yon_mphf_unindex(idx);
        if (v == YON_XCOORD_INVALID)         { invalid++;   continue; }
        if (!yon_xcoord_is_type2(v))         { not_type2++; continue; }
        unsigned back = yon_mphf_index(v);
        if (back == YON_MPHF_INVALID || back >= 196560u || back != idx)
                                             { rt_fail++;   continue; }
        if (seen[back])                      { dup++;       continue; }
        seen[back] = 1; ok++;
    }
    long covered = 0;
    for (unsigned i = 0; i < 196560u; i++) covered += seen[i];

    printf("idx range        : [0, 196560)\n");
    printf("round-trip ok    : %ld / 196560\n", ok);
    printf("distinct covered : %ld / 196560\n", covered);
    printf("invalid          : %ld\n", invalid);
    printf("not type-2       : %ld\n", not_type2);
    printf("round-trip fail  : %ld\n", rt_fail);
    printf("collisions (dup) : %ld\n", dup);

    int bijection = (ok == 196560 && covered == 196560 &&
                     invalid == 0 && not_type2 == 0 && rt_fail == 0 && dup == 0);
    printf("%s\n", bijection
        ? "BIJECTION VERIFIED (zero collisions, full cover, 100% round-trip)"
        : "NOT A BIJECTION");
    return bijection ? 0 : 1;
}
