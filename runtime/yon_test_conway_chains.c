/* yon_test_conway_chains.c — monumental permanent test suite for the runtime.
 * =========================================================================
 *
 * WHAT THIS PROVES
 *
 * The XLeech2 coordinate decoder (yon_xcoord_to_int24 / yon_leech2_signed_product)
 * reconstructs the 24 real coordinates of a minimal Leech vector from its 25-bit
 * leech2 encoding, making the real inner product <v,w> in {0,+-1,+-2,+-4}
 * computable. This suite pins that decoder against facts that are *external* and
 * *independent* of our code: the geometry of the Leech lattice Lambda_24 and the
 * orders of the sporadic and classical groups in the Conway chain.
 *
 * The mechanism is the orbit-counting (orbit-stabiliser) theorem. Co0 = 2.Co1
 * acts on the 196560 minimal vectors. Fixing one minimal vector v0 leaves its
 * stabiliser Co2; fixing a type-3 vector x leaves Co3. Both act with small rank
 * on the surrounding minimal vectors, and the orbits are separated exactly by
 * the real inner product. For a single orbit O,
 *
 *        |stabiliser of a point in O| = |G| / |O|.
 *
 * So the *count* of minimal vectors at a given inner product, divided into |Co2|
 * or |Co3|, must land precisely on the order of a known maximal subgroup. It
 * does, to the digit. A single sign error in any of the decoder's three shapes
 * (4^2 / 2^8 / 3.1^23) would corrupt the inner product and break at least one of
 * these identities. This is therefore a stringent, falsifiable certificate that
 * the decoder is correct.
 *
 * THE TWO CHAINS
 *
 *   Co2 = Stab(v0), v0 minimal (type-2). Pairs (v0,w), invariant <v0,w>:
 *     <v0,w>= +-4 : count     1  -> |Co2|/1     = 42305421312000 = Co2
 *     <v0,w>= +-2 : count  4600  -> |Co2|/4600  =     9196830720 = U6(2)
 *     <v0,w>= +-1 : count 47104  -> |Co2|/47104 =      898128000 = McL  (McLaughlin)
 *     <v0,w>=   0 : count 93150  -> |Co2|/93150 =      454164480 = 2^10:M22
 *
 *   Co3 = Stab(x), x type-3 (norm 6, here x = v0 - w0 with <v0,w0>=1). Type-2
 *   vectors v, invariant <x,v> = <v0,v> - <w0,v>:
 *     <x,v>= +-3 : count   552  -> |Co3|/552   =      898128000 = McL
 *     <x,v>= +-2 : count 11178  -> |Co3|/11178 =       44352000 = HS   (Higman-Sims)
 *     <x,v>= +-1 : count 48600  -> |Co3|/48600 =       10200960 = M23
 *     <x,v>=   0 : count 75900  -> |Co3|/75900 =        6531840 = U4(3):2
 *
 * Both columns sum to 196560 (every minimal vector accounted for, none double
 * counted). The inner product, not the leech2 subtype, is the separating
 * invariant: the subtype only sees the shape mod 2 and splits these orbits into
 * non-orbit pieces with non-integer indices. It is precisely the decoder built
 * here that makes these orbits visible.
 *
 * DECODER INVARIANTS (independent of the group theory)
 *   - <v,v> = 4 for every minimal vector (correct norm).
 *   - <v,-v> = -4 (the global sign bit is handled).
 *   - the histogram N_k for a fixed v0 equals the Leech theta-series
 *     coefficients (Elkies) and is symmetric.
 *   - the triangle holonomy sgn<u,v>*sgn<v,w>*sgn<w,u> is Co0-invariant, even
 *     though the per-edge sign is gauge (flipping a vertex flips two edges).
 *
 * BUILD (from runtime/, after `make`):
 *   cc -std=c11 -O2 -I. -Ivendor/mmgroup yon_test_conway_chains.c \
 *      yon_rt.o yon_mmap.o leech_orbits.o yon_arena.o yon_curtis_canon.o \
 *      xleech2_coord.o xleech2_heap.o xleech2_mphf.o \
 *      vendor/mmgroup/[all object files] -lpthread -lm -o yon_test_conway_chains
 * Run from run_regression.sh; exit code 0 iff every check passes.
 * ========================================================================= */

#include <stdint.h>
#include <stdio.h>

extern uint32_t yon_mphf_unindex(uint32_t);
extern uint32_t gen_leech2_op_atom(uint32_t, uint32_t);
extern int      yon_leech2_signed_product(uint32_t, uint32_t);
extern int      yon_xcoord_to_int24(uint32_t, int16_t *);

/* The runtime's cross-Space RPC serve loop references the per-program dispatch
 * symbol that yonc normally emits. This C-only test never enters that loop;
 * a stub lets the full runtime object set link. */
double __yon_dispatch(double a, double b, double c);
double __yon_dispatch(double a, double b, double c) {
    (void)a; (void)b; (void)c; return 0.0;
}

#define N_TYPE2  196560u

/* Orders of the groups in the Conway chain (exact integers). */
#define ORD_CO0  8315553613086720000LL
#define ORD_CO2     42305421312000LL
#define ORD_CO3       495766656000LL

typedef struct { long long order; const char *name; } group_t;
static const group_t GROUPS[] = {
    {8315553613086720000LL, "Co0"},
    {     42305421312000LL, "Co2"},
    {       495766656000LL, "Co3"},
    {         9196830720LL, "U6(2)"},
    {          898128000LL, "McL"},
    {          454164480LL, "2^10:M22"},
    {           44352000LL, "HS"},
    {           10200960LL, "M23"},
    {            6531840LL, "U4(3):2"},
};
static const int N_GROUPS = (int)(sizeof GROUPS / sizeof GROUPS[0]);

static const char *group_of_order(long long ord) {
    for (int i = 0; i < N_GROUPS; i++)
        if (GROUPS[i].order == ord) return GROUPS[i].name;
    return 0;
}

/* A row in a stabiliser chain: a fixed inner-product value, the expected count
 * of minimal vectors realising it, and the expected stabiliser group. */
typedef struct {
    int         product;   /* the invariant inner product            */
    long        count;     /* expected number of minimal vectors     */
    long long   order;     /* expected |G| / count                   */
    const char *group;     /* expected group name                    */
} chain_row_t;

static const chain_row_t CO2_CHAIN[] = {
    {4,     1, 42305421312000LL, "Co2"},
    {2,  4600,     9196830720LL, "U6(2)"},
    {1, 47104,      898128000LL, "McL"},
    {0, 93150,      454164480LL, "2^10:M22"},
};
static const chain_row_t CO3_CHAIN[] = {
    {3,   552, 898128000LL, "McL"},
    {2, 11178,  44352000LL, "HS"},
    {1, 48600,  10200960LL, "M23"},
    {0, 75900,   6531840LL, "U4(3):2"},
};
static const int N_CO2 = (int)(sizeof CO2_CHAIN / sizeof CO2_CHAIN[0]);
static const int N_CO3 = (int)(sizeof CO3_CHAIN / sizeof CO3_CHAIN[0]);

static uint32_t vec(uint32_t i) { return yon_mphf_unindex(i) & 0x1FFFFFFu; }
static int      sgn(int x)      { return (x > 0) - (x < 0); }

static int g_fail = 0;
static void check(const char *name, int ok) {
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", name);
    if (!ok) g_fail = 1;
}

/* Verify one chain row: count matches and |G|/count lands on the named group. */
static void check_row(long long G_order, const chain_row_t *row, long observed) {
    char msg[160];
    long long idx = (row->count != 0 && G_order % row->count == 0)
                  ? G_order / row->count : -1;
    const char *named = group_of_order(idx);
    int ok = (observed == row->count) && (idx == row->order) && (named != 0);
    snprintf(msg, sizeof msg,
             "<.,.>=%d : count=%ld (exp %ld), |G|/count=%lld = %s",
             row->product, observed, row->count, idx,
             named ? named : "(not in catalogue)");
    check(msg, ok);
}

int main(void) {
    printf("=== Conway-chains runtime suite ===\n");

    /* ---- Section A: decoder invariants -------------------------------- */
    printf("-- decoder invariants --\n");
    int norm_ok = 1, flip_ok = 1;
    for (uint32_t i = 0; i < N_TYPE2; i++) {
        uint32_t v  = vec(i);
        uint32_t nv = (yon_mphf_unindex(i) ^ (1u << 24)) & 0x1FFFFFFu;
        if (yon_leech2_signed_product(v, v) != 4)   norm_ok = 0;
        if (yon_leech2_signed_product(v, nv) != -4) flip_ok = 0;
    }
    check("norm <v,v> == 4 for all 196560 minimal vectors", norm_ok);
    check("global sign <v,-v> == -4 for all minimal vectors", flip_ok);

    uint32_t v0 = vec(0);
    long hist[9] = {0};
    for (uint32_t i = 0; i < N_TYPE2; i++) {
        int d = yon_leech2_signed_product(v0, vec(i));
        if (d >= -4 && d <= 4) hist[d + 4]++;
    }
    int elkies_ok = hist[4] == 93150 && hist[5] == 47104 && hist[6] == 4600
                 && hist[8] == 1;
    int sym_ok = hist[0] == hist[8] && hist[1] == hist[7]
              && hist[2] == hist[6] && hist[3] == hist[5];
    check("N_k matches Elkies theta coefficients (93150/47104/4600/1)", elkies_ok);
    check("N_k is symmetric in the sign of the product", sym_ok);

    long omega_bad = 0;
    uint32_t a = 99999u, g = 0x20000000u | 150000001u;
    for (long t = 0; t < 1000000; t++) {
        uint32_t i = (a = a * 1664525u + 1013904223u) % N_TYPE2;
        uint32_t j = (a = a * 1664525u + 1013904223u) % N_TYPE2;
        uint32_t k = (a = a * 1664525u + 1013904223u) % N_TYPE2;
        uint32_t u = vec(i), v = vec(j), w = vec(k);
        uint32_t gu = gen_leech2_op_atom(u, g) & 0x1FFFFFFu;
        uint32_t gv = gen_leech2_op_atom(v, g) & 0x1FFFFFFu;
        uint32_t gw = gen_leech2_op_atom(w, g) & 0x1FFFFFFu;
        int o1 = sgn(yon_leech2_signed_product(u, v))
               * sgn(yon_leech2_signed_product(v, w))
               * sgn(yon_leech2_signed_product(w, u));
        int o2 = sgn(yon_leech2_signed_product(gu, gv))
               * sgn(yon_leech2_signed_product(gv, gw))
               * sgn(yon_leech2_signed_product(gw, gu));
        if (o1 != o2) omega_bad++;
    }
    check("holonomy Omega is Co0-invariant (0 deviations / 1e6)", omega_bad == 0);

    /* ---- Section B: Co2 chain (minimal-vector pairs) ------------------- */
    printf("-- Co2 stabiliser chain (pairs <v0,w>) --\n");
    long co2_total = 0;
    for (int r = 0; r < N_CO2; r++) {
        long observed = hist[CO2_CHAIN[r].product + 4];  /* d > 0 representative */
        check_row(ORD_CO2, &CO2_CHAIN[r], observed);
        /* count both signs for the closure total (product 0 has a single class) */
        co2_total += observed * (CO2_CHAIN[r].product == 0 ? 1 : 2);
    }
    check("Co2 chain closes: sum of orbits == 196560", co2_total == (long)N_TYPE2);

    /* ---- Section C: Co3 chain (minimal vectors around a type-3 point) -- */
    printf("-- Co3 stabiliser chain (<x,v>, x type-3) --\n");
    uint32_t w0 = 0;
    for (uint32_t i = 1; i < N_TYPE2; i++)
        if (yon_leech2_signed_product(v0, vec(i)) == 1) { w0 = vec(i); break; }

    /* x = v0 - w0 is type-3 (norm 6); confirm via decoded coordinates. */
    int16_t cv[24], cw[24];
    yon_xcoord_to_int24(v0, cv);
    yon_xcoord_to_int24(w0, cw);
    int xx = 0;
    for (int kk = 0; kk < 24; kk++) { int d = cv[kk] - cw[kk]; xx += d * d; }
    check("anchor x = v0 - w0 is type-3 (norm 6)", xx / 8 == 6);

    long hist3[7] = {0};  /* <x,v> in -3..3 -> index +3 */
    for (uint32_t i = 0; i < N_TYPE2; i++) {
        uint32_t v = vec(i);
        int p = yon_leech2_signed_product(v0, v) - yon_leech2_signed_product(w0, v);
        if (p >= -3 && p <= 3) hist3[p + 3]++;
    }
    long co3_total = 0;
    for (int r = 0; r < N_CO3; r++) {
        long observed = hist3[CO3_CHAIN[r].product + 3];
        check_row(ORD_CO3, &CO3_CHAIN[r], observed);
        co3_total += observed * (CO3_CHAIN[r].product == 0 ? 1 : 2);
    }
    check("Co3 chain closes: sum of orbits == 196560", co3_total == (long)N_TYPE2);

    printf("%s\n", g_fail ? "CONWAY-CHAINS: FAIL" : "CONWAY-CHAINS: PASS");
    return g_fail;
}
