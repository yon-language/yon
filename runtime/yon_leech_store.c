/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* yon_leech_store.c — the node store of the Leech heap (see the header). */
#include "yon_leech_store.h"
#include "leech_theta.h"   /* YON_LEECH_TYPE2_COUNT */
#include "yon_mmap.h"      /* yon_map / yon_unmap */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N YON_LEECH_TYPE2_COUNT
#define GEN_BYTES ((size_t)N * YON_LEECH_NODE_BYTES)
/* every name a 32-bit k can take has a generation */
#define N_GENERATIONS ((uint32_t)((0xFFFFFFFFull + N - 1) / N))

/* One store per Space: its generation directory, its next name, its empty
 * node. The store the puts and reads go to is the current Space's. */
typedef struct {
    uint8_t *volatile *gens;   /* the directory, mapped on the first put */
    uint32_t next;             /* the next name */
    uint32_t empty;            /* the empty node, made once */
} leech_store_t;

#define N_STORES 65536u          /* a Space is 16 bits of a marked name */
static leech_store_t *volatile *g_stores;   /* the stores, mapped once */
static uint32_t g_cur;                      /* the current Space */
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_gen_lock = PTHREAD_MUTEX_INITIALIZER;

static void stores_init(void) {
    g_stores = (leech_store_t *volatile *)yon_map((size_t)N_STORES * sizeof(leech_store_t *));
}

static leech_store_t *store_of(uint32_t space) {
    pthread_once(&g_once, stores_init);
    leech_store_t *st = g_stores[space];
    if (st) return st;
    pthread_mutex_lock(&g_gen_lock);
    st = g_stores[space];
    if (!st) {
        st = (leech_store_t *)yon_map(sizeof *st);
        st->gens = (uint8_t *volatile *)yon_map((size_t)N_GENERATIONS * sizeof(uint8_t *));
        st->empty = 0xFFFFFFFFu;
        __atomic_store_n(&g_stores[space], st, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_gen_lock);
    return st;
}

void yon_leech_select(uint32_t space) { g_cur = space % N_STORES; }
uint32_t yon_leech_current(void) { return g_cur; }

static uint8_t *generation(leech_store_t *st, uint32_t g) {
    uint8_t *t = st->gens[g];
    if (t) return t;
    pthread_mutex_lock(&g_gen_lock);
    t = st->gens[g];
    if (!t) {
        t = (uint8_t *)yon_map(GEN_BYTES);
        __atomic_store_n(&st->gens[g], t, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_gen_lock);
    return t;
}

uint32_t yon_leech_put(const void *node, uint32_t size) {
    leech_store_t *st = store_of(g_cur);
    if (size > YON_LEECH_NODE_BYTES) {
        fprintf(stderr, "[YON-RT] Leech store: a node of %u bytes does not fit a place\n", size);
        abort();
    }
    uint32_t k = __atomic_fetch_add(&st->next, 1u, __ATOMIC_RELAXED);
    if (k == 0xFFFFFFFFu) {
        fprintf(stderr, "[YON-RT] Leech store: every 32-bit name is taken\n");
        abort();
    }
    uint8_t *slot = generation(st, k / N) + (size_t)(k % N) * YON_LEECH_NODE_BYTES;
    memcpy(slot, node, size);
    return k;
}

uint32_t yon_leech_empty(const void *node, uint32_t size) {
    leech_store_t *st = store_of(g_cur);
    if (st->empty == 0xFFFFFFFFu) st->empty = yon_leech_put(node, size);
    return st->empty;
}

/* A name reaches a reader only from a put that made it, so the directory and
 * the node's generation exist by then; a name never made has no node. */
const void *yon_leech_at(uint32_t k) {
    leech_store_t *st = store_of(g_cur);
    if (k >= __atomic_load_n(&st->next, __ATOMIC_ACQUIRE)) return NULL;
    uint8_t *t = __atomic_load_n(&st->gens[k / N], __ATOMIC_ACQUIRE);
    return t ? t + (size_t)(k % N) * YON_LEECH_NODE_BYTES : NULL;
}

uint32_t yon_leech_generation(uint32_t k) { return k / N; }
uint32_t yon_leech_index(uint32_t k)      { return k % N; }
uint32_t yon_leech_count(void) {
    return __atomic_load_n(&store_of(g_cur)->next, __ATOMIC_ACQUIRE);
}
