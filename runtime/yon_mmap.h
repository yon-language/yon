/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* yon_mmap.h — the one allocation primitive of the Yon runtime.
 *
 * mmap always: every runtime structure allocates through here, never malloc,
 * never a static array. The count of direct mmap sites in the runtime should
 * trend to zero as structures migrate onto this module.
 *
 *   yon_map        : private, anonymous, kernel-zeroed. The default for
 *                    everything that lives inside a single Space. Aborts on
 *                    failure — a runtime that cannot map its core structures
 *                    cannot meaningfully continue.
 *   yon_unmap      : release a region obtained from yon_map.
 *   yon_map_shared : the SOLE exception to private mapping. A named shared
 *                    region (shm_open + MAP_SHARED) for structures that cross
 *                    Space boundaries (shared heap, wire stream/RPC rings).
 *                    Returns NULL on failure so the caller can retry or fall
 *                    back; this is the base form, sites needing flock/EXCL
 *                    retry layer that on top. */
#ifndef YON_MMAP_H
#define YON_MMAP_H

#include <stddef.h>

void *yon_map(size_t size);
void  yon_unmap(void *p, size_t size);
void *yon_map_shared(const char *shm_name, size_t size, int create);

#endif /* YON_MMAP_H */
