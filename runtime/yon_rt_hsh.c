/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* ============================================================================
 * HSH — Hierarchical History Store (array-backed)
 * ----------------------------------------------------------------------------
 * A structure for the backward reachability direction.
 * A chain H_0 subset H_1 subset ... subset H_n with three views of the same
 * content:
 *   HASH view    (hashset)        -> membership (v in H_i) in O(1)
 *   MERKLE view  (xheap CA)       -> shared memory: levels with the same
 *                                    content share the same slot
 *   VOYAGER view (delta + prev)   -> historical navigation for the backward
 *
 * Design note: we do NOT use yon_rt_hashset_to_list to iterate the levels. The
 * value 0.0 (the monoid identity) collides with the empty list in the
 * content-addressed cons-list representation, and was lost — making the
 * identity disappear from every H_i. The source of truth is therefore an
 * explicit array of values per level; hashset and merkle remain as views. Same
 * lesson as the XSet bug: a sentinel value must not coincide with a domain
 * value.
 * ============================================================================ */

#define YON_HSH_MAX_LEVELS 4096u
#define YON_HSH_MAX_STORES   64u
/* MAX_VALS = the physical capacity of the heap (not a hand-picked number):
 * |H_i| cannot exceed the number of allocatable slots. No free parameter. */
#define YON_HSH_MAX_VALS  YON_HEAP_N_SLOTS

typedef struct {
    double   hash_set_id;     /* HASH view: cumulative hashset of the values in H_i */
    uint32_t val_off;         /* offset in the store's value pool: H_i = vals[0..val_count) */
    uint32_t val_count;       /* |H_i| (cumulative) */
    uint32_t prev_level;      /* VOYAGER view: index of H_{i-1}, 0xFFFFFFFF = base */
    uint32_t delta_count;     /* |H_i \ H_{i-1}| */
    uint32_t merkle_root;     /* MERKLE view: content-addressed slot of the root */
} hsh_level_t;

typedef struct {
    hsh_level_t levels[YON_HSH_MAX_LEVELS];
    double      vals[YON_HSH_MAX_VALS];   /* cumulative values of the LAST level */
    double      axiom[YON_HSH_MAX_LEVELS];/* a_i used at each step (for the backward) */
    uint32_t    n_vals;                   /* |H_{n_levels-1}| */
    uint32_t    n_levels;
    double      modulus;                  /* M>0 => monoid (Z_M,+); 0 => (N,+) */
    uint32_t    is_used;
} hsh_store_t;

static hsh_store_t g_hsh[YON_HSH_MAX_STORES];
static uint32_t    g_n_hsh = 0;

static hsh_store_t *hsh_lookup(double store_id) {
    uint32_t s = (uint32_t)store_id;
    if (s == 0 || s > g_n_hsh) return NULL;
    hsh_store_t *st = &g_hsh[s - 1];
    return st->is_used ? st : NULL;
}

double yon_rt_hsh_empty_mod(double e_value, double modulus) {
    ds_ensure_init();
    if (g_n_hsh >= YON_HSH_MAX_STORES) {
        fprintf(stderr, "[YON-RT] hsh_empty: pool exhausted\n");
        return 0.0;
    }
    uint32_t id = g_n_hsh++;
    hsh_store_t *st = &g_hsh[id];
    st->n_levels = 0; st->n_vals = 0; st->is_used = 1; st->modulus = modulus;
    hsh_level_t *L0 = &st->levels[0];
    L0->hash_set_id = yon_rt_hashset_add(yon_rt_hashset_empty(), e_value);
    L0->prev_level  = 0xFFFFFFFFu;
    L0->delta_count = 1;
    st->vals[st->n_vals++] = e_value;       /* H_0 = {e} in the array */
    L0->val_off = 0; L0->val_count = 1;
    L0->merkle_root = (uint32_t)yon_rt_merkle_leaf(e_value);
    st->n_levels = 1;
    return (double)(id + 1);
}

double yon_rt_hsh_empty(double e_value) {
    return yon_rt_hsh_empty_mod(e_value, 0.0);   /* (ℕ,+) */
}

/* Forward: H_i = H_{i-1} U (a_i o H_{i-1}), monoid (N,+) for compose_op=0.
 * Iterates the value array of H_{i-1} (no cons lists -> no sentinel collision). */
double yon_rt_hsh_step(double store_id, double a_i, double compose_op) {
    hsh_store_t *st = hsh_lookup(store_id);
    if (!st || st->n_levels == 0) return 0.0;
    if (st->n_levels >= YON_HSH_MAX_LEVELS) { fprintf(stderr,"[YON-RT] hsh: max levels\n"); return store_id; }
    uint32_t pi = st->n_levels - 1;
    hsh_level_t *prev = &st->levels[pi];
    hsh_level_t *cur  = &st->levels[st->n_levels];

    /* nuovo hashset cumulativo e nuovo array. Copiamo H_{i-1} e aggiungiamo i nuovi. */
    double new_set = yon_rt_hashset_empty();
    uint32_t base = prev->val_count;                  /* |H_{i-1}| */
    /* The values of H_{i-1} are vals[0..base) (cumulative chain on the last) */
    uint32_t write = 0;
    static double tmp[YON_HSH_MAX_VALS];
    /* 1) copia H_{i-1} */
    for (uint32_t k = 0; k < base; k++) {
        double v = st->vals[k];
        new_set = yon_rt_hashset_add(new_set, v);   /* a set is a value */
        tmp[write++] = v;
    }
    /* 2) aggiungi (a_i + v) se nuovo */
    uint32_t delta_n = 0; double dmax = 0.0;
    for (uint32_t k = 0; k < base; k++) {
        double cv = st->vals[k] + a_i;                /* compose (ℕ,+) */
        if (st->modulus > 0.5) { cv = cv - st->modulus * (double)((long long)(cv / st->modulus)); } /* mod M */
        if (yon_rt_hashset_contains(new_set, cv) < 0.5) {
            new_set = yon_rt_hashset_add(new_set, cv);
            if (write < YON_HSH_MAX_VALS) tmp[write++] = cv;
            if (delta_n == 0 || cv > dmax) dmax = cv;
            delta_n++;
        }
    }
    /* commit the array into the store (becomes the new cumulative) */
    for (uint32_t k = 0; k < write && k < YON_HSH_MAX_VALS; k++) st->vals[k] = tmp[k];
    st->n_vals = write;

    cur->hash_set_id = new_set;
    cur->prev_level  = pi;
    cur->val_off     = 0; cur->val_count = write;
    cur->delta_count = delta_n;
    if (delta_n == 0) {
        cur->merkle_root = prev->merkle_root;                 /* sharing totale */
    } else {
        double dleaf = yon_rt_merkle_leaf(dmax);
        cur->merkle_root = (uint32_t)yon_rt_merkle_node2(a_i, (double)prev->merkle_root, dleaf);
    }
    st->axiom[st->n_levels] = a_i;   /* record a_i for the backward pass (no lists) */
    (void)compose_op;
    st->n_levels++;
    return store_id;
}

/* Membership O(1): v ∈ H_i ? */
double yon_rt_hsh_contains(double store_id, double level, double v) {
    hsh_store_t *st = hsh_lookup(store_id);
    if (!st) return 0.0;
    uint32_t i = (uint32_t)level;
    if (i >= st->n_levels) return 0.0;
    return yon_rt_hashset_contains(st->levels[i].hash_set_id, v);
}

/* Backward: witness for goal G as a bitmask of the axioms used. */
double yon_rt_hsh_backward(double store_id, double goal, double weights_list) {
    hsh_store_t *st = hsh_lookup(store_id);
    if (!st || st->n_levels == 0) return 0.0;
    uint32_t n = st->n_levels - 1;
    (void)weights_list;   /* the weights are in st->axiom[1..n]; the list is no longer
                           * used, to avoid the slot0/EMPTY collision of cons lists */
    double v = goal; uint64_t mask = 0;
    for (int i = (int)n; i >= 1; i--) {
        double a = st->axiom[i];   /* a_i registered at step i */
        if (v >= a && yon_rt_hashset_contains(st->levels[i-1].hash_set_id, v - a) >= 0.5) {
            /* The witness bitmask holds 64 bits: a shift count >= 64 is UB in C
             * (and cannot be represented anyway). Guard it — the reachability
             * decision below (v reduced to 0) is unaffected; only the explicit
             * bit-witness is necessarily lossy past 64 levels. */
            if (i - 1 < 64) mask |= (1ULL << (i - 1));
            v -= a;
        }
    }
    if (v != 0.0) return 0.0;
    return (double)mask;
}

double yon_rt_hsh_shared_levels(double store_id) {
    hsh_store_t *st = hsh_lookup(store_id);
    if (!st) return 0.0;
    uint32_t shared = 0;
    for (uint32_t i = 1; i < st->n_levels; i++)
        if (st->levels[i].merkle_root == st->levels[i-1].merkle_root) shared++;
    return (double)shared;
}
double yon_rt_hsh_levels(double store_id) {
    hsh_store_t *st = hsh_lookup(store_id);
    return st ? (double)st->n_levels : 0.0;
}

/* ============================================================================
 * A condition the compiler decides itself, on a proposition it built and that
 * is never unknown (0=present, 1=absent). An unknown here is a broken
 * invariant of the compiler, and stops the program: it never becomes false.
 * ============================================================================ */
int8_t yon_rt_to_bool_dec(int8_t decided) {
    if (decided == 2) {
        yon_rt_refuse_with(YON_REFUSAL_UnknownDecided, 0, 0, 0);
    }
    return (decided == 0) ? 1 : 0;   /* present->true, absent->false */
}

/* ============================================================================
 * Extended Math: libm functions not yet exposed.
 * ============================================================================ */
double yon_rt_math_lcm(double a_d, double b_d) {
    int64_t a = (int64_t)fabs(a_d), b = (int64_t)fabs(b_d);
    if (a == 0 || b == 0) return 0.0;
    int64_t x = a, y = b;
    while (y != 0) { int64_t t = y; y = x % y; x = t; }   /* gcd */
    return (double)((a / x) * b);                          /* lcm = a*b/gcd */
}
double yon_rt_math_log2(double x)  { return log2(x); }
double yon_rt_math_log10(double x) { return log10(x); }
double yon_rt_math_atan2(double y, double x) { return atan2(y, x); }
double yon_rt_math_sinh(double x)  { return sinh(x); }
double yon_rt_math_cosh(double x)  { return cosh(x); }
double yon_rt_math_tanh(double x)  { return tanh(x); }


/* ============================================================================
 * Exact Co_0 canonicalization — replaces the partial co0_step (<xi>.M_24) with
 * the full canonical reduction of the Co_0 orbit.
 *
 * Principle: no heuristic, no free parameter, no truncated BFS. Uses
 * gen_leech2_reduce_type2 from libmmgroup: given v (a type-2 Leech vector mod
 * 2), it computes the group word g in G_x0 = 2^(1+24).Co_1 that reduces v to
 * the canonical representative of its orbit. Applying g to v yields the fixed
 * canonical form: two vectors in the same Co_0 orbit give the same canonical
 * form. It is a closed algebraic reduction (Leech syndrome decoding), not
 * iteration.
 *
 * Completeness: unlike co0_step (which captured only <xi>.M_24), this captures
 * the full Co_0 orbit for type-2 vectors. reduce_type2 returns -1 if v is not
 * type-2: in that case we return v unchanged (no spurious merge).
 * ============================================================================ */
extern int32_t gen_leech2_reduce_type2(uint32_t v, uint32_t *pg_out);
extern uint32_t gen_leech2_op_word_leech2(uint32_t l, uint32_t *g, uint32_t n, uint32_t back);
extern uint32_t gen_leech2_type(uint64_t v2);

double yon_rt_leech_co0_canonical_exact(double v_24bit) {
    uint32_t v = ((uint32_t)v_24bit) & 0xFFFFFFu;
    uint32_t g[8];
    int32_t len = gen_leech2_reduce_type2(v, g);
    if (len < 0) {
        /* v is not type-2: no canonical reduction defined here. Return v
         * unchanged — correct under-merge, never a spurious merge. */
        return (double)v;
    }
    /* apply the word g to v: yields the fixed canonical form of the orbit */
    uint32_t canon = gen_leech2_op_word_leech2(v, g, (uint32_t)len, 0);
    return (double)canon;
}

/* Exact check: are two vectors Co_0-equivalent? (same canonical form). */
double yon_rt_leech_co0_equivalent(double a_24bit, double b_24bit) {
    double ca = yon_rt_leech_co0_canonical_exact(a_24bit);
    double cb = yon_rt_leech_co0_canonical_exact(b_24bit);
    return (ca == cb) ? 1.0 : 0.0;
}

/* The bridge of the MLIR algebra verifier, for the units written by hand that
 * reach it: @<Place>_instantiate gives the index of an algebra in its table, 0 to
 * 6, as a handle. An index outside the table is refused. The presentations and the
 * reachability are places of the prelude, Generated and Land. */
double yon_rt_magma_from_algebra(double op_id) {
    if (!(op_id >= 0.0 && op_id <= 6.0) || op_id != (double)(int)op_id) {
        yon_rt_refuse_with(YON_REFUSAL_AlgebraNotInTable, yon_refusal_real(op_id), 0, 0);
    }
    return op_id + 1.0;
}
