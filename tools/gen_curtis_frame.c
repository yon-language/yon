/* gen_curtis_frame.c -- regenerate the Curtis frame constant in
 * runtime/yon_curtis_frame.h. Deterministic; output is reproducible.
 *
 * Build (from runtime/):
 *   cc -std=c11 -O2 -I. -Ivendor/mmgroup ../tools/gen_curtis_frame.c \
 *      xleech2_mphf.c xleech2_coord.c xleech2_heap.c yon_mmap.c \
 *      vendor/mmgroup/*.o -lpthread -lm -o /tmp/gen_curtis_frame
 *
 * Seed: standard MOG octad mat24_octad_to_gcode(0)<<12.
 * Orbit: BFS under the 4 M24 generators as group atoms
 *        gen_leech2_op_atom(v, 0x20000000u | g), keeping subtype-0x22
 *        vectors, capped at YON_XREL_MAX_REFS (26).
 */
#include "mat24_functions.h"
#include "mmgroup_generators.h"
#include "xleech2_mphf.h"
#include "xleech2_coord.h"
#include <stdio.h>
#include <stdint.h>

#define CURTIS_CAP 26

int main(void) {
    const uint32_t gens[4] = { 1000003u, 50000063u, 150000001u, 200000017u };
    uint32_t start = (mat24_octad_to_gcode(0) << 12) & 0x1FFFFFFu;
    static uint8_t seen[1 << 24];
    uint32_t refs[CURTIS_CAP];
    uint32_t q[8192];
    int nr = 0, qh = 0, qt = 0;
    refs[nr++] = start; q[qt++] = start; seen[start & 0xFFFFFF] = 1;
    while (qh < qt && nr < CURTIS_CAP) {
        uint32_t cur = q[qh++];
        for (int g = 0; g < 4 && nr < CURTIS_CAP; g++) {
            uint32_t nx = (uint32_t)gen_leech2_op_atom(cur, 0x20000000u | gens[g]) & 0x1FFFFFFu;
            if (gen_leech2_subtype((uint64_t)nx) != 0x22) continue;
            if (seen[nx & 0xFFFFFF]) continue;
            seen[nx & 0xFFFFFF] = 1;
            refs[nr++] = nx;
            if (qt < 8192) q[qt++] = nx;
        }
    }
    printf("#define YON_CURTIS_FRAME_N %du\n\n", nr);
    printf("static const uint32_t YON_CURTIS_FRAME[YON_CURTIS_FRAME_N] = {\n   ");
    for (int i = 0; i < nr; i++) {
        printf(" 0x%06xu,", refs[i]);
        if ((i & 3) == 3) printf("\n   ");
    }
    printf("\n};\n");
    return 0;
}
