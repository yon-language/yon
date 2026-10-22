/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* yon_leech_store.h — the node store of the Leech heap.
 *
 * Node k lives in the place (generation k div 196560, point
 * at_index(k mod 196560)): a generation is one table over the type-2 shell,
 * its slot i the place of the i-th point. Nodes are made in sequence and
 * written once, when they are made; nothing is written on a node after.
 * There is no index by content: two equal nodes are two places, and equality
 * of what they hold is structural. A generation is mapped on its first node.
 * The name k is 32 bits wide: 2^32 - 1 nodes, then the store says it is
 * exhausted. */
#ifndef YON_LEECH_STORE_H
#define YON_LEECH_STORE_H

#include <stdint.h>

#define YON_LEECH_NODE_BYTES 40u   /* one slot: the largest trie node */

/* a new node holding size bytes (at most YON_LEECH_NODE_BYTES); its name */
uint32_t    yon_leech_put(const void *node, uint32_t size);
/* the node named k */
const void *yon_leech_at(uint32_t k);
/* the generation and the shell index of node k's place */
uint32_t    yon_leech_generation(uint32_t k);
uint32_t    yon_leech_index(uint32_t k);
/* nodes made so far */
uint32_t    yon_leech_count(void);

#endif /* YON_LEECH_STORE_H */
