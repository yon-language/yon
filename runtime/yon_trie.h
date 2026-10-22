/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* yon_trie.h — the persistent binary trie behind both families of
 * collections, parametrized on where its nodes live (the store) and on which
 * bits of a key choose a branch (the router).
 *
 *   HashMap / HashSet: nodes in the FNV heap (identity by content, so equal
 *     collections are the same node); the route is the 32-bit FNV-1a hash of
 *     the key's bits.
 *   XRelMap / XRelSet: nodes in the Leech heap's node store (the place
 *     (generation, point), written once); the route of a lattice point is its
 *     MPHF index, exact, and of any other key its 64-bit hash written in base
 *     196560: the first digit a point of the shell, then the rest.
 *
 * A collection is a value: put returns a new root and leaves the one it was
 * given. The shape of a trie depends only on its entries, never on the order
 * they went in: a prefix holding no key is EMPTY, one whose keys all have the
 * same route is a LEAF (a chain sorted by the keys' bits), any other a BRANCH
 * on the next route bit. Keys and values are 64-bit patterns; a key is
 * identified by its bits. */
#ifndef YON_TRIE_H
#define YON_TRIE_H

#include <stdint.h>

#define YON_TRIE_NONE 0xFFFFFFFFu   /* no node: the end of a chain */

typedef struct {
    uint32_t (*put)(const void *node, uint32_t size);   /* a new node, written once */
    const void *(*at)(uint32_t ref);                     /* the node at ref */
    uint32_t (*empty)(void);                             /* the empty node */
} yon_trie_store_t;

/* A route: d0 holds the first `width0` bits, rest the bits after them. Two
 * keys with the same route share a chain. */
typedef struct { uint32_t d0; uint64_t rest; } yon_trie_route_t;

typedef struct {
    yon_trie_route_t (*route)(uint64_t key);
    uint32_t width0;   /* bits of d0 the trie reads before rest */
    uint32_t bits;     /* route bits in all: past them only a chain remains */
} yon_trie_router_t;

uint32_t yon_trie_put(const yon_trie_store_t *s, const yon_trie_router_t *r,
                      uint32_t root, uint64_t key, uint64_t value);
/* 1 and the value in *out when the key is in the trie, 0 otherwise */
int      yon_trie_find(const yon_trie_store_t *s, const yon_trie_router_t *r,
                       uint32_t root, uint64_t key, uint64_t *out);
uint32_t yon_trie_size(const yon_trie_store_t *s, uint32_t root);

typedef void (*yon_trie_visit_fn)(uint64_t key, uint64_t value, void *ctx);
void     yon_trie_each(const yon_trie_store_t *s, uint32_t root,
                       yon_trie_visit_fn f, void *ctx);

/* The keys of a and of b; a key in both keeps a's value. Merges the two
 * tries: a subtree the two share is reused, not walked. */
uint32_t yon_trie_union(const yon_trie_store_t *s, const yon_trie_router_t *r,
                        uint32_t a, uint32_t b);
/* The keys in both, with a's values. */
uint32_t yon_trie_intersect(const yon_trie_store_t *s, const yon_trie_router_t *r,
                            uint32_t a, uint32_t b);
/* Same entries, node by node (the shape is canonical, so this is equality). */
int      yon_trie_equal(const yon_trie_store_t *s, uint32_t a, uint32_t b);

/* The stores and routers of the collections (yon_rt.c): the FNV heap and
 * the 32-bit hash route of HashMap / HashSet, the Leech node store and the
 * lattice route of XRelMap / XRelSet. */
const yon_trie_store_t  *yon_collections_fnv_store(void);
const yon_trie_store_t  *yon_collections_leech_store(void);
const yon_trie_router_t *yon_collections_hash_router(void);
const yon_trie_router_t *yon_collections_lattice_router(void);

#endif /* YON_TRIE_H */
