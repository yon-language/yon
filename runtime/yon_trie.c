/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* yon_trie.c — the persistent binary trie (see yon_trie.h).
 *
 * No node is ever written after the store hands it back: an update copies
 * the path from the root to the key and shares everything else, and union and
 * intersection reuse every subtree that comes out unchanged. */
#include "yon_trie.h"

#include <stdio.h>
#include <stdlib.h>

enum { T_EMPTY = 0, T_LEAF = 1, T_BRANCH = 2 };

typedef struct { uint32_t kind, size, child[2]; } branch_t;
typedef struct {
    uint32_t kind, size;   /* size: keys in this chain, from here */
    uint32_t next;         /* the next key with the same route, or YON_TRIE_NONE */
    uint32_t d0;
    uint64_t rest, key, value;
} leaf_t;

static const uint32_t *node(const yon_trie_store_t *s, uint32_t ref) {
    const uint32_t *p = (const uint32_t *)s->at(ref);
    if (!p || p[0] > T_BRANCH) {
        fprintf(stderr, "[YON-RT] trie: %u is not a node\n", ref);
        abort();
    }
    return p;
}
static uint32_t kind(const yon_trie_store_t *s, uint32_t ref) { return node(s, ref)[0]; }

uint32_t yon_trie_size(const yon_trie_store_t *s, uint32_t ref) {
    if (ref == YON_TRIE_NONE) return 0;
    return node(s, ref)[1];   /* 0 for the empty trie */
}

static uint32_t mk_leaf(const yon_trie_store_t *s, yon_trie_route_t rt,
                        uint64_t k, uint64_t v, uint32_t next) {
    leaf_t l = { T_LEAF, 1 + yon_trie_size(s, next), next, rt.d0, rt.rest, k, v };
    return s->put(&l, sizeof l);
}
static uint32_t mk_branch(const yon_trie_store_t *s, uint32_t c0, uint32_t c1) {
    branch_t b = { T_BRANCH, yon_trie_size(s, c0) + yon_trie_size(s, c1), { c0, c1 } };
    return s->put(&b, sizeof b);
}

static int route_eq(yon_trie_route_t a, yon_trie_route_t b) { return a.d0 == b.d0 && a.rest == b.rest; }
static yon_trie_route_t leaf_route(const leaf_t *l) { yon_trie_route_t r = { l->d0, l->rest }; return r; }
static uint32_t bit(const yon_trie_router_t *r, yon_trie_route_t rt, unsigned depth) {
    if (depth < r->width0) return (rt.d0 >> depth) & 1u;
    return (uint32_t)((rt.rest >> (depth - r->width0)) & 1u);
}

/* put into a chain of keys with route rt, kept sorted by the keys' bits */
static uint32_t chain_put(const yon_trie_store_t *s, uint32_t ref, yon_trie_route_t rt,
                          uint64_t k, uint64_t v) {
    if (ref == YON_TRIE_NONE) return mk_leaf(s, rt, k, v, YON_TRIE_NONE);
    const leaf_t *l = (const leaf_t *)node(s, ref);
    uint64_t lk = l->key, lv = l->value;
    uint32_t ln = l->next;
    if (k == lk) return mk_leaf(s, rt, k, v, ln);
    if (k < lk)  return mk_leaf(s, rt, k, v, ref);
    return mk_leaf(s, rt, lk, lv, chain_put(s, ln, rt, k, v));
}

static uint32_t put_at(const yon_trie_store_t *s, const yon_trie_router_t *r, uint32_t ref,
                       yon_trie_route_t rt, uint64_t k, uint64_t v, unsigned depth) {
    const uint32_t *p = node(s, ref);
    if (p[0] == T_EMPTY) return mk_leaf(s, rt, k, v, YON_TRIE_NONE);
    if (p[0] == T_LEAF) {
        yon_trie_route_t lr = leaf_route((const leaf_t *)p);
        if (route_eq(lr, rt)) return chain_put(s, ref, rt, k, v);
        uint32_t bn = bit(r, rt, depth), bo = bit(r, lr, depth);
        if (bn == bo) {
            uint32_t sub = put_at(s, r, ref, rt, k, v, depth + 1);
            uint32_t e = s->empty();
            return bn ? mk_branch(s, e, sub) : mk_branch(s, sub, e);
        }
        uint32_t nl = mk_leaf(s, rt, k, v, YON_TRIE_NONE);
        return bn ? mk_branch(s, ref, nl) : mk_branch(s, nl, ref);
    }
    const branch_t *b = (const branch_t *)p;
    uint32_t c0 = b->child[0], c1 = b->child[1];
    if (bit(r, rt, depth)) c1 = put_at(s, r, c1, rt, k, v, depth + 1);
    else                   c0 = put_at(s, r, c0, rt, k, v, depth + 1);
    return mk_branch(s, c0, c1);
}

uint32_t yon_trie_put(const yon_trie_store_t *s, const yon_trie_router_t *r,
                      uint32_t root, uint64_t key, uint64_t value) {
    return put_at(s, r, root, r->route(key), key, value, 0);
}

static int find_at(const yon_trie_store_t *s, const yon_trie_router_t *r, uint32_t ref,
                   yon_trie_route_t rt, uint64_t k, unsigned depth, uint64_t *out) {
    for (;; depth++) {
        const uint32_t *p = node(s, ref);
        if (p[0] == T_EMPTY) return 0;
        if (p[0] == T_LEAF) {
            const leaf_t *l = (const leaf_t *)p;
            if (!route_eq(leaf_route(l), rt)) return 0;
            for (;;) {
                if (l->key == k) { if (out) *out = l->value; return 1; }
                if (l->next == YON_TRIE_NONE) return 0;
                l = (const leaf_t *)node(s, l->next);
            }
        }
        ref = ((const branch_t *)p)->child[bit(r, rt, depth)];
    }
}

int yon_trie_find(const yon_trie_store_t *s, const yon_trie_router_t *r,
                  uint32_t root, uint64_t key, uint64_t *out) {
    return find_at(s, r, root, r->route(key), key, 0, out);
}

void yon_trie_each(const yon_trie_store_t *s, uint32_t ref, yon_trie_visit_fn f, void *ctx) {
    const uint32_t *p = node(s, ref);
    if (p[0] == T_EMPTY) return;
    if (p[0] == T_LEAF) {
        for (const leaf_t *l = (const leaf_t *)p;;) {
            f(l->key, l->value, ctx);
            if (l->next == YON_TRIE_NONE) return;
            l = (const leaf_t *)node(s, l->next);
        }
    }
    const branch_t *b = (const branch_t *)p;
    uint32_t c0 = b->child[0], c1 = b->child[1];
    yon_trie_each(s, c0, f, ctx);
    yon_trie_each(s, c1, f, ctx);
}

static uint32_t union_at(const yon_trie_store_t *s, const yon_trie_router_t *r,
                         uint32_t a, uint32_t b, unsigned depth) {
    if (a == b) return a;
    const uint32_t *pa = node(s, a), *pb = node(s, b);
    if (pa[0] == T_EMPTY) return b;
    if (pb[0] == T_EMPTY) return a;
    if (pa[0] == T_LEAF) {   /* a's entries into b: a's values win */
        uint32_t out = b;
        for (const leaf_t *l = (const leaf_t *)pa;;) {
            out = put_at(s, r, out, leaf_route(l), l->key, l->value, depth);
            if (l->next == YON_TRIE_NONE) return out;
            l = (const leaf_t *)node(s, l->next);
        }
    }
    if (pb[0] == T_LEAF) {   /* b's entries a lacks, into a */
        uint32_t out = a;
        for (const leaf_t *l = (const leaf_t *)pb;;) {
            if (!find_at(s, r, out, leaf_route(l), l->key, depth, NULL))
                out = put_at(s, r, out, leaf_route(l), l->key, l->value, depth);
            if (l->next == YON_TRIE_NONE) return out;
            l = (const leaf_t *)node(s, l->next);
        }
    }
    const branch_t *ba = (const branch_t *)pa, *bb = (const branch_t *)pb;
    uint32_t a0 = ba->child[0], a1 = ba->child[1], b0 = bb->child[0], b1 = bb->child[1];
    uint32_t u0 = union_at(s, r, a0, b0, depth + 1);
    uint32_t u1 = union_at(s, r, a1, b1, depth + 1);
    if (u0 == a0 && u1 == a1) return a;
    if (u0 == b0 && u1 == b1) return b;
    return mk_branch(s, u0, u1);
}

uint32_t yon_trie_union(const yon_trie_store_t *s, const yon_trie_router_t *r,
                        uint32_t a, uint32_t b) {
    return union_at(s, r, a, b, 0);
}

static uint32_t inter_at(const yon_trie_store_t *s, const yon_trie_router_t *r,
                         uint32_t a, uint32_t b, unsigned depth) {
    if (a == b) return a;
    const uint32_t *pa = node(s, a), *pb = node(s, b);
    if (pa[0] == T_EMPTY) return a;
    if (pb[0] == T_EMPTY) return b;
    if (pa[0] == T_LEAF || pb[0] == T_LEAF) {
        /* walk the chain, keep what the other side holds, with a's values */
        int a_leaf = pa[0] == T_LEAF;
        const leaf_t *l = (const leaf_t *)(a_leaf ? pa : pb);
        uint32_t other = a_leaf ? b : a;
        uint32_t out = s->empty(), kept = 0, walked = 0;
        for (;;) {
            uint64_t va;
            if (find_at(s, r, other, leaf_route(l), l->key, depth, &va)) {
                out = put_at(s, r, out, leaf_route(l), l->key, a_leaf ? l->value : va, depth);
                kept++;
            }
            walked++;
            if (l->next == YON_TRIE_NONE) break;
            l = (const leaf_t *)node(s, l->next);
        }
        return (a_leaf && kept == walked) ? a : out;
    }
    const branch_t *ba = (const branch_t *)pa, *bb = (const branch_t *)pb;
    uint32_t a0 = ba->child[0], a1 = ba->child[1];
    uint32_t i0 = inter_at(s, r, a0, bb->child[0], depth + 1);
    uint32_t i1 = inter_at(s, r, a1, bb->child[1], depth + 1);
    if (i0 == a0 && i1 == a1) return a;
    uint32_t k0 = kind(s, i0), k1 = kind(s, i1);
    /* the canonical shape: no keys is EMPTY, keys of one route a LEAF */
    if (k0 == T_EMPTY && k1 != T_BRANCH) return i1;
    if (k1 == T_EMPTY && k0 != T_BRANCH) return i0;
    return mk_branch(s, i0, i1);
}

uint32_t yon_trie_intersect(const yon_trie_store_t *s, const yon_trie_router_t *r,
                            uint32_t a, uint32_t b) {
    return inter_at(s, r, a, b, 0);
}

int yon_trie_equal(const yon_trie_store_t *s, uint32_t a, uint32_t b) {
    if (a == b) return 1;
    if (a == YON_TRIE_NONE || b == YON_TRIE_NONE) return 0;
    const uint32_t *pa = node(s, a), *pb = node(s, b);
    if (pa[0] != pb[0] || pa[1] != pb[1]) return 0;
    if (pa[0] == T_EMPTY) return 1;
    if (pa[0] == T_LEAF) {
        const leaf_t *x = (const leaf_t *)pa, *y = (const leaf_t *)pb;
        if (x->key != y->key || x->value != y->value || !route_eq(leaf_route(x), leaf_route(y)))
            return 0;
        return yon_trie_equal(s, x->next, y->next);
    }
    const branch_t *x = (const branch_t *)pa, *y = (const branch_t *)pb;
    return yon_trie_equal(s, x->child[0], y->child[0]) && yon_trie_equal(s, x->child[1], y->child[1]);
}
