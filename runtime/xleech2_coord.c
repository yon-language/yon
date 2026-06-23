/* xleech2_coord.c — implementation of the native XLeech2 type. */

#include "xleech2_coord.h"
#include <pthread.h>
#include <math.h>
#include "mmgroup_generators.h"
#include "mat24_functions.h"
#include "xleech2_mphf.h"

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
        /* j is a 5-bit field (0..31) but out[] has 24 lanes: a valid type-2
         * short always has j<24, yet we make local soundness independent of
         * that upstream invariant by failing closed on the function's own
         * "-1 = not decodable" contract rather than risking an OOB write. */
        if (i >= 24u || j >= 24u) return -1;
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

/* ======================================================================
 * Closest type-2 quantizer:  q in R^24  ->  nearest minimal (norm-4) vector.
 *
 * All 196560 type-2 vectors lie on the sphere of norm 4, so "closest to q"
 * is equivalent to "maximises <q,v>" (since |q-v|^2 = |q|^2 + 4 - 2<q,v>).
 * The minimal shell splits into three shapes; the best candidate inside each
 * is a closed O(1) sub-problem, and the winner is their max:
 *
 *   4^2     : the two coordinates of largest |q|, signs from q.
 *   2^8     : the octad (of 759) of largest sum|q|, signs from q, with a
 *             parity fix (#(-2) must be even) paid on the smallest |q|.
 *   3.1^23  : a Golay codeword for the +-1 signs (soft-decoded over the 4096
 *             codewords) plus the position of the +-3, which carries the
 *             sign opposite to its codeword bit.
 *
 * Reconstruction back to an xcoord goes through mmgroup's short encoding
 * (gen_xi_short_to_leech), with the relative signs built into the short and
 * the global sign fixed afterwards by requiring <q,v> >= 0 (qz_signfix).
 *
 * The address is deterministic on every Voronoi boundary: at equal score
 * (within QZ_EPS) the type-2 of minimum MPHF index wins. This is enforced not
 * just between shapes but across the full sign orbit on coordinates where
 * q_k = 0 (spent coordinates), which carry a free sign and so generate a set
 * of equidistant winners. The 4^2 (free relative sign) and 2^8 (parity-even
 * sign subsets of the spent coords) enumerate that orbit explicitly; the
 * 3.1^23 loop spans it already, since a free-sign variant is another codeword
 * of equal score.
 *
 * Validated against brute force over all 196560 vectors with the same
 * MPHF-min tie-break: exact vector identity on 3000 continuous queries, on
 * 8000 integer queries (3901 with real ties) and on 1500 ultra-sparse queries
 * (799 with real ties); zero mismatches.
 *
 * Returns the xcoord of the closest type-2, or YON_XCOORD_INVALID if no
 * candidate could be reconstructed (should not occur for finite q).
 * ====================================================================== */
#define QZ_EPS 1e-9

static uint32_t qz_signfix(uint32_t v, const double q[24]) {
    int16_t c[24];
    if (yon_xcoord_to_int24(v, c)) return v;
    double s = 0; for (int k = 0; k < 24; k++) s += q[k] * (double)c[k];
    return (s < 0.0) ? yon_xcoord_negate(v) : v;
}
static uint32_t qz_sub_pattern(int o, int sub) {
    const uint8_t *po = MAT24_OCTAD_ELEMENT_TABLE + (o * 8);
    const uint8_t *ps = MAT24_OCTAD_INDEX_TABLE + ((sub & 0x3f) * 4);
    return (1u << po[ps[0]]) ^ (1u << po[ps[1]]) ^ (1u << po[ps[2]]) ^ (1u << po[ps[3]]);
}
static uint32_t qz_recon_42(const double q[24], int i, int j, uint32_t gf) {
    uint32_t code = (gf ? 768u : 0u) + (uint32_t)i * 32u + (uint32_t)j;
    return qz_signfix(gen_xi_short_to_leech((1u << 16) | code) & 0x1FFFFFFu, q);
}
static uint32_t qz_recon_28(const double q[24], int o, uint32_t mask) {
    uint32_t octmask = 0;
    { const uint8_t *p = MAT24_OCTAD_ELEMENT_TABLE + (o * 8);
      for (int e = 0; e < 8; e++) octmask |= (1u << p[e]); }
    uint32_t comp = octmask ^ mask;        /* suboctad stores the weight<=4 rep */
    int sub = -1;
    for (int s = 0; s < 64; s++) { uint32_t pat = qz_sub_pattern(o, s);
        if (pat == mask || pat == comp) { sub = s; break; } }
    if (sub < 0) return YON_XCOORD_INVALID;
    uint32_t oi = (uint32_t)o * 64u + (uint32_t)sub, box, code;
    if (oi < 960u)        { box = 1; code = oi + 1536u; }
    else if (oi < 24000u) { box = 2; code = oi - 960u; }
    else                  { box = 3; code = oi - 24000u; }
    return qz_signfix(gen_xi_short_to_leech((box << 16) | code) & 0x1FFFFFFu, q);
}
static uint32_t qz_recon_3123(uint32_t gc, int p3) {
    int16_t tgt[24]; uint32_t gv = mat24_gcode_to_vect(gc) & 0xFFFFFFu;
    for (int k = 0; k < 24; k++) tgt[k] = (int16_t)(((gv >> k) & 1u) ? -1 : 1);
    int sp3 = ((gv >> p3) & 1u) ? -1 : 1; tgt[p3] = (int16_t)(-3 * sp3);
    uint32_t code = ((gc & 0x7ffu) << 5) | (uint32_t)p3;
    for (int box = 4; box <= 5; box++) {
        uint32_t v = gen_xi_short_to_leech(((uint32_t)box << 16) | code) & 0x1FFFFFFu;
        int16_t c[24]; if (yon_xcoord_to_int24(v, c)) continue;
        int eq = 1, eqn = 1;
        for (int k = 0; k < 24; k++) { if (c[k] != tgt[k]) eq = 0; if (c[k] != -tgt[k]) eqn = 0; }
        if (eq)  return v;
        if (eqn) return yon_xcoord_negate(v);
    }
    return YON_XCOORD_INVALID;
}
static double qz_max_42(const double q[24]) {
    double m1 = -1, m2 = -1;
    for (int k = 0; k < 24; k++) { double a = fabs(q[k]); if (a > m1) { m2 = m1; m1 = a; } else if (a > m2) m2 = a; }
    return 4.0 * (m1 + m2);
}
static double qz_max_28(const double q[24]) {
    double best = -1e30;
    for (int o = 0; o < 759; o++) { const uint8_t *p = MAT24_OCTAD_ELEMENT_TABLE + (o * 8);
        double sum = 0, mn = 1e30; int neg = 0;
        for (int e = 0; e < 8; e++) { double a = fabs(q[p[e]]); sum += a; if (a < mn) mn = a; if (q[p[e]] < 0) neg++; }
        double sc = 2.0 * sum; if (neg & 1) sc -= 4.0 * mn; if (sc > best) best = sc; }
    return best;
}
static double qz_max_3123(const double q[24]) {
    double best = -1e30;
    for (uint32_t gc = 0; gc < 4096; gc++) { uint32_t gv = mat24_gcode_to_vect(gc) & 0xFFFFFFu;
        double C = 0, minsq = 1e30;
        for (int k = 0; k < 24; k++) { double sk = ((gv >> k) & 1u) ? -1.0 : 1.0; double sq = sk * q[k]; C += sq; if (sq < minsq) minsq = sq; }
        double sc = C - 4.0 * minsq; if (sc > best) best = sc; }
    return best;
}
static void qz_consider(uint32_t x, uint32_t *best_idx, uint32_t *best_x, int *have) {
    if (x == YON_XCOORD_INVALID) return;
    uint32_t idx = yon_mphf_index(x & 0x1FFFFFFu);
    if (!*have || idx < *best_idx) { *best_idx = idx; *best_x = x; *have = 1; }
}
yon_xcoord_t yon_leech2_quantize(const double q[24]) {
    double maxs = qz_max_42(q);
    { double b = qz_max_28(q), c = qz_max_3123(q); if (b > maxs) maxs = b; if (c > maxs) maxs = c; }
    uint32_t best_x = YON_XCOORD_INVALID, best_idx = 0xFFFFFFFFu; int have = 0;

    /* 4^2: pairs reaching the max; enumerate the free relative sign when spent */
    for (int i = 0; i < 24; i++) for (int j = i + 1; j < 24; j++) {
        double sc = 4.0 * (fabs(q[i]) + fabs(q[j]));
        if (sc < maxs - QZ_EPS) continue;
        if (q[i] == 0.0 || q[j] == 0.0) {
            qz_consider(qz_recon_42(q, i, j, 0u), &best_idx, &best_x, &have);
            qz_consider(qz_recon_42(q, i, j, 1u), &best_idx, &best_x, &have);
        } else {
            uint32_t gf = (((q[i] < 0) ? -1 : 1) == ((q[j] < 0) ? -1 : 1)) ? 0u : 1u;
            qz_consider(qz_recon_42(q, i, j, gf), &best_idx, &best_x, &have);
        }
    }
    /* 2^8: octads reaching the max; enumerate the sign orbit over spent coords */
    for (int o = 0; o < 759; o++) {
        const uint8_t *p = MAT24_OCTAD_ELEMENT_TABLE + (o * 8);
        double sum = 0, mn = 1e30; int neg = 0;
        for (int e = 0; e < 8; e++) { double a = fabs(q[p[e]]); sum += a; if (a < mn) mn = a; if (q[p[e]] < 0) neg++; }
        double sc = 2.0 * sum; if (neg & 1) sc -= 4.0 * mn;
        if (sc < maxs - QZ_EPS) continue;
        uint32_t base = 0, Z[8]; int nz = 0, neg_ns = 0;
        for (int e = 0; e < 8; e++) { int k = p[e];
            if (q[k] == 0.0) { Z[nz++] = (uint32_t)k; }
            else if (q[k] < 0) { base |= (1u << k); neg_ns++; } }
        if (nz > 0) {
            for (uint32_t bits = 0; bits < (1u << nz); bits++) {
                if (((__builtin_popcount(bits) + neg_ns) & 1)) continue;
                uint32_t mask = base;
                for (int t = 0; t < nz; t++) if (bits & (1u << t)) mask |= (1u << Z[t]);
                qz_consider(qz_recon_28(q, o, mask), &best_idx, &best_x, &have);
            }
        } else if ((neg_ns & 1) == 0) {
            qz_consider(qz_recon_28(q, o, base), &best_idx, &best_x, &have);
        } else {
            double m2 = 1e30; for (int e = 0; e < 8; e++) { double aa = fabs(q[p[e]]); if (aa < m2) m2 = aa; }
            for (int e = 0; e < 8; e++) if (fabs(q[p[e]]) == m2)
                qz_consider(qz_recon_28(q, o, base ^ (1u << p[e])), &best_idx, &best_x, &have);
        }
    }
    /* 3.1^23: the loop already spans the orbit (free-sign variants are other gc) */
    for (uint32_t gc = 0; gc < 4096; gc++) {
        uint32_t gv = mat24_gcode_to_vect(gc) & 0xFFFFFFu;
        double C = 0, minsq = 1e30;
        for (int k = 0; k < 24; k++) { double sk = ((gv >> k) & 1u) ? -1.0 : 1.0; double sq = sk * q[k]; C += sq; if (sq < minsq) minsq = sq; }
        if (C - 4.0 * minsq < maxs - QZ_EPS) continue;
        for (int p3 = 0; p3 < 24; p3++) {
            double sk = ((gv >> p3) & 1u) ? -1.0 : 1.0; double sc = C - 4.0 * sk * q[p3];
            if (sc >= maxs - QZ_EPS) qz_consider(qz_recon_3123(gc, p3), &best_idx, &best_x, &have);
        }
    }
    return best_x;
}
