/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_trie.c — the one persistent trie, on both stores and routers.
 *
 * Against a model (a plain array of entries), for each pair (store, router):
 * the FNV heap with the 32-bit hash route (HashMap), the Leech store with the
 * lattice route (XRelMap), and both stores with a 3-bit route that forces long
 * chains of keys with the same route. What is asserted:
 *   VALUES: after every put, find and size agree with the model; a put on a
 *     key already there replaces its value.
 *   PERSISTENCE: a root kept from before later puts still holds exactly what
 *     it held.
 *   CANONICAL SHAPE: the same entries put in another order give an equal trie
 *     (on the FNV heap, the same node).
 *   UNION / INTERSECTION by merging: the entries the model says, a's values
 *     on common keys; equal to the trie built by puts; union(a, a) and
 *     intersect(a, a) are a; union with the empty trie is the other side.
 *   ROUTE: the lattice route of every point of the shell is its MPHF index
 *     (exhaustive), and of any other key a first digit on the shell.
 *   STORE: names are made in sequence, node k at generation k div 196560 and
 *     shell index k mod 196560, across more than one generation. */
#include "yon_trie.h"
#include "yon_leech_store.h"
#include "yon_rt.h"
#include "leech_theta.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern uint32_t yon_mphf_index(uint32_t v);
extern uint32_t yon_mphf_unindex(uint32_t idx);

#define N YON_LEECH_TYPE2_COUNT
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint64_t next_rand(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

/* a 3-bit route: eight routes, so most keys share a chain */
static yon_trie_route_t tiny_route(uint64_t k) { yon_trie_route_t r = { (uint32_t)(k % 7u) & 7u, 0 }; return r; }
static const yon_trie_router_t tiny = { tiny_route, 3, 3 };

typedef struct { uint64_t k, v; } entry_t;
typedef struct { entry_t *e; uint32_t n; } model_t;

static int model_find(const model_t *m, uint64_t k, uint64_t *v) {
    for (uint32_t i = 0; i < m->n; i++) if (m->e[i].k == k) { if (v) *v = m->e[i].v; return 1; }
    return 0;
}
static void model_put(model_t *m, uint64_t k, uint64_t v) {
    for (uint32_t i = 0; i < m->n; i++) if (m->e[i].k == k) { m->e[i].v = v; return; }
    m->e[m->n].k = k; m->e[m->n].v = v; m->n++;
}

/* the model holds exactly the trie's entries */
typedef struct { const model_t *m; long bad, seen; } agree_ctx;
static void agree_visit(uint64_t k, uint64_t v, void *c) {
    agree_ctx *a = (agree_ctx *)c; uint64_t mv;
    a->seen++;
    if (!model_find(a->m, k, &mv) || mv != v) a->bad++;
}
static int agrees(const yon_trie_store_t *s, const yon_trie_router_t *r, uint32_t t, const model_t *m) {
    if (yon_trie_size(s, t) != m->n) return 0;
    agree_ctx a = { m, 0, 0 };
    yon_trie_each(s, t, agree_visit, &a);
    if (a.bad || a.seen != (long)m->n) return 0;
    for (uint32_t i = 0; i < m->n; i++) {
        uint64_t v;
        if (!yon_trie_find(s, r, t, m->e[i].k, &v) || v != m->e[i].v) return 0;
    }
    return 1;
}

static uint64_t pool_key(uint32_t i) {
    switch (i % 4) {
    case 0: return (uint64_t)yon_mphf_unindex((i * 7919u) % N);   /* a lattice point */
    case 1: { double d = (double)i * 0.5; uint64_t u; memcpy(&u, &d, 8); return u; }   /* a Number */
    case 2: return (uint64_t)i;                                       /* a small Int64 */
    default: return next_rand();                                      /* any 64 bits */
    }
}

#define POOL 3000u
#define OPS  12000u

static void exercise(const char *name, const yon_trie_store_t *s, const yon_trie_router_t *r, int same_node) {
    static uint64_t keys[POOL];
    for (uint32_t i = 0; i < POOL; i++) keys[i] = pool_key(i);

    model_t m = { calloc(POOL, sizeof(entry_t)), 0 };
    model_t snap_m = { calloc(POOL, sizeof(entry_t)), 0 };
    uint32_t t = s->empty(), snap = t;
    long bad_ops = 0;
    for (uint32_t op = 0; op < OPS; op++) {
        uint64_t k = keys[next_rand() % POOL], v = next_rand();
        t = yon_trie_put(s, r, t, k, v);
        model_put(&m, k, v);
        uint64_t got;
        if (!yon_trie_find(s, r, t, k, &got) || got != v) bad_ops++;
        if (op == OPS / 2) { snap = t; memcpy(snap_m.e, m.e, sizeof(entry_t) * m.n); snap_m.n = m.n; }
    }
    CHECK(bad_ops == 0, "%s: %ld puts not read back", name, bad_ops);
    CHECK(agrees(s, r, t, &m), "%s: the trie and the model differ", name);
    CHECK(agrees(s, r, snap, &snap_m), "%s: an older root changed", name);

    /* another order, the same entries */
    uint32_t u = s->empty();
    for (uint32_t i = m.n; i-- > 0;) u = yon_trie_put(s, r, u, m.e[i].k, m.e[i].v);
    CHECK(yon_trie_equal(s, t, u), "%s: the shape depends on the order", name);
    if (same_node) CHECK(t == u, "%s: equal tries are not the same node", name);

    /* union and intersection against the model and against puts */
    model_t a = { calloc(POOL, sizeof(entry_t)), 0 }, b = { calloc(POOL, sizeof(entry_t)), 0 };
    uint32_t ta = s->empty(), tb = s->empty();
    for (uint32_t i = 0; i < POOL; i++) {
        uint64_t x = next_rand();
        if (x % 3 != 0) { ta = yon_trie_put(s, r, ta, keys[i], i); model_put(&a, keys[i], i); }
        if (x % 5 < 2)  { tb = yon_trie_put(s, r, tb, keys[i], i + 1000000u); model_put(&b, keys[i], i + 1000000u); }
    }
    model_t mu = { calloc(2 * POOL, sizeof(entry_t)), 0 }, mi = { calloc(POOL, sizeof(entry_t)), 0 };
    for (uint32_t i = 0; i < a.n; i++) model_put(&mu, a.e[i].k, a.e[i].v);
    for (uint32_t i = 0; i < b.n; i++) if (!model_find(&a, b.e[i].k, NULL)) model_put(&mu, b.e[i].k, b.e[i].v);
    for (uint32_t i = 0; i < a.n; i++) if (model_find(&b, a.e[i].k, NULL)) model_put(&mi, a.e[i].k, a.e[i].v);
    uint32_t tu = yon_trie_union(s, r, ta, tb), ti = yon_trie_intersect(s, r, ta, tb);
    CHECK(agrees(s, r, tu, &mu), "%s: union differs from the model", name);
    CHECK(agrees(s, r, ti, &mi), "%s: intersection differs from the model", name);
    uint32_t pu = s->empty(), pi = s->empty();
    for (uint32_t i = 0; i < mu.n; i++) pu = yon_trie_put(s, r, pu, mu.e[i].k, mu.e[i].v);
    for (uint32_t i = 0; i < mi.n; i++) pi = yon_trie_put(s, r, pi, mi.e[i].k, mi.e[i].v);
    CHECK(yon_trie_equal(s, tu, pu), "%s: the merged union is not the canonical trie", name);
    CHECK(yon_trie_equal(s, ti, pi), "%s: the merged intersection is not the canonical trie", name);
    if (same_node) CHECK(tu == pu && ti == pi, "%s: merged and built tries are not the same node", name);
    CHECK(yon_trie_union(s, r, ta, ta) == ta, "%s: union(a, a) is not a", name);
    CHECK(yon_trie_intersect(s, r, ta, ta) == ta, "%s: intersect(a, a) is not a", name);
    CHECK(yon_trie_union(s, r, ta, s->empty()) == ta && yon_trie_union(s, r, s->empty(), tb) == tb,
          "%s: union with the empty trie is not the other side", name);
    CHECK(yon_trie_size(s, yon_trie_intersect(s, r, ta, s->empty())) == 0,
          "%s: intersection with the empty trie is not empty", name);
    printf("%s: %u entries, union %u, intersection %u\n", name, m.n, mu.n, mi.n);
    free(m.e); free(snap_m.e); free(a.e); free(b.e); free(mu.e); free(mi.e);
}

int main(void) {
    const yon_trie_store_t *fnv = yon_collections_fnv_store();
    const yon_trie_store_t *leech = yon_collections_leech_store();
    const yon_trie_router_t *hash32 = yon_collections_hash_router();
    const yon_trie_router_t *lattice = yon_collections_lattice_router();

    /* ROUTE: every point routes by its index */
    long bad_route = 0;
    for (uint32_t i = 0; i < N; i++) {
        yon_trie_route_t rt = lattice->route((uint64_t)yon_mphf_unindex(i));
        if (rt.d0 != i || rt.rest != 0) bad_route++;
    }
    CHECK(bad_route == 0, "route: %ld points not routed by their index", bad_route);
    long off_shell = 0;
    for (uint32_t i = 0; i < 100000; i++) if (lattice->route(next_rand()).d0 >= N) off_shell++;
    CHECK(off_shell == 0, "route: %ld hashed keys whose first digit is off the shell", off_shell);

    exercise("FNV heap, hash route", fnv, hash32, 1);
    exercise("Leech store, lattice route", leech, lattice, 0);
    exercise("FNV heap, 3-bit route", fnv, &tiny, 1);
    exercise("Leech store, 3-bit route", leech, &tiny, 0);

    /* every point of the shell in one Leech trie, past the first generation */
    uint32_t before = yon_leech_count(), t = leech->empty();
    for (uint32_t i = 0; i < N; i++) t = yon_trie_put(leech, lattice, t, (uint64_t)yon_mphf_unindex(i), i);
    long missing = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint64_t v;
        if (!yon_trie_find(leech, lattice, t, (uint64_t)yon_mphf_unindex(i), &v) || v != i) missing++;
    }
    CHECK(yon_trie_size(leech, t) == N, "shell: size %u", yon_trie_size(leech, t));
    CHECK(missing == 0, "shell: %ld points not found", missing);
    uint32_t made = yon_leech_count();
    CHECK(yon_leech_generation(made - 1) >= 1, "store: the shell trie stayed in generation 0");
    CHECK(yon_leech_generation(made - 1) == (made - 1) / N && yon_leech_index(made - 1) == (made - 1) % N,
          "store: node %u is not at (k div N, k mod N)", made - 1);
    printf("shell trie: %u nodes made (%u generations)\n", made - before, yon_leech_generation(made - 1) + 1);

    if (failures) { printf("TRIE: FAIL (%d)\n", failures); return 1; }
    printf("TRIE: PASS\n");
    return 0;
}
