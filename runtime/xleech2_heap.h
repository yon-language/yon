/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* xleech2_heap.h — content-addressed HexHeap with a hybrid design
 * (tile-based arena + content_index for dedup).
 *
 * Achieves a 0-collision design on the arena while preserving
 * content-addressing (natural dedup).
 *
 * HYBRID DESIGN:
 *   slots[]         = tile-based arena of payloads (sequential slot_index)
 *   content_index[] = parallel hash table: content_hash -> slot_index
 *
 *   yon_xheap_put(payload, n_bytes) returns slot_index in [0, N_SLOTS).
 *   If the payload was already present (same content), returns the existing
 *   slot_index. If new, allocates a sequential slot and records the hash in
 *   the content_index.
 *
 *   yon_xheap_get(slot_index) returns the slot directly (strictly O(1)).
 *
 * INVARIANTS:
 *   - slot_index is stable for the life of the heap (no rehashing/move)
 *   - content_index may have collisions (linear probing), but these do not
 *     cause physical-slot collisions: two payloads with colliding hashes
 *     occupy different slots in the arena
 *
 * BACKING:
 *   The struct is still a contiguous, mmap-relocatable block. Same pluggable
 *   backing as before (PRIVATE/SHM).
 *
 * SIZING:
 *   N_SLOTS         = 196,560 (the rational maximum = #type-2 vectors)
 *   N_INDEX         = 294,913 (~1.5x N_SLOTS, load factor ~2/3 when full)
 *   ARENA_BYTES     = 64 MB
 *   Total           ~70.5 MB per heap (~same as the previous design)
 */

#ifndef YON_XLEECH2_HEAP_H
#define YON_XLEECH2_HEAP_H

#include "xleech2_coord.h"
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#define YON_HEAP_N_SLOTS      196560u
#define YON_HEAP_N_INDEX      294913u    /* ~1.5x 196560, load factor ~2/3 */
#define YON_HEAP_ARENA_BYTES  (64u * 1024u * 1024u)
#define YON_HEAP_MAGIC        0x594F4E48u  /* "YONH" */
#define YON_HEAP_VERSION      2u           /* bumped for the hybrid design */

/* Slot invalid sentinel. */
#define YON_HEAP_SLOT_INVALID 0xFFFFFFFFu

/* Possible tags. FREE = never used; in_use = 0 is implicit from the tag.
 * In the hybrid design there are no tombstones: slots are never moved, and
 * clear merely marks the slot as free (releasable to a free-list, a future
 * phase). */
typedef enum {
    YON_TAG_FREE = 0,   /* slot never used (or freed) */
    YON_TAG_FACT,
    YON_TAG_PLACE,
    YON_TAG_USER1,
    YON_TAG_USER2,
    YON_TAG_USER3,  /* node3/node4 multi-arity Merkle */
} yon_xtag_t;

/* Arena slot: payload + tag + size + schema_version. No more xcoord key: the
 * slot_index is the identifier. The content hash lives in the parallel
 * content_index.
 *
 * schema_version encodes which schema version the payload was written with.
 * yon_rt_field_load can apply a lazy migration if the version requested by the
 * caller differs. */
typedef struct {
    uint32_t tag;             /* yon_xtag_t */
    uint32_t payload_offset;  /* offset in arena[], 0 = none */
    uint32_t payload_size;
    uint32_t schema_version;  /* 0 = legacy/unspecified, >=1 = versioned */
} yon_xheap_slot_t;

/* A content_index entry: (hash64 + slot_index). Open addressing with linear
 * probing. hash == 0 and slot_index == INVALID = an empty entry. */
typedef struct {
    uint64_t hash;            /* content hash (FNV-1a 64) */
    uint32_t slot_index;      /* in [0, N_SLOTS), or INVALID if the entry is empty */
    uint32_t reserved;        /* 16-byte alignment */
} yon_xheap_index_entry_t;

/* Heap: a contiguous, mmap-relocatable struct.
 *
 * heap_id supports a chain of heaps. Each heap is registered in
 * g_heap_registry[256] at creation. yon_xheap_put_chain follows the chain if
 * the first heap is full; yon_xheap_get_chain decodes a global heapref into
 * (heap_id, local_slot).
 *
 * Memory layout (increasing offsets):
 *   header (16 + 4-byte heap_id + 12 padding = 32 bytes)
 *   slots[N_SLOTS]         ~3.0 MB
 *   content_index[N_INDEX] ~4.7 MB
 *   arena[ARENA_BYTES]     64 MB
 */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t n_occupied;
    uint32_t arena_used;
    uint32_t heap_id;         /* registry id in [0, 256) */
    uint32_t reserved[3];     /* 32-byte alignment */
    yon_xheap_slot_t        slots[YON_HEAP_N_SLOTS];
    yon_xheap_index_entry_t content_index[YON_HEAP_N_INDEX];
    uint8_t                 arena[YON_HEAP_ARENA_BYTES];
} yon_xheap_t;

/* Backing strategy. */
typedef enum {
    YON_HEAP_BACKING_PRIVATE = 0,
    YON_HEAP_BACKING_SHM     = 1,
} yon_heap_backing_t;

/* ============================================================== */
/* Lifecycle                                                       */
/* ============================================================== */

yon_xheap_t *yon_xheap_create(void);

yon_xheap_t *yon_xheap_create_with_backing(yon_heap_backing_t kind,
                                             const char *shm_name,
                                             int shm_create);

void yon_xheap_destroy(yon_xheap_t *h);
int  yon_xheap_unlink_shm(const char *shm_name);

/* ============================================================== */
/* Strip allocation (in-place mutable structures, e.g. Vec)         */
/* ============================================================== */

/* Hand out a contiguous, bump-allocated byte range in the arena - no dedup,
 * no content_index entry, no malloc. For in-place mutable structures that own
 * their storage (Vec). Returns the arena offset, or 0 on exhaustion (offset 0
 * is the "no payload" sentinel, so a live strip never starts at 0). */
uint32_t yon_xheap_strip_alloc(yon_xheap_t *h, uint32_t n_bytes);

/* Writable pointer into the arena at a strip offset (NULL if off == 0). */
void *yon_xheap_strip_at(yon_xheap_t *h, uint32_t off);

/* Return the unused tail of a strip to the OS. Releases, via
 * madvise(MADV_DONTNEED), only the whole page-aligned pages that fall entirely
 * within [off+live_bytes, off+total_bytes): physical RAM is reclaimed, the
 * virtual bump pointer is never rewound (O(1) bump, no fragmentation). A no-op
 * when the dead tail is smaller than one page. */
void yon_xheap_strip_trim(yon_xheap_t *h, uint32_t off,
                          uint32_t live_bytes, uint32_t total_bytes);

/* Whole-heap twin of yon_xheap_strip_trim: hand the physical RAM of the live
 * arena [0, arena_used) back to the OS (madvise MADV_DONTNEED), page-aligned
 * inward. Used to reclaim a dropped Space whose heap is provably dead. The
 * virtual mapping stays valid (no dangling); arena_used is not rewound. A NULL
 * heap is a no-op. Counts each drop performed (see yon_xheap_drops). */
void yon_xheap_drop(yon_xheap_t *h);

/* Number of yon_xheap_drop calls performed on a real heap. Observable proof, for
 * the drop-emission gate, that a compiled `drop X` reached the reclaim. */
uint64_t yon_xheap_drops(void);

/* ============================================================== */
/* Basic operations                                                */
/* ============================================================== */

/* Insert a payload (n_bytes) with a tag. Content-addressed:
 *   - if the payload was already present with the same bytes -> return the
 *     existing slot_index
 *   - if new -> allocate a sequential slot + register it in the content_index
 *
 * Returns:
 *   slot_index in [0, N_SLOTS) on success
 *   YON_HEAP_SLOT_INVALID if: h null, tag=FREE, arena full, slots full
 */
uint32_t yon_xheap_put(yon_xheap_t *h,
                        const void *payload, uint32_t n_bytes,
                        yon_xtag_t tag);

/* Put with an explicit schema_version. */
uint32_t yon_xheap_put_v(yon_xheap_t *h,
                          const void *payload, uint32_t n_bytes,
                          yon_xtag_t tag, uint32_t schema_version);

/* Content-based lookup (no insert). Returns the existing slot_index, or INVALID. */
uint32_t yon_xheap_lookup_content(const yon_xheap_t *h,
                                    const void *payload, uint32_t n_bytes);

/* Put + a "was_new" flag. Returns slot_index; *out_was_new = true if it
 * allocated a new slot, false if it reused an existing one (content dedup). */
uint32_t yon_xheap_put_or_get(yon_xheap_t *h,
                               const void *payload, uint32_t n_bytes,
                               yon_xtag_t tag, bool *out_was_new);

/* "anonymous" allocation — no dedup via the content_index. For large data
 * structures (HashSet, HashMap, XSet) that must stay distinct even when empty.
 * Returns slot_id; the payload is zeroed. */
uint32_t yon_xheap_alloc(yon_xheap_t *h, uint32_t n_bytes, yon_xtag_t tag);

/* Mutable payload: same byte range as yon_xheap_slot_payload but cast to a
 * mutable void *. The caller is responsible for not corrupting beyond
 * n_bytes. */
void *yon_xheap_slot_payload_mut(yon_xheap_t *h, uint32_t slot_index);

/* Direct get by slot_index. Returns a pointer to the slot, or NULL if
 * slot_index >= N_SLOTS or the slot is FREE. */
const yon_xheap_slot_t *yon_xheap_get(const yon_xheap_t *h, uint32_t slot_index);

/* Returns a pointer to the slot's payload bytes (inside arena[]). */
const void *yon_xheap_slot_payload(const yon_xheap_t *h,
                                     const yon_xheap_slot_t *slot);

bool yon_xheap_is_occupied(const yon_xheap_t *h, uint32_t slot_index);

/* Free the slot. The slot stays in the arena (no compaction) but its tag ->
 * FREE. The content_index entry for that slot is removed (backward-shift
 * probe). */
int yon_xheap_clear(yon_xheap_t *h, uint32_t slot_index);

/* Full reset: all slots -> FREE, content_index -> INVALID, arena -> 0. Fast
 * O(N_INDEX). For scratchpad use (transient working sets) where each
 * invocation starts from a clean heap. */
int yon_xheap_reset(yon_xheap_t *h);

size_t yon_xheap_occupancy(const yon_xheap_t *h);

/* ============================================================== */
/* Cross-process locking                                          */
/* ============================================================== */

int yon_xheap_lock(yon_xheap_t *h);
int yon_xheap_unlock(yon_xheap_t *h);

/* ============================================================== */
/* HeapRef + chain API                                             */
/* ============================================================== */

/* Bit-packed HeapRef: (heap_id << 24) | slot_idx.
 *   8 bits  heap_id   in [0, 256)     -> registry g_heap_registry[]
 *  24 bits  slot_idx  in [0, 196560)  -> 18 effective bits, 6 of slack
 *
 * Global limit: 256 heaps x 196560 slots = ~50M slots total.
 *
 * HeapRef = 0 is not valid (it collides with slot_idx=0, heap_id=0).
 * Caller-side convention: shift the HeapRef by +1 to avoid collision with
 * "empty".
 */
#define YON_HEAPREF_MAKE(heap_id, slot_idx)   \
    ((((uint32_t)(heap_id)) << 24) | ((uint32_t)(slot_idx) & 0xFFFFFFu))
#define YON_HEAPREF_HEAP_ID(href)   (((uint32_t)(href) >> 24) & 0xFFu)
#define YON_HEAPREF_SLOT(href)      ((uint32_t)(href) & 0xFFFFFFu)
#define YON_HEAPREF_INVALID         0xFFFFFFFFu
#define YON_HEAPREF_MAX_HEAPS       256u

/* Global registry of heaps. Each heap created with yon_xheap_create is
 * auto-registered. O(1) lookup by heap_id. */
yon_xheap_t *yon_xheap_registry_get(uint32_t heap_id);
uint32_t     yon_xheap_registry_count(void);

/* Chain-based put: inserts the payload into the "primary chain" starting from
 * h_first. If h_first is full, follows h_first->next; if that is also full,
 * allocates a new heap, links it, registers it, and inserts there.
 *
 * Returns a global HeapRef = (final_heap_id << 24 | local_slot_idx), or
 * YON_HEAPREF_INVALID on error.
 *
 * Accepted trade-off: heaps can be unbalanced (the first at 100%, the second
 * at 3% right after overflow). Conway stays intact on heap_id=0.
 */
uint32_t yon_xheap_put_chain(yon_xheap_t *h_first,
                              const void *payload, uint32_t n_bytes,
                              yon_xtag_t tag);

/* Chain-based get: decodes the HeapRef, looks up the heap via the registry,
 * returns the slot. Returns NULL if the HeapRef is invalid. */
const yon_xheap_slot_t *yon_xheap_get_chain(uint32_t heapref);

/* Payload from a HeapRef: a convenience wrapper. */
const void *yon_xheap_payload_chain(uint32_t heapref);

/* A slot's payload, resolving the owning heap from the registry. */
const void *yon_xheap_slot_payload_any(const yon_xheap_slot_t *slot);

#endif /* YON_XLEECH2_HEAP_H */
