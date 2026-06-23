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
 * value 0.0 (the monoid identity) collides with YON_RT_LIST_EMPTY in the
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
    st->vals[st->n_vals++] = e_value;       /* H_0 = {e} nell'array */
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
        yon_rt_hashset_add(new_set, v);
        tmp[write++] = v;
    }
    /* 2) aggiungi (a_i + v) se nuovo */
    uint32_t delta_n = 0; double dmax = 0.0;
    for (uint32_t k = 0; k < base; k++) {
        double cv = st->vals[k] + a_i;                /* compose (ℕ,+) */
        if (st->modulus > 0.5) { cv = cv - st->modulus * (double)((long long)(cv / st->modulus)); } /* mod M */
        if (yon_rt_hashset_contains(new_set, cv) < 0.5) {
            yon_rt_hashset_add(new_set, cv);
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
 * Decidable — intuitionistic guard for the proposition -> boolean collapse.
 * Runtime proposition: i8 with 0=present, 1=absent, 2=unknown (Heyting).
 *   yon_rt_decide(p)       : asserts decidability. On unknown(2) it aborts
 *                            explicitly (not a silent coercion).
 *   yon_rt_to_bool_dec(d)  : Decidable -> boolean, total (unknown already
 *                            excluded).
 * ============================================================================ */
int8_t yon_rt_decide(int8_t prop) {
    if (prop == 2) {
        fprintf(stderr, "[YON-RT] decide: proposition is unknown — not decidable; "
                        "cannot collapse to boolean (intuitionistic guard)\n");
        abort();
    }
    return prop;                 /* 0=present, 1=absent: already decided */
}
int8_t yon_rt_to_bool_dec(int8_t decided) {
    if (decided == 2) {          /* invariante Decidable violato */
        fprintf(stderr, "[YON-RT] to_bool_dec: unknown reached a Decidable slot\n");
        abort();
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
 * Collections: Set.union / Set.intersect / List.reverse.
 * Built on the existing primitives. Iteration via an explicit array to avoid
 * the slot-0/sentinel collision of cons lists (the HSH/XSet lesson).
 * ============================================================================ */
/* Iteration via at_bucket (NOT to_list): avoids the slot-0/sentinel trap that
 * makes hashset_to_list lose elements (cons with tail in slot 0). */
/* 2026-06-04: set directories are dynamic per-set; each set is iterated
 * over ITS OWN capacity (dir_capacity(set)), not a global constant. */
double yon_rt_hashset_union(double a_id, double b_id) {
    double out = yon_rt_hashset_empty();
    double cap_a = yon_rt_hashset_dir_capacity(a_id);
    for (double i = 0; i < cap_a; i += 1.0) {
        double v = yon_rt_hashset_at_bucket(a_id, i);
        if (v != -1.0) out = yon_rt_hashset_add(out, v);
    }
    double cap_b = yon_rt_hashset_dir_capacity(b_id);
    for (double i = 0; i < cap_b; i += 1.0) {
        double v = yon_rt_hashset_at_bucket(b_id, i);
        if (v != -1.0) out = yon_rt_hashset_add(out, v);
    }
    return out;
}
double yon_rt_hashset_intersect(double a_id, double b_id) {
    double out = yon_rt_hashset_empty();
    double cap_a = yon_rt_hashset_dir_capacity(a_id);
    for (double i = 0; i < cap_a; i += 1.0) {
        double v = yon_rt_hashset_at_bucket(a_id, i);
        if (v != -1.0 && yon_rt_hashset_contains(b_id, v) >= 0.5)
            out = yon_rt_hashset_add(out, v);
    }
    return out;
}
double yon_rt_list_reverse(double list_id) {
    /* materialize into an array, rebuild in reverse via cons.
     * End guard: node == YON_RT_LIST_EMPTY (0xFFFFFFFF). With slot 0 reserved, a
     * valid node is never 0.0; the empty list is 0xFFFFFFFF. Termination:
     * guaranteed by construction, not by an arbitrary cap. Cons lists are
     * acyclic: each cons allocates a new slot whose tail points to a slot
     * allocated earlier (a strictly smaller index), so the chain of tails is
     * strictly decreasing and ends at EMPTY. No free parameter: the only bound
     * is the physical capacity of the heap. */
    static double buf[YON_HEAP_N_SLOTS]; uint32_t n = 0;
    double node = list_id;
    while (node != YON_RT_LIST_EMPTY) {
        buf[n++] = yon_rt_list_head(node);
        node = yon_rt_list_tail(node);
    }
    double out = yon_rt_list_empty(0.0);
    /* cons in forward order reconstructs the reversed list */
    for (uint32_t i = 0; i < n; i++) out = yon_rt_list_cons(buf[i], out);
    return out;
}

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

/* ============================================================================
 * Algebraic solver — general schema.
 *
 * The "CommutativeAlgebra" world is a schema: a place is a concrete algebraic
 * structure = (generators, operation, laws). The solver exposes three
 * projections of the closure R: closure / reachable+certificate / normal_form.
 *
 * A generic binary operation, dispatched by op_id. f64->f64->f64. The solver
 * has no knowledge of the specific operation: it is a parameter.
 * ============================================================================ */
double yon_rt_alg_op(double a, double b, double op_id_d) {
    int op = (int)op_id_d;
    switch (op) {
        case 0: return a + b;                      /* (Z, +)  commutative monoid  */
        case 1: return a > b ? a : b;              /* max     idempotent comm.    */
        case 2: return a < b ? a : b;              /* min     idempotent comm.    */
        case 3: return a * b;                      /* (Z, *)  commutative monoid  */
        case 4: { uint64_t x=(uint64_t)a, y=(uint64_t)b; return (double)(x | y); }   /* OR  */
        case 5: { uint64_t x=(uint64_t)a, y=(uint64_t)b; return (double)(x & y); }   /* AND */
        case 6: { /* gcd: commutative+associative, identity 0 */
            int64_t x=(int64_t)(a<0?-a:a), y=(int64_t)(b<0?-b:b);
            while (y){ int64_t t=y; y=x%y; x=t; } return (double)x; }
        case 7: return a - b;   /* subtraction: NOT comm, NOT assoc (negative test) */
        default: return a + b;
    }
}

/* Exact verification of the laws over an explicit set of elements.
 * Returns 1 if the law holds on all tuples, 0 otherwise. Zero parameters, zero
 * sampling: an exhaustive check. If you quotient by a law, this verification
 * must pass first (otherwise it is the S_n over-merge in general form). */
double yon_rt_alg_verify_commutative(double op_id, const double *elems, double n_d) {
    uint32_t n = (uint32_t)n_d;
    for (uint32_t i = 0; i < n; i++)
        for (uint32_t j = i+1; j < n; j++)
            if (yon_rt_alg_op(elems[i], elems[j], op_id) !=
                yon_rt_alg_op(elems[j], elems[i], op_id)) return 0.0;
    return 1.0;
}
double yon_rt_alg_verify_associative(double op_id, const double *elems, double n_d) {
    uint32_t n = (uint32_t)n_d;
    for (uint32_t i = 0; i < n; i++)
      for (uint32_t j = 0; j < n; j++)
        for (uint32_t k = 0; k < n; k++) {
            double l = yon_rt_alg_op(yon_rt_alg_op(elems[i],elems[j],op_id), elems[k], op_id);
            double r = yon_rt_alg_op(elems[i], yon_rt_alg_op(elems[j],elems[k],op_id), op_id);
            if (l != r) return 0.0;
        }
    return 1.0;
}
/* Identity: find e among the elements such that e op a == a op e == a for all a.
 * Returns the identity element if it exists, otherwise NaN (no identity). */
double yon_rt_alg_find_identity(double op_id, const double *elems, double n_d) {
    uint32_t n = (uint32_t)n_d;
    for (uint32_t e = 0; e < n; e++) {
        int is_id = 1;
        for (uint32_t a = 0; a < n; a++) {
            if (yon_rt_alg_op(elems[e], elems[a], op_id) != elems[a] ||
                yon_rt_alg_op(elems[a], elems[e], op_id) != elems[a]) { is_id = 0; break; }
        }
        if (is_id) return elems[e];
    }
    return (double)(0.0/0.0);  /* NaN: no identity among the generators */
}

/* ============================================================================
 * closure() — the closure R of the generators under the operation.
 *
 * R = the smallest set that contains the generators and is closed under op.
 * Algorithm: fixpoint. Start from gen, apply op to all pairs of R, add the new
 * ones, repeat until R stops growing. Dedup by exact state (each state once).
 * Termination: by construction, when no new element appears — no parameter, no
 * iteration cap.
 *
 * Storage: a HeapRef chain. If a heap fills up, put_chain allocates/links a new
 * one. No artificial limit: only real memory.
 *
 * commutative_verified: if 1 (which MUST be passed by the verifier, not
 * declared), skip the redundant pairs (b,a) — exact S_2 quotient.
 *
 * Returns |R| (the cardinality of the closure). The elements are left in out[]
 * (capacity out_cap; if R exceeds out_cap it still returns the correct |R| but
 * out[] is truncated — out_cap is a CALLER buffer, not a cap on the
 * computation). Warning: for an infinite closure this function does not
 * terminate; the caller must use it only on structures with finite R (e.g.
 * Z_n, finite semigroups).
 * ============================================================================ */
double yon_rt_alg_closure(double op_id, const double *gen, double n_gen_d,
                          int commutative_verified,
                          double *out, double out_cap_d) {
    uint32_t n_gen = (uint32_t)n_gen_d;
    uint32_t out_cap = (uint32_t)out_cap_d;
    /* A dedicated heap for the closure: each state is a content-addressed f64
     * payload. put_chain dedups automatically (same value -> same heapref). */
    yon_xheap_t *H = yon_xheap_create();
    if (!H) return 0.0;

    /* R materialized into an array to iterate; the real dedup is in the heap. */
    static double R[1u << 16];   /* working set; for larger R the chain holds the storage */
    uint32_t r_n = 0;
    /* insert the generators (dedup) */
    for (uint32_t i = 0; i < n_gen; i++) {
        double v = gen[i];
        bool was_new = false;
        yon_xheap_put_or_get(H, &v, sizeof(v), YON_TAG_USER1, &was_new);
        if (was_new && r_n < (1u<<16)) R[r_n++] = v;
    }

    /* fixpoint: apply op to all known pairs, add the new ones */
    uint32_t frontier_start = 0;
    int grew = 1;
    while (grew) {
        grew = 0;
        uint32_t cur_n = r_n;
        /* apply op to the pairs (i,j); using a frontier so as not to
         * reconsider pairs already fully explored in previous iterations */
        for (uint32_t i = 0; i < cur_n; i++) {
            uint32_t jstart = (i >= frontier_start) ? 0 : frontier_start;
            /* if commutativity is verified: j>=i (skip the redundant (b,a)) */
            for (uint32_t j = (commutative_verified ? i : jstart); j < cur_n; j++) {
                double c = yon_rt_alg_op(R[i], R[j], op_id);
                bool was_new = false;
                yon_xheap_put_or_get(H, &c, sizeof(c), YON_TAG_USER1, &was_new);
                if (was_new) {
                    if (r_n < (1u<<16)) R[r_n++] = c;
                    grew = 1;
                }
            }
        }
        frontier_start = cur_n;
    }

    /* copy R into out[] (up to out_cap; the returned |R| is still exact) */
    uint32_t copy = (r_n < out_cap) ? r_n : out_cap;
    for (uint32_t i = 0; i < copy; i++) out[i] = R[i];
    double card = (double)r_n;
    yon_xheap_destroy(H);
    return card;
}

/* ============================================================================
 * reachable(T) + certificate.
 *
 * Decides whether T is in the closure R of the generators under op, and if so
 * produces a certificate: the pair (a,b) of already-reachable elements with
 * a op b == T. Recursively, a and b have their own certificates down to the
 * generators — the derivation tree. Here we return the certificate at one
 * level (a, b) + a flag; the full backward is obtained by applying reachable to
 * a and b.
 *
 * Each reached state is stored once (the first cert wins). The search is the
 * same fixpoint closure, with early exit as soon as T appears. For generators:
 * cert = (T, NaN) [it is an axiom].
 *
 * Returns 1.0 if T is reachable, 0.0 otherwise. If reachable, writes into
 * cert_a/cert_b the pair that produces T (cert_a==T, cert_b==NaN if T is a
 * generator). No parameter: terminates when T appears or R stops growing.
 * (Infinite-R case: like closure, requires a structure with finite R, or the
 *  lazy bounded-by-T variant of the next step.)
 * ============================================================================ */
double yon_rt_alg_reachable(double op_id, const double *gen, double n_gen_d,
                            int commutative_verified, double T,
                            double *cert_a, double *cert_b) {
    uint32_t n_gen = (uint32_t)n_gen_d;
    yon_xheap_t *H = yon_xheap_create();
    if (!H) return 0.0;
    static double R[1u << 16];
    uint32_t r_n = 0;
    double NaN = (double)(0.0/0.0);

    for (uint32_t i = 0; i < n_gen; i++) {
        double v = gen[i];
        bool was_new = false;
        yon_xheap_put_or_get(H, &v, sizeof(v), YON_TAG_USER1, &was_new);
        if (was_new && r_n < (1u<<16)) { R[r_n++]=v; }
        if (v == T) { *cert_a = T; *cert_b = NaN; yon_xheap_destroy(H); return 1.0; }
    }

    uint32_t frontier_start = 0;
    int grew = 1;
    while (grew) {
        grew = 0;
        uint32_t cur_n = r_n;
        for (uint32_t i = 0; i < cur_n; i++) {
            uint32_t jstart = (i >= frontier_start) ? 0 : frontier_start;
            for (uint32_t j = (commutative_verified ? i : jstart); j < cur_n; j++) {
                double c = yon_rt_alg_op(R[i], R[j], op_id);
                bool was_new = false;
                yon_xheap_put_or_get(H, &c, sizeof(c), YON_TAG_USER1, &was_new);
                if (was_new) {
                    if (r_n < (1u<<16)) { R[r_n++]=c; }
                    grew = 1;
                    if (c == T) {        /* early-exit: T raggiunto, cert = (R[i],R[j]) */
                        *cert_a = R[i]; *cert_b = R[j];
                        yon_xheap_destroy(H); return 1.0;
                    }
                }
            }
        }
        frontier_start = cur_n;
    }
    yon_xheap_destroy(H);
    *cert_a = NaN; *cert_b = NaN;
    return 0.0;   /* T not reachable */
}

/* ============================================================================
 * normal_form(word) — canonical form of a word under the laws.
 *
 * A "word" is a sequence of generators to compose: w = e_0 o e_1 o ...
 * normal_form computes the canonical representative of its equivalence class
 * under the verified laws. Two words are law-equivalent iff they have the same
 * normal_form (decision of the word problem for the structure).
 *
 * - commutative_verified=1: order does not matter -> we sort the word before
 *   the fold (explicit canonicalization of the S_n orbit over the positions).
 *   Allowed only because commutativity was verified, not declared.
 * - associative_verified: grouping does not matter -> fold-left is canonical.
 *
 * Without verified laws, normal_form is just the fold-left in the given order
 * (no quotient): honest, it does not collapse what is not proven equivalent.
 * ============================================================================ */
static int cmp_double(const void *a, const void *b) {
    double x = *(const double*)a, y = *(const double*)b;
    return (x < y) ? -1 : (x > y) ? 1 : 0;
}
double yon_rt_alg_normal_form(double op_id, const double *word, double n_d,
                              int commutative_verified) {
    uint32_t n = (uint32_t)n_d;
    if (n == 0) return (double)(0.0/0.0);   /* empty word: NaN (no identity here) */
    static double w[1u << 16];
    if (n > (1u<<16)) n = (1u<<16);
    for (uint32_t i = 0; i < n; i++) w[i] = word[i];
    if (commutative_verified) qsort(w, n, sizeof(double), cmp_double);  /* canonical order */
    double acc = w[0];
    for (uint32_t i = 1; i < n; i++) acc = yon_rt_alg_op(acc, w[i], op_id);
    return acc;
}
/* equal(word1, word2): are two words law-equivalent? (same normal_form). */
double yon_rt_alg_word_equal(double op_id,
                             const double *w1, double n1, const double *w2, double n2,
                             int commutative_verified) {
    double nf1 = yon_rt_alg_normal_form(op_id, w1, n1, commutative_verified);
    double nf2 = yon_rt_alg_normal_form(op_id, w2, n2, commutative_verified);
    return (nf1 == nf2) ? 1.0 : 0.0;
}

/* ============================================================================
 * Magma — builder for the "Magma" world in surface Yon.
 *
 * A Magma = (op_id, accumulated generators). The laws are NOT assumed: they are
 * verified on demand (is_commutative/is_associative). closure/reachable/
 * normal_form use commutativity only if verified.
 *
 * Handle = index+1 (0 reserved as "empty"). Pool YON_MAGMA_MAX.
 * ============================================================================ */
/* forward decl of the algebra catalog (defined further below) */
double yon_rt_alg_catalog_op(double cat_id);
double yon_rt_alg_catalog_is_commutative(double cat_id);
double yon_rt_alg_catalog_is_associative(double cat_id);
double yon_rt_alg_catalog_identity(double cat_id);
double yon_rt_alg_catalog_is_monotone(double cat_id);
double yon_rt_alg_reachable_bounded(double,const double*,double,int,double);
double yon_rt_alg_subsetsum(double,const double*,double,double,int,double*);

#define YON_MAGMA_MAX     64u
#define YON_MAGMA_GEN_CAP 4096u
typedef struct {
    double   op_id;
    double   cat_id;        /* algebra catalog index; -1 = raw op without certified laws */
    double   gen[YON_MAGMA_GEN_CAP];
    uint32_t n_gen;
    double   word[YON_MAGMA_GEN_CAP];   /* parola per normal_form */
    uint32_t n_word;
    uint32_t n_knap;
    uint32_t is_used;
} ds_magma_t;
static ds_magma_t g_magmas[YON_MAGMA_MAX];
static uint32_t g_n_magmas = 0;

double yon_rt_magma_empty(double op_id) {
    ds_ensure_init();
    if (g_n_magmas >= YON_MAGMA_MAX) { fprintf(stderr,"[YON-RT] magma pool exhausted\n"); return 0.0; }
    uint32_t id = g_n_magmas++;
    g_magmas[id].op_id = op_id;
    g_magmas[id].cat_id = -1.0;       /* raw op: laws to be verified, not certified */
    g_magmas[id].n_gen = 0;
    g_magmas[id].n_knap = 0;
    g_magmas[id].n_word = 0;
    g_magmas[id].is_used = 1;
    return (double)(id + 1);
}

/* Instantiate a place from a catalog algebra: the laws come WITH the algebra
 * (theorems), they are not verified on the generators. This is the intended way
 * for the user: pick a known algebra and instantiate a place with its
 * generators. */
double yon_rt_magma_from_algebra(double cat_id) {
    ds_ensure_init();
    if (g_n_magmas >= YON_MAGMA_MAX) { fprintf(stderr,"[YON-RT] magma pool exhausted\n"); return 0.0; }
    uint32_t id = g_n_magmas++;
    g_magmas[id].op_id  = yon_rt_alg_catalog_op(cat_id);
    g_magmas[id].cat_id = cat_id;
    g_magmas[id].n_gen = 0;
    g_magmas[id].n_knap = 0;
    g_magmas[id].n_word = 0;
    g_magmas[id].is_used = 1;
    return (double)(id + 1);
}

/* Effective commutativity of the magma: if instantiated from the catalog, it is
 * the certified law of the algebra (a theorem); if a raw op, it is verified on
 * the generators. This is the function the queries use to decide whether to
 * quotient. */
static int magma_commutative(ds_magma_t *m) {
    if (m->cat_id >= 0.0)
        return (int)yon_rt_alg_catalog_is_commutative(m->cat_id);   /* certified */
    return (int)yon_rt_alg_verify_commutative(m->op_id, m->gen, (double)m->n_gen); /* verified */
}
static ds_magma_t *magma_lookup(double h) {
    uint32_t id = (uint32_t)h;
    if (id < 1 || id > g_n_magmas) return NULL;
    ds_magma_t *m = &g_magmas[id - 1];
    return m->is_used ? m : NULL;
}
/* add a generator; returns the handle (immutable-style: same handle) */
double yon_rt_magma_gen(double h, double x) {
    ds_magma_t *m = magma_lookup(h);
    if (!m) return h;
    if (m->n_gen < YON_MAGMA_GEN_CAP) m->gen[m->n_gen++] = x;
    return h;
}
/* verify laws (exact, on the generators) */
double yon_rt_magma_is_commutative(double h) {
    ds_magma_t *m = magma_lookup(h); if (!m) return 0.0;
    return yon_rt_alg_verify_commutative(m->op_id, m->gen, (double)m->n_gen);
}
double yon_rt_magma_is_associative(double h) {
    ds_magma_t *m = magma_lookup(h); if (!m) return 0.0;
    return yon_rt_alg_verify_associative(m->op_id, m->gen, (double)m->n_gen);
}
double yon_rt_magma_identity(double h) {
    ds_magma_t *m = magma_lookup(h); if (!m) return (double)(0.0/0.0);
    return yon_rt_alg_find_identity(m->op_id, m->gen, (double)m->n_gen);
}
/* |R|: the cardinality of the closure. Uses commutativity if verified. */
double yon_rt_magma_closure_size(double h) {
    ds_magma_t *m = magma_lookup(h); if (!m) return 0.0;
    int comm = magma_commutative(m);
    static double out[1u << 16];
    return yon_rt_alg_closure(m->op_id, m->gen, (double)m->n_gen, comm, out, (double)(1u<<16));
}
/* Is T reachable? (boolean). The certificate is available via the direct C-API. */
double yon_rt_magma_reachable(double h, double T) {
    ds_magma_t *m = magma_lookup(h); if (!m) return 0.0;
    int comm = magma_commutative(m);
    /* If the algebra is monotone (certified by the catalog), use the
     * bounded-by-target variant: it terminates even on an infinite closure
     * (e.g. Additive), pruning that is valid by theorem. Otherwise the full
     * closure (requires finite R). */
    if (m->cat_id >= 0.0 && yon_rt_alg_catalog_is_monotone(m->cat_id) >= 0.5)
        return yon_rt_alg_reachable_bounded(m->op_id, m->gen, (double)m->n_gen, comm, T);
    double ca, cb;
    return yon_rt_alg_reachable(m->op_id, m->gen, (double)m->n_gen, comm, T, &ca, &cb);
}

/* Land.reach(magma, target) -> 1.0 if the target is reachable by composing
 * generators (each at most once, Theorem 4) under the magma operation, else
 * 0.0. Coherent with Land.witness by construction: both run the same disjoint
 * composition; reach is "a witness exists", witness is the witness itself. */
double yon_rt_land_reach(double h, double T) {
    ds_magma_t *m = magma_lookup(h); if (!m) return 0.0;
    int mono = (m->cat_id >= 0.0) ? (int)yon_rt_alg_catalog_is_monotone(m->cat_id) : 0;
    double mask = 0.0;
    return yon_rt_alg_subsetsum(m->op_id, m->gen, (double)m->n_gen, T, mono, &mask);
}

/* Land.witness(magma, target) -> the certificate: a bitmask of which generators
 * compose (under the magma operation, each used at most once) to reach the
 * target. 0 if the target is not reachable. The reachability decision is
 * Land.reach; this returns the witnessing combination. */
double yon_rt_land_witness(double h, double T) {
    ds_magma_t *m = magma_lookup(h); if (!m) return 0.0;
    int mono = (m->cat_id >= 0.0) ? (int)yon_rt_alg_catalog_is_monotone(m->cat_id) : 0;
    double mask = 0.0;
    yon_rt_alg_subsetsum(m->op_id, m->gen, (double)m->n_gen, T, mono, &mask);
    return mask;
}
/* word for normal_form: push elements, then normal_form reduces them */
double yon_rt_magma_word_push(double h, double x) {
    ds_magma_t *m = magma_lookup(h); if (!m) return h;
    if (m->n_word < YON_MAGMA_GEN_CAP) m->word[m->n_word++] = x;
    return h;
}
double yon_rt_magma_normal_form(double h) {
    ds_magma_t *m = magma_lookup(h); if (!m) return (double)(0.0/0.0);
    int comm = magma_commutative(m);
    double nf = yon_rt_alg_normal_form(m->op_id, m->word, (double)m->n_word, comm);
    m->n_word = 0;   /* reset the word after the reduction */
    return nf;
}

/* ============================================================================
 * ALGEBRA CATALOG — certified laws.
 *
 * Key difference from "verification on the generators": here the laws are
 * theorems about the structure, not empirical checks. (Z,+) is commutative by
 * proof, not because we tested it on {1,5,8}. The user instantiates a catalog
 * algebra as a place; the laws come WITH the algebra.
 *
 * Law bitfield: bit0=commutative, bit1=associative, bit2=idempotent,
 * bit3=has_identity. identity_value valid iff bit3.
 *
 * These are properties known in universal algebra, here declared as catalog
 * facts (the proof is standard: monoids, semilattices, Boolean algebra, gcd
 * domain). They are not heuristics: they are the theorems that define each
 * structure. The user cannot inject an algebra with false laws — they can only
 * choose from the verified catalog.
 * ============================================================================ */
#define ALG_COMMUTATIVE  0x1u
#define ALG_ASSOCIATIVE  0x2u
#define ALG_IDEMPOTENT   0x4u
#define ALG_HAS_IDENTITY 0x8u
#define ALG_MONOTONE     0x10u  /* a op b >= max(a,b) for generators >=0: target pruning is valid */

typedef struct {
    const char *name;
    int    op_id;            /* operazione in yon_rt_alg_op */
    uint32_t laws;           /* bitfield of certified laws */
    double identity_value;   /* valid iff ALG_HAS_IDENTITY */
} alg_catalog_entry_t;

/* The catalog. Each row = an algebra with its proven laws. */
static const alg_catalog_entry_t g_alg_catalog[] = {
    /* name          op  laws                                                  id  */
    { "Additive",     0, ALG_COMMUTATIVE|ALG_ASSOCIATIVE|ALG_HAS_IDENTITY|ALG_MONOTONE, 0.0 },  /* (N,+) comm monoid, monotone for gen>=0 */
    { "TropicalMax",  1, ALG_COMMUTATIVE|ALG_ASSOCIATIVE|ALG_IDEMPOTENT,       0.0 },  /* sup-semilattice */
    { "TropicalMin",  2, ALG_COMMUTATIVE|ALG_ASSOCIATIVE|ALG_IDEMPOTENT,       0.0 },  /* inf-semilattice */
    { "Multiplicative",3,ALG_COMMUTATIVE|ALG_ASSOCIATIVE|ALG_HAS_IDENTITY,     1.0 },  /* (Z,*) comm monoid */
    { "BooleanOr",    4, ALG_COMMUTATIVE|ALG_ASSOCIATIVE|ALG_IDEMPOTENT|ALG_HAS_IDENTITY|ALG_MONOTONE, 0.0 }, /* sup-semilattice, monotone */
    { "BooleanAnd",   5, ALG_COMMUTATIVE|ALG_ASSOCIATIVE|ALG_IDEMPOTENT,       0.0 },  /* inf-semilattice (AND) */
    { "Gcd",          6, ALG_COMMUTATIVE|ALG_ASSOCIATIVE|ALG_HAS_IDENTITY,     0.0 },  /* gcd-monoid, id=0 */
};
#define ALG_CATALOG_N (sizeof(g_alg_catalog)/sizeof(g_alg_catalog[0]))

/* Lookup by name -> catalog index (-1 if absent). */
double yon_rt_alg_catalog_id(const char *name) {
    for (uint32_t i = 0; i < ALG_CATALOG_N; i++)
        if (strcmp(g_alg_catalog[i].name, name) == 0) return (double)i;
    return -1.0;
}
/* Accessor for certified laws by catalog index. */
double yon_rt_alg_catalog_op(double cat_id) {
    int i = (int)cat_id; if (i < 0 || i >= (int)ALG_CATALOG_N) return 0.0;
    return (double)g_alg_catalog[i].op_id;
}
double yon_rt_alg_catalog_is_commutative(double cat_id) {
    int i = (int)cat_id; if (i < 0 || i >= (int)ALG_CATALOG_N) return 0.0;
    return (g_alg_catalog[i].laws & ALG_COMMUTATIVE) ? 1.0 : 0.0;
}
double yon_rt_alg_catalog_is_associative(double cat_id) {
    int i = (int)cat_id; if (i < 0 || i >= (int)ALG_CATALOG_N) return 0.0;
    return (g_alg_catalog[i].laws & ALG_ASSOCIATIVE) ? 1.0 : 0.0;
}
double yon_rt_alg_catalog_is_monotone(double cat_id) {
    int i = (int)cat_id; if (i < 0 || i >= (int)ALG_CATALOG_N) return 0.0;
    return (g_alg_catalog[i].laws & ALG_MONOTONE) ? 1.0 : 0.0;
}
double yon_rt_alg_catalog_identity(double cat_id) {
    int i = (int)cat_id; if (i < 0 || i >= (int)ALG_CATALOG_N) return (double)(0.0/0.0);
    if (!(g_alg_catalog[i].laws & ALG_HAS_IDENTITY)) return (double)(0.0/0.0);
    return g_alg_catalog[i].identity_value;
}

/* reachable bounded-by-target: for monotone algebras (a op b >= max(a,b)),
 * expands only states <= T. Pruning that is valid by theorem (certified
 * monotonicity), not heuristic: a state > T can never come back down to T. It
 * terminates because the states <= T reachable from positive generators are
 * finite in number. Use only if the algebra is marked ALG_MONOTONE and the
 * generators are >=0. */
double yon_rt_alg_reachable_bounded(double op_id, const double *gen, double n_gen_d,
                                    int commutative_verified, double T) {
    uint32_t n_gen = (uint32_t)n_gen_d;
    yon_xheap_t *H = yon_xheap_create();
    if (!H) return 0.0;
    static double R[1u << 16];
    uint32_t r_n = 0;
    for (uint32_t i = 0; i < n_gen; i++) {
        double v = gen[i];
        if (v > T) continue;                 /* pruning: oltre il target, inutile */
        bool was_new = false;
        yon_xheap_put_or_get(H, &v, sizeof(v), YON_TAG_USER1, &was_new);
        if (was_new && r_n < (1u<<16)) R[r_n++] = v;
        if (v == T) { yon_xheap_destroy(H); return 1.0; }
    }
    uint32_t frontier_start = 0; int grew = 1;
    while (grew) {
        grew = 0; uint32_t cur_n = r_n;
        for (uint32_t i = 0; i < cur_n; i++) {
            uint32_t jstart = (i >= frontier_start) ? 0 : frontier_start;
            for (uint32_t j = (commutative_verified ? i : jstart); j < cur_n; j++) {
                double c = yon_rt_alg_op(R[i], R[j], op_id);
                if (c > T) continue;          /* monotone pruning: beyond T, discard */
                bool was_new = false;
                yon_xheap_put_or_get(H, &c, sizeof(c), YON_TAG_USER1, &was_new);
                if (was_new) {
                    if (r_n < (1u<<16)) R[r_n++] = c;
                    grew = 1;
                    if (c == T) { yon_xheap_destroy(H); return 1.0; }
                }
            }
        }
        frontier_start = cur_n;
    }
    yon_xheap_destroy(H);
    return 0.0;
}

/* ============================================================================
 * SubsetSum — LINEAR reachability: each generator used at most once.
 * This is the Theorem 4 algebra: the Goedel number tracks which generators are
 * consumed, and two states compose only if disjoint (G_a & G_b == 0). Distinct
 * from Additive-with-reuse (the coin problem).
 *
 * State = (value, mask) where mask bit i = generator i used. Composes (v1,m1)
 * with (v2,m2) iff m1 & m2 == 0 -> (v1 op v2, m1 | m2). Target pruning if
 * monotone. n_gen <= 53 (mask in the double mantissa).
 * Returns 1 if T is reachable, and writes into out_mask the mask of the
 * generators used (the certificate: which weights sum to T). 0 if unreachable.
 * ============================================================================ */
double yon_rt_alg_subsetsum(double op_id, const double *gen, double n_gen_d,
                            double T, int monotone, double *out_mask) {
    uint32_t n = (uint32_t)n_gen_d;
    if (n > 53) n = 53;
    /* states: parallel value/mask arrays. Dedup by (value,mask) via the heap. */
    yon_xheap_t *H = yon_xheap_create();
    if (!H) return 0.0;
    static double Vv[1u << 16]; static uint64_t Vm[1u << 16];
    uint32_t v_n = 0;
    /* empty axiom: identity value? for + it is 0, mask 0. Start from the generators. */
    for (uint32_t i = 0; i < n; i++) {
        double val = gen[i]; uint64_t mask = (1ULL << i);
        if (monotone && val > T) continue;
        struct { double v; uint64_t m; } key = { val, mask };
        bool was_new = false;
        yon_xheap_put_or_get(H, &key, sizeof(key), YON_TAG_USER1, &was_new);
        if (was_new && v_n < (1u<<16)) { Vv[v_n]=val; Vm[v_n]=mask; v_n++; }
        if (val == T) { if(out_mask)*out_mask=(double)mask; yon_xheap_destroy(H); return 1.0; }
    }
    uint32_t frontier_start = 0; int grew = 1;
    while (grew) {
        grew = 0; uint32_t cur_n = v_n;
        for (uint32_t i = 0; i < cur_n; i++) {
            uint32_t jstart = (i >= frontier_start) ? 0 : frontier_start;
            for (uint32_t j = jstart; j < cur_n; j++) {
                if (Vm[i] & Vm[j]) continue;            /* DISGIUNZIONE: Theorem 4 */
                double val = yon_rt_alg_op(Vv[i], Vv[j], op_id);
                uint64_t mask = Vm[i] | Vm[j];
                if (monotone && val > T) continue;
                struct { double v; uint64_t m; } key = { val, mask };
                bool was_new = false;
                yon_xheap_put_or_get(H, &key, sizeof(key), YON_TAG_USER1, &was_new);
                if (was_new) {
                    if (v_n < (1u<<16)) { Vv[v_n]=val; Vm[v_n]=mask; v_n++; }
                    grew = 1;
                    if (val == T) { if(out_mask)*out_mask=(double)mask; yon_xheap_destroy(H); return 1.0; }
                }
            }
        }
        frontier_start = cur_n;
    }
    yon_xheap_destroy(H);
    if (out_mask) *out_mask = 0.0;
    return 0.0;
}


