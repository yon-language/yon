/* yon_shm.h — shared-memory backend for yon_xheap_t.
 *
 * A shadow implementation of a content-addressed heap that lives in POSIX
 * shared memory (shm_open + mmap), portable across processes.
 *
 * Differences from the in-process yon_xheap_t:
 *   - Everything in a single pre-allocated shm region
 *   - No absolute pointers: blobs are offsets in the shm arena
 *   - Cross-process locking via flock() on the shm fd
 *
 * Identical observable semantics: (heap_id, xcoord) -> payload bytes.
 * Content-addressing partitioned by heap_id guarantees determinism across
 * processes.
 */
#ifndef YON_SHM_H
#define YON_SHM_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Fixed size.
 *   - slots:  2^17 = 131072 slots (~5MB of key/tag/offset)
 *   - arena:  16MB of payload storage
 *
 * Will become parametric via the YON_SHM_SIZE env var in a future phase. */
#define YON_SHM_N_SLOTS    131072u
#define YON_SHM_ARENA_SIZE (16u * 1024u * 1024u)
#define YON_SHM_NAME_PREFIX "/yon_shm_heap_"

typedef struct {
    uint32_t key;        /* xcoord or YON_XCOORD_INVALID */
    uint32_t tag;        /* yon_xtag_t */
    uint32_t offset;     /* offset in the data arena, 0 = no payload */
    uint32_t size;       /* payload bytes in the arena */
} yon_shm_slot_t;

typedef struct {
    uint32_t magic;          /* YON_SHM_MAGIC for a sanity check */
    uint32_t version;
    uint32_t n_occupied;
    uint32_t arena_used;     /* next free position in the arena */
    yon_shm_slot_t slots[YON_SHM_N_SLOTS];
    uint8_t  arena[YON_SHM_ARENA_SIZE];
} yon_shm_heap_t;

#define YON_SHM_MAGIC 0x594F4E53u  /* "YONS" */

/* Open (or create) an shm region for a specific heap_id. Returns a pointer to
 * the mapped heap, or NULL on error. */
yon_shm_heap_t *yon_shm_open(const char *name, int create);

/* Close the mapping. Does NOT unlink the shm (it stays visible to other
 * processes). yon_shm_unlink removes the shm from the system. */
void yon_shm_close(yon_shm_heap_t *h);
int  yon_shm_unlink(const char *name);

/* xheap-like API. xcoord and payload come from the caller; tag = YON_TAG_USER1.
 * Returns 0 on success, -1 on error. */
int  yon_shm_put(yon_shm_heap_t *h, uint32_t xcoord,
                  const void *payload, uint32_t size);

/* Look up xcoord. If found, fills *out_offset (= the base of slot->offset in
 * the arena) and *out_size. Returns 0 on success, -1 if not found. */
int  yon_shm_get(const yon_shm_heap_t *h, uint32_t xcoord,
                  uint32_t *out_offset, uint32_t *out_size);

/* Copy the payload (size bytes) of xcoord into out_buf. Returns 0 on success,
 * -1 if not found / OOB. */
int  yon_shm_load(const yon_shm_heap_t *h, uint32_t xcoord,
                   uint32_t inner_offset, uint32_t size, void *out_buf);

/* Cross-process lock (flock on the shm fd). Blocking. Needed for 2PC:
 * prepare/commit crosses the barrier. */
int yon_shm_lock(yon_shm_heap_t *h);
int yon_shm_unlock(yon_shm_heap_t *h);

/* Diagnostic */
uint32_t yon_shm_occupancy(const yon_shm_heap_t *h);
uint32_t yon_shm_arena_used(const yon_shm_heap_t *h);

#ifdef __cplusplus
}
#endif

#endif /* YON_SHM_H */
