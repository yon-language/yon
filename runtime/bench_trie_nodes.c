/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* bench_trie_nodes.c — how many nodes a map costs on each store.
 *
 * Builds a map of N keys by N persistent sets (Number keys k * 0.5, as in
 * regression/bench/maps_compare), once on the FNV heap with the hash route
 * (HashMap) and once on the Leech store with the lattice route (XRelMap),
 * through the same trie code, and counts the nodes each store made. On the
 * FNV heap a node whose content is already there is not made again (it is
 * the same node), so the count is the distinct nodes; on the Leech store every
 * node is a new place. Then builds the same map a second time: on the FNV heap
 * nothing new is made, on the Leech store everything is.
 *
 * Build it in runtime/ against the runtime objects (yon_rt.o yon_mmap.o
 * leech_orbits.o yon_arena.o yon_curtis_canon.o yon_trie.o yon_leech_store.o
 * xleech2_coord.o xleech2_heap.o xleech2_mphf.o, every vendor/mmgroup object)
 * and ../regression/_dispatch_stub.c, with -lpthread -lm, as bench_ds.c is.
 *
 * Output: N, FNV nodes, FNV nodes on the rebuild, Leech nodes, Leech nodes on
 * the rebuild, one line per N. */
#include "yon_trie.h"
#include "yon_leech_store.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const yon_trie_store_t *g_inner;
static uint8_t *g_seen;          /* FNV refs already made */
static uint64_t g_seen_bytes;
static uint64_t g_new;

static uint32_t counting_put(const void *n, uint32_t sz) {
    uint32_t r = g_inner->put(n, sz);
    if (r / 8u >= g_seen_bytes) {
        uint64_t nb = (uint64_t)r / 8u * 2u + 1024u;
        g_seen = realloc(g_seen, nb);
        memset(g_seen + g_seen_bytes, 0, nb - g_seen_bytes);
        g_seen_bytes = nb;
    }
    if (!(g_seen[r / 8u] & (1u << (r % 8u)))) { g_seen[r / 8u] |= (uint8_t)(1u << (r % 8u)); g_new++; }
    return r;
}
static const void *counting_at(uint32_t r) { return g_inner->at(r); }
static uint32_t counting_empty(void) { return g_inner->empty(); }

static uint64_t bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }

static uint64_t build_fnv(uint32_t n) {
    const yon_trie_store_t s = { counting_put, counting_at, counting_empty };
    g_inner = yon_collections_fnv_store();
    uint64_t before = g_new;
    uint32_t m = s.empty();
    for (uint32_t k = 0; k < n; k++)
        m = yon_trie_put(&s, yon_collections_hash_router(), m, bits(k * 0.5), bits((double)k));
    return g_new - before;
}

static uint64_t build_leech(uint32_t n) {
    const yon_trie_store_t *s = yon_collections_leech_store();
    uint32_t before = yon_leech_count();
    uint32_t m = s->empty();
    for (uint32_t k = 0; k < n; k++)
        m = yon_trie_put(s, yon_collections_lattice_router(), m, bits(k * 0.5), bits((double)k));
    return yon_leech_count() - before;
}

int main(void) {
    uint32_t sizes[] = { 1000, 10000, 100000, 400000 };
    printf("N fnv fnv_rebuild leech leech_rebuild (nodes; a Leech node is %u bytes)\n",
           YON_LEECH_NODE_BYTES);
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        uint32_t n = sizes[i];
        uint64_t f1 = build_fnv(n), f2 = build_fnv(n);
        uint64_t l1 = build_leech(n), l2 = build_leech(n);
        printf("%u %llu %llu %llu %llu\n", n, (unsigned long long)f1, (unsigned long long)f2,
               (unsigned long long)l1, (unsigned long long)l2);
        fflush(stdout);
    }
    return 0;
}
