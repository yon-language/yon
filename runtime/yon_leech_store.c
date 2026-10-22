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

static uint8_t *volatile *g_generations;   /* the directory, mapped once */
static uint32_t g_next;                    /* the next name */
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_gen_lock = PTHREAD_MUTEX_INITIALIZER;

static void store_init(void) {
    g_generations = (uint8_t *volatile *)yon_map((size_t)N_GENERATIONS * sizeof(uint8_t *));
}

static uint8_t *generation(uint32_t g) {
    uint8_t *t = g_generations[g];
    if (t) return t;
    pthread_mutex_lock(&g_gen_lock);
    t = g_generations[g];
    if (!t) {
        t = (uint8_t *)yon_map(GEN_BYTES);
        __atomic_store_n(&g_generations[g], t, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_gen_lock);
    return t;
}

uint32_t yon_leech_put(const void *node, uint32_t size) {
    pthread_once(&g_once, store_init);
    if (size > YON_LEECH_NODE_BYTES) {
        fprintf(stderr, "[YON-RT] Leech store: a node of %u bytes does not fit a place\n", size);
        abort();
    }
    uint32_t k = __atomic_fetch_add(&g_next, 1u, __ATOMIC_RELAXED);
    if (k == 0xFFFFFFFFu) {
        fprintf(stderr, "[YON-RT] Leech store: every 32-bit name is taken\n");
        abort();
    }
    uint8_t *slot = generation(k / N) + (size_t)(k % N) * YON_LEECH_NODE_BYTES;
    memcpy(slot, node, size);
    return k;
}

const void *yon_leech_at(uint32_t k) {
    pthread_once(&g_once, store_init);
    if (k >= __atomic_load_n(&g_next, __ATOMIC_ACQUIRE)) return NULL;
    uint8_t *t = __atomic_load_n(&g_generations[k / N], __ATOMIC_ACQUIRE);
    return t ? t + (size_t)(k % N) * YON_LEECH_NODE_BYTES : NULL;
}

uint32_t yon_leech_generation(uint32_t k) { return k / N; }
uint32_t yon_leech_index(uint32_t k)      { return k % N; }
uint32_t yon_leech_count(void)            { return __atomic_load_n(&g_next, __ATOMIC_ACQUIRE); }
