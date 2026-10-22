/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* bench_reclaim_growth.c — how memory grows when nothing is reclaimed.
 *
 * Repeats the work of regression/bench/maps_compare, R rounds: a map of N
 * Number keys built by N persistent sets, two sets of N keys sharing N/2, their
 * union and intersection. Each round's values are dropped before the next one
 * (nothing holds them), so everything a round made is unreachable after it.
 * Two workloads: SAME, every round builds the same keys; SHIFTED, round r uses
 * keys from r * N on (a map whose contents change). After each round, per heap:
 *   reach   the nodes reachable from the round's five values (a DAG walk)
 *   made    every node the heap holds (FNV: occupied slots; Leech: names made)
 *   bytes   FNV: the payload bytes of its arenas; Leech: made * 40
 * Neither heap reclaims, so made - reach after a round is what a reclaimer
 * would free. Build it in runtime/ as bench_trie_nodes.c is. */
#include "yon_trie.h"
#include "yon_leech_store.h"
#include "xleech2_heap.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { T_EMPTY = 0, T_LEAF = 1, T_BRANCH = 2 };

static uint64_t bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }

/* distinct nodes reachable from a set of roots */
typedef struct { uint32_t *keys; uint64_t cap, n; } refset_t;
static int refset_add(refset_t *s, uint32_t r) {
    uint64_t h = (r * 2654435761u) & (s->cap - 1);
    while (s->keys[h] != 0xFFFFFFFFu) { if (s->keys[h] == r) return 0; h = (h + 1) & (s->cap - 1); }
    s->keys[h] = r; s->n++; return 1;
}
static void walk(const yon_trie_store_t *st, uint32_t r, refset_t *s) {
    if (r == 0xFFFFFFFFu || !refset_add(s, r)) return;
    const uint32_t *p = (const uint32_t *)st->at(r);
    if (p[0] == T_BRANCH) { walk(st, p[2], s); walk(st, p[3], s); }
    else if (p[0] == T_LEAF) walk(st, p[2], s);   /* next in the chain */
}

static void fnv_counts(uint64_t *made, uint64_t *bytes) {
    *made = 0; *bytes = 0;
    for (uint32_t i = 0; i < yon_xheap_registry_count(); i++) {
        yon_xheap_t *h = yon_xheap_registry_get(i);
        if (!h) continue;
        *made += h->n_occupied; *bytes += h->arena_used;
    }
}

static void round_of(const yon_trie_store_t *s, const yon_trie_router_t *r, uint32_t n,
                     uint32_t from, uint32_t roots[5]) {
    uint32_t m = s->empty(), a = s->empty(), b = s->empty();
    for (uint32_t k = 0; k < n; k++) m = yon_trie_put(s, r, m, bits((from + k) * 0.5), bits((double)k));
    for (uint32_t k = 0; k < n; k++) a = yon_trie_put(s, r, a, bits((from + k) * 0.5), bits(1.0));
    for (uint32_t k = 0; k < n; k++) b = yon_trie_put(s, r, b, bits((from + n / 2 + k) * 0.5), bits(1.0));
    roots[0] = m; roots[1] = a; roots[2] = b;
    roots[3] = yon_trie_union(s, r, a, b);
    roots[4] = yon_trie_intersect(s, r, a, b);
}

int main(int argc, char **argv) {
    uint32_t n = argc > 1 ? (uint32_t)atoi(argv[1]) : 100000;
    uint32_t rounds = argc > 2 ? (uint32_t)atoi(argv[2]) : 8;
    const yon_trie_store_t *fnv = yon_collections_fnv_store(), *leech = yon_collections_leech_store();
    refset_t rs = { malloc(sizeof(uint32_t) * (1u << 25)), 1u << 25, 0 };
    printf("workload family round reach made bytes\n");
    for (int shifted = 0; shifted < 2; shifted++)
        for (int fam = 0; fam < 2; fam++) {
            const yon_trie_store_t *s = fam ? leech : fnv;
            const yon_trie_router_t *r = fam ? yon_collections_lattice_router() : yon_collections_hash_router();
            uint64_t made0, bytes0, m1, b1;
            if (fam) { made0 = yon_leech_count(); bytes0 = made0 * YON_LEECH_NODE_BYTES; }
            else fnv_counts(&made0, &bytes0);
            for (uint32_t rd = 1; rd <= rounds; rd++) {
                uint32_t roots[5];
                round_of(s, r, n, shifted ? rd * n * 2 : 0, roots);
                memset(rs.keys, 0xFF, sizeof(uint32_t) * rs.cap); rs.n = 0;
                for (int i = 0; i < 5; i++) walk(s, roots[i], &rs);
                if (fam) { m1 = yon_leech_count(); b1 = m1 * YON_LEECH_NODE_BYTES; }
                else fnv_counts(&m1, &b1);
                printf("%s %s %u %llu %llu %llu\n", shifted ? "shifted" : "same", fam ? "xrel" : "hash", rd,
                       (unsigned long long)rs.n, (unsigned long long)(m1 - made0),
                       (unsigned long long)(b1 - bytes0));
                fflush(stdout);
            }
        }
    free(rs.keys);
    return 0;
}
