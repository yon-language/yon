/* xleech2_coord.c — implementation of the native XLeech2 type. */

#include "xleech2_coord.h"
#include <pthread.h>
#include "mmgroup_generators.h"
#include "mat24_functions.h"

/* Mutex shared with xleech2_move.c to serialize calls into libmmgroup.
 * libmmgroup is not thread-safe by default. Defined in xleech2_move.c. */
extern pthread_mutex_t mmgroup_mutex;

int yon_xcoord_type(yon_xcoord_t v) {
    /* Bit 25+ should always be 0 for valid encoding */
    if (v & ~YON_XCOORD_VALID_MASK) return -1;
    pthread_mutex_lock(&mmgroup_mutex);
    int t = (int)gen_leech2_type(v);
    pthread_mutex_unlock(&mmgroup_mutex);
    return t;
}

bool yon_xcoord_is_type2(yon_xcoord_t v) {
    return yon_xcoord_type(v) == 2;
}

/* Decode an XLeech2 type-2 vector into its 24 integer coordinates.
 *
 * Strategy (via b): convert the leech2 vector to mmgroup's "short vector"
 * encoding (sign<<15 | box<<16 | code), where the box identifies the shape and
 * the code carries positions and signs with the Parker-loop theta already
 * applied. We then materialise the three minimal-vector shapes directly:
 *   4^2   (box 1, code<1536):  +-4 on two positions, relative sign from code>=768
 *   2^8   (box 1 high, 2, 3):  +-2 on an octad, negatives = XOR of the four
 *                              suboctad-indexed octad elements
 *   3.1^23 (box 4, 5):         +-1 from the Golay codeword, the 3 at code&31
 *                              carrying the opposite sign (the (-+3) of (∓3)(±1)^23)
 * The global sign is bit 15 of the short.
 *
 * Coordinates are in {-4,-3,-2,-1,0,1,2,3,4}. The Leech inner product is
 * (sum out_v[i]*out_w[i]) / 8; <v,v> = 4 for every type-2 vector.
 *
 * Validated empirically: norm == 4 for all type-2; <v,-v> == -4; the product
 * distribution N_k for a fixed v0 matches Elkies (N0=93150, N1=47104, N2=4600,
 * N4=1) and is symmetric; the holonomy sgn<u,v>*sgn<v,w>*sgn<w,u> is
 * Co0-invariant. The per-edge sign is gauge (not Co0-invariant on its own) by
 * design; the holonomy cancels the gauge.
 *
 * Returns 0 on success, -1 if v is not a decodable type-2 short vector. */
int yon_xcoord_to_int24(yon_xcoord_t v, int16_t out[24]) {
    for (int k = 0; k < 24; k++) out[k] = 0;
    if (v & ~YON_XCOORD_VALID_MASK) return -1;
    uint32_t s = gen_xi_leech_to_short(v & 0x1FFFFFFu);
    uint32_t sign = (s >> 15) & 1u;
    uint32_t box  = (s >> 16) & 7u;
    uint32_t code = s & 0x7FFFu;

    if (box == 1u && code < 1536u) {                 /* 4^2 */
        uint32_t gf = code >= 768u;
        uint32_t c  = code - (gf ? 768u : 0u);
        uint32_t i = c >> 5, j = c & 31u;
        out[i] = 4;
        out[j] = gf ? -4 : 4;
    } else if ((box == 1u && code >= 1536u && code < 2496u)
               || box == 2u || box == 3u) {          /* 2^8 */
        uint32_t oi = box == 2u ? code + 960u
                    : box == 3u ? code + 24000u
                                : code - 1536u;
        const uint8_t *po = MAT24_OCTAD_ELEMENT_TABLE + ((oi >> 6) << 3);
        const uint8_t *ps = MAT24_OCTAD_INDEX_TABLE   + ((oi & 0x3fu) << 2);
        uint32_t neg = (1u << po[ps[0]]) ^ (1u << po[ps[1]])
                     ^ (1u << po[ps[2]]) ^ (1u << po[ps[3]]);
        uint32_t oct = 0;
        for (int e = 0; e < 8; e++) oct |= (1u << po[e]);
        for (int k = 0; k < 24; k++)
            if (oct & (1u << k)) out[k] = ((neg >> k) & 1u) ? -2 : 2;
    } else if (box == 4u || box == 5u) {             /* 3.1^23 */
        uint32_t c2 = box == 5u ? code + 0x8000u : code;
        uint32_t p3 = c2 & 31u;
        uint32_t gc = (c2 >> 5) & 0x7ffu;
        uint32_t cocode = mat24_vect_to_cocode(1u << p3);
        uint32_t w = ((MAT24_THETA_TABLE[gc] >> 12) & 1u) ^ (gc & cocode);
        w = mat24_def_parity12(w);
        gc ^= w << 11;
        uint32_t gv = mat24_gcode_to_vect(gc) & 0xFFFFFFu;
        for (int k = 0; k < 24; k++) out[k] = ((gv >> k) & 1u) ? -1 : 1;
        out[p3] = (int16_t)(-out[p3] * 3);
    } else {
        return -1;
    }
    if (sign) for (int k = 0; k < 24; k++) out[k] = (int16_t)(-out[k]);
    return 0;
}

/* Real Leech inner product <v,w> in {0,+-1,+-2,+-4}, or a large sentinel if
 * either vector is not a decodable type-2. The per-edge sign is gauge; use the
 * triangle holonomy for a Co0-invariant signed quantity. */
int yon_leech2_signed_product(yon_xcoord_t v, yon_xcoord_t w) {
    int16_t a[24], b[24];
    if (yon_xcoord_to_int24(v, a) || yon_xcoord_to_int24(w, b)) return 0x7fffffff;
    int s = 0;
    for (int k = 0; k < 24; k++) s += (int)a[k] * (int)b[k];
    return s / 8;
}
