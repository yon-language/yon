/* xleech2_heap.c — hybrid HexHeap design (arena + content_index).
 *
 * Tile-based arena (no physical slot collisions) + content_index hash table
 * (natural O(1) dedup). Backing pluggable via mmap (PRIVATE/SHM).
 */

#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

#include "xleech2_heap.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
/* macOS: MAP_ANONYMOUS may be spelled MAP_ANON (BSD). */
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif
#include <sys/file.h>
#include <sys/stat.h>
#include <pthread.h>

/* Global mutex to serialize calls into libmmgroup (not thread-safe).
 * Previously defined in xleech2_move.c, moved here as the canonical
 * definition. Referenced via extern from xleech2_mphf.c and xleech2_coord.c. */
pthread_mutex_t mmgroup_mutex = PTHREAD_MUTEX_INITIALIZER;

/* ============================================================== */
/* Content hash (FNV-1a 64-bit)                                    */
/* ============================================================== */

#define FNV1A_OFFSET_BASIS 0xcbf29ce484222325ULL
#define FNV1A_PRIME        0x100000001b3ULL

static uint64_t content_hash(const void *data, size_t n) {
    const uint8_t *p = (const uint8_t *)data;
    uint64_t h = FNV1A_OFFSET_BASIS;
    for (size_t i = 0; i < n; i++) {
        h ^= (uint64_t)p[i];
        h *= FNV1A_PRIME;
    }
    /* Avoid hash == 0 (the sentinel for "empty entry"). */
    if (h == 0) h = 1;
    return h;
}

static uint32_t index_bucket(uint64_t hash, uint32_t probe) {
    /* SplitMix64 finalizer to spread the entropy. */
    uint64_t x = hash;
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return (uint32_t)((x + probe) % (uint64_t)YON_HEAP_N_INDEX);
}

/* ============================================================== */
/* Backing metadata side-table                                     */
/* ============================================================== */

typedef struct {
    yon_xheap_t        *heap;
    yon_heap_backing_t  kind;
    int                 fd;
    char                name[256];   /* inline (was strdup) */
} heap_meta_t;

#define MAX_HEAP_META 256
static heap_meta_t g_heap_meta[MAX_HEAP_META];
static int g_n_heap_meta = 0;

static heap_meta_t *meta_for(const yon_xheap_t *h) {
    for (int i = 0; i < g_n_heap_meta; i++) {
        if (g_heap_meta[i].heap == h) return &g_heap_meta[i];
    }
    return NULL;
}

static heap_meta_t *meta_alloc(yon_xheap_t *h) {
    if (g_n_heap_meta >= MAX_HEAP_META) return NULL;
    heap_meta_t *m = &g_heap_meta[g_n_heap_meta++];
    m->heap = h;
    m->kind = YON_HEAP_BACKING_PRIVATE;
    m->fd = -1;
    m->name[0] = '\0';
    return m;
}

static void meta_free(yon_xheap_t *h) {
    for (int i = 0; i < g_n_heap_meta; i++) {
        if (g_heap_meta[i].heap == h) {
            for (int j = i; j < g_n_heap_meta - 1; j++) {
                g_heap_meta[j] = g_heap_meta[j+1];
            }
            g_n_heap_meta--;
            return;
        }
    }
}

/* ============================================================== */
/* Lifecycle                                                       */
/* ============================================================== */

/* Forward decl: registry_register is defined at the bottom, used by create. */
static uint32_t registry_register(yon_xheap_t *h);

static void init_header(yon_xheap_t *h) {
    /* memset zeroing all 71MB is costly; mmap MAP_ANONYMOUS already zeroes.
     * For SHM with shm_create we do it manually. */
    h->magic = YON_HEAP_MAGIC;
    h->version = YON_HEAP_VERSION;
    /* n_occupied starts at 1: slot 0 is reserved and never returned as a data
     * slot. Reason: (uint32_t)slot 0 == 0.0 as a double, which collides with
     * every "empty/false/>=0.5" guard in code that iterates list_id or elements
     * (the cons cell in slot 0 was lost: tail==0 read as end-of-list, and
     * 0.0>=0.5 false stopped the loops). By reserving slot 0, the first real
     * object gets slot 1, and no valid handle is ever 0.0. Consistent with
     * arena_used starting at 1 for the same reason about offset 0. */
    h->n_occupied = 1;
    h->slots[0].tag = (uint32_t)YON_TAG_USER1;  /* reserved, not FREE, never reused */
    h->slots[0].payload_offset = 0;
    h->slots[0].payload_size = 0;
    h->slots[0].schema_version = 0;
    /* arena_used starts at 1: offset 0 is the "no payload" sentinel. */
    h->arena_used = 1;
    h->heap_id = 0xFFFFFFFFu;  /* assigned by the registry on create */
    /* slots[] and content_index[] are already zeroed by mmap. slot_index 0 is
     * valid as a slot, but the content_index uses slot_index == 0xFFFFFFFF as
     * the "empty" sentinel: reading an entry with slot_index == 0 would confuse
     * an empty one with it. Initialize all content_index entries with
     * slot_index = INVALID. */
    for (uint32_t i = 0; i < YON_HEAP_N_INDEX; i++) {
        h->content_index[i].slot_index = YON_HEAP_SLOT_INVALID;
    }
}

yon_xheap_t *yon_xheap_create(void) {
    return yon_xheap_create_with_backing(YON_HEAP_BACKING_PRIVATE, NULL, 0);
}

yon_xheap_t *yon_xheap_create_with_backing(yon_heap_backing_t kind,
                                             const char *shm_name,
                                             int shm_create) {
    size_t sz = sizeof(yon_xheap_t);
    void *mem = MAP_FAILED;
    int fd = -1;

    if (kind == YON_HEAP_BACKING_PRIVATE) {
        mem = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (mem == MAP_FAILED) {
            perror("[YON-RT] mmap private");
            return NULL;
        }
    } else if (kind == YON_HEAP_BACKING_SHM) {
        if (!shm_name) {
            fprintf(stderr, "[YON-RT] shm backing requires shm_name\n");
            return NULL;
        }
        /* "create or attach" mode: opens with O_CREAT (idempotent). We
         * distinguish "new" from "existing" via the size before ftruncate. If
         * shm_create=0, fails if it does not exist. */
        int flags = O_RDWR;
        if (shm_create) flags |= O_CREAT;
        fd = shm_open(shm_name, flags, 0600);
        if (fd < 0) {
            perror("[YON-RT] shm_open");
            return NULL;
        }

        /* Detect if it is new: size == 0 -> just created, to be initialized. */
        struct stat st;
        int is_new = 0;
        if (fstat(fd, &st) == 0 && (size_t)st.st_size < sz) {
            is_new = 1;
            if (ftruncate(fd, (off_t)sz) < 0) {
                perror("[YON-RT] ftruncate");
                close(fd);
                if (shm_create) shm_unlink(shm_name);
                return NULL;
            }
        }
        mem = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mem == MAP_FAILED) {
            perror("[YON-RT] mmap shared");
            close(fd);
            return NULL;
        }

        yon_xheap_t *h_tmp = (yon_xheap_t *)mem;
        if (is_new) {
            init_header(h_tmp);
        } else {
            if (h_tmp->magic != YON_HEAP_MAGIC) {
                fprintf(stderr,
                        "[YON-RT] shm '%s' magic mismatch: 0x%x\n",
                        shm_name, h_tmp->magic);
                munmap(mem, sz);
                close(fd);
                return NULL;
            }
            if (h_tmp->version != YON_HEAP_VERSION) {
                fprintf(stderr,
                        "[YON-RT] shm '%s' version mismatch: %u vs %u\n",
                        shm_name, h_tmp->version, YON_HEAP_VERSION);
                munmap(mem, sz);
                close(fd);
                return NULL;
            }
        }

        /* Skip the old init/validation path below: already done here. */
        yon_xheap_t *h = h_tmp;
        heap_meta_t *m = meta_alloc(h);
        if (!m) {
            munmap(mem, sz);
            close(fd);
            return NULL;
        }
        m->kind = kind;
        m->fd = fd;
        snprintf(m->name, sizeof(m->name), "%s", shm_name);
        registry_register(h); /* chain support */
        return h;
    } else {
        return NULL;
    }

    /* Path PRIVATE: continua qui */
    yon_xheap_t *h = (yon_xheap_t *)mem;
    init_header(h);

    heap_meta_t *m = meta_alloc(h);
    if (!m) {
        munmap(mem, sz);
        return NULL;
    }
    m->kind = kind;
    m->fd = -1;
    m->name[0] = '\0';
    registry_register(h); /* chain support */
    return h;
}

void yon_xheap_destroy(yon_xheap_t *h) {
    if (!h) return;
    heap_meta_t *m = meta_for(h);
    int fd = m ? m->fd : -1;
    meta_free(h);
    munmap(h, sizeof(yon_xheap_t));
    if (fd >= 0) close(fd);
}

int yon_xheap_unlink_shm(const char *shm_name) {
    if (!shm_name) return -1;
    return shm_unlink(shm_name);
}

/* ============================================================== */
/* Arena bump-allocator                                            */
/* ============================================================== */

static uint32_t arena_alloc(yon_xheap_t *h, uint32_t n_bytes) {
    /* Widen to uint64_t before the align/compare so the bound check is sound
     * regardless of caller (a 32-bit  used + aligned  could wrap and pass the
     * test). Same class fixed in yon_rt.c; pure widening, no behaviour change
     * on any in-range input. */
    uint64_t aligned = ((uint64_t)n_bytes + 7u) & ~(uint64_t)7u;
    if ((uint64_t)h->arena_used + aligned > (uint64_t)YON_HEAP_ARENA_BYTES) return 0;
    uint32_t off = h->arena_used;
    h->arena_used += (uint32_t)aligned;
    return off;
}

/* ---- Strip allocation (in-place mutable structures, e.g. Vec) -------- */

uint32_t yon_xheap_strip_alloc(yon_xheap_t *h, uint32_t n_bytes) {
    if (!h) return 0;
    return arena_alloc(h, n_bytes);
}

void *yon_xheap_strip_at(yon_xheap_t *h, uint32_t off) {
    if (!h || off == 0) return NULL;
    return h->arena + off;
}

void yon_xheap_strip_trim(yon_xheap_t *h, uint32_t off,
                          uint32_t live_bytes, uint32_t total_bytes) {
    if (!h || off == 0 || total_bytes <= live_bytes) return;
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) return;
    uintptr_t page  = (uintptr_t)pg;
    uintptr_t base  = (uintptr_t)(h->arena + off);
    /* Page-align the dead tail inward: round the start up, the end down, so we
     * only ever hand back pages that lie ENTIRELY inside the unused tail. */
    uintptr_t a_start = (base + live_bytes  + page - 1u) & ~(page - 1u);
    uintptr_t a_end   = (base + total_bytes)            & ~(page - 1u);
    if (a_end > a_start) {
        /* Best-effort: reclaims physical RAM. The live prefix is untouched. */
        madvise((void *)a_start, (size_t)(a_end - a_start), MADV_DONTNEED);
    }
}

/* Number of drops performed (observability for the drop-emission gate). */
static uint64_t g_xheap_drops = 0;

uint64_t yon_xheap_drops(void) { return g_xheap_drops; }

void yon_xheap_drop(yon_xheap_t *h) {
    /* Whole-heap twin of yon_xheap_strip_trim, scaled from one strip's dead tail
     * to the ENTIRE live arena [0, arena_used): used when a Space is dropped and
     * its whole heap is provably dead (Space_liveness.check_drops). Hands the
     * physical RAM back to the OS via madvise(MADV_DONTNEED); the virtual mapping
     * and the struct header are left intact, so the heap stays addressable and no
     * pointer dangles (a stray read returns zeros, which the compile-time
     * downstream check already excludes). arena_used is NOT rewound: this is a
     * RAM reclaim, not a logical reset. Same inward page alignment as strip_trim:
     * start rounded up, end rounded down, so only whole pages that lie ENTIRELY
     * inside the arena are handed back and the partial final page (live up to
     * arena_used) is never touched. Counts every drop performed on a real heap;
     * a NULL heap (no private per-Space heap, L1_SHARED) is a no-op. */
    if (!h) return;
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) return;
    uintptr_t page    = (uintptr_t)pg;
    uintptr_t base    = (uintptr_t)h->arena;
    uintptr_t a_start = (base + page - 1u)        & ~(page - 1u);
    uintptr_t a_end   = (base + h->arena_used)    & ~(page - 1u);
    if (a_end > a_start)
        madvise((void *)a_start, (size_t)(a_end - a_start), MADV_DONTNEED);
    g_xheap_drops++;
}

/* ============================================================== */
/* Content index operations                                        */
/* ============================================================== */

/* Look up hash + payload in the content_index. Linear probing. Returns
 * slot_index if found (i.e. a content match), INVALID otherwise. */
static uint32_t index_lookup(const yon_xheap_t *h,
                              uint64_t hash,
                              const void *payload, uint32_t n_bytes) {
    for (uint32_t probe = 0; probe < YON_HEAP_N_INDEX; probe++) {
        uint32_t idx = index_bucket(hash, probe);
        const yon_xheap_index_entry_t *e = &h->content_index[idx];
        if (e->slot_index == YON_HEAP_SLOT_INVALID) {
            /* Empty entry: the hash is not present. */
            return YON_HEAP_SLOT_INVALID;
        }
        if (e->hash == hash) {
            /* Hash match -> verify the actual content */
            const yon_xheap_slot_t *s = &h->slots[e->slot_index];
            if (s->payload_size == n_bytes && s->tag != YON_TAG_FREE) {
                const void *p = (const void *)(h->arena + s->payload_offset);
                if (memcmp(p, payload, n_bytes) == 0) {
                    return e->slot_index;
                }
            }
            /* Hash match but different content: keep probing (hash collision). */
        }
    }
    return YON_HEAP_SLOT_INVALID;
}

/* Insert (hash -> slot_index) into the content_index. Returns 0 on success,
 * -1 if the index is full. */
static int index_insert(yon_xheap_t *h, uint64_t hash, uint32_t slot_index) {
    for (uint32_t probe = 0; probe < YON_HEAP_N_INDEX; probe++) {
        uint32_t idx = index_bucket(hash, probe);
        yon_xheap_index_entry_t *e = &h->content_index[idx];
        if (e->slot_index == YON_HEAP_SLOT_INVALID) {
            e->hash = hash;
            e->slot_index = slot_index;
            return 0;
        }
    }
    return -1;
}

/* Remove from the content_index the entry with slot_index = target. Used by
 * yon_xheap_clear. Implementation: backward shift after the found bucket so as
 * not to break probing chains. */
static int index_remove(yon_xheap_t *h, uint32_t target_slot) {
    /* Find the bucket containing target_slot. */
    int32_t found = -1;
    /* Linear scan: alternatively we could store the hash in the slot and do a
     * targeted lookup. For now a full scan (O(N_INDEX)). Clear is not a hot
     * path. */
    for (uint32_t i = 0; i < YON_HEAP_N_INDEX; i++) {
        if (h->content_index[i].slot_index == target_slot) {
            found = (int32_t)i;
            break;
        }
    }
    if (found < 0) return -1;

    /* Backward shift: from the bucket after found, reposition all contiguous
     * entries to their "canonical" bucket where possible. */
    uint32_t hole = (uint32_t)found;
    h->content_index[hole].slot_index = YON_HEAP_SLOT_INVALID;

    for (uint32_t k = 1; k < YON_HEAP_N_INDEX; k++) {
        uint32_t next = (hole + k) % YON_HEAP_N_INDEX;
        if (h->content_index[next].slot_index == YON_HEAP_SLOT_INVALID) break;
        uint32_t canonical = index_bucket(h->content_index[next].hash, 0);
        /* If 'next' is between the canonical bucket and 'hole', move it to hole. */
        uint32_t dist_next  = (next - canonical) % YON_HEAP_N_INDEX;
        uint32_t dist_hole  = (hole - canonical) % YON_HEAP_N_INDEX;
        if (dist_hole < dist_next) {
            h->content_index[hole] = h->content_index[next];
            h->content_index[next].slot_index = YON_HEAP_SLOT_INVALID;
            hole = next;
        }
    }
    return 0;
}

/* ============================================================== */
/* Operations: put / get                                           */
/* ============================================================== */

uint32_t yon_xheap_put_v(yon_xheap_t *h,
                          const void *payload, uint32_t n_bytes,
                          yon_xtag_t tag, uint32_t schema_version) {
    if (!h) return YON_HEAP_SLOT_INVALID;
    if (tag == YON_TAG_FREE) return YON_HEAP_SLOT_INVALID;
    if (n_bytes > 0 && !payload) return YON_HEAP_SLOT_INVALID;

    /* Dedup check */
    uint64_t hash = (n_bytes > 0) ? content_hash(payload, n_bytes) : 1;
    if (n_bytes > 0) {
        uint32_t existing = index_lookup(h, hash, payload, n_bytes);
        if (existing != YON_HEAP_SLOT_INVALID) {
            /* Same content: return the existing slot (idempotence). */
            return existing;
        }
    }

    /* New: allocate a sequential slot */
    if (h->n_occupied >= YON_HEAP_N_SLOTS) return YON_HEAP_SLOT_INVALID;
    uint32_t slot_idx = h->n_occupied;
    yon_xheap_slot_t *s = &h->slots[slot_idx];

    uint32_t off = 0;
    if (n_bytes > 0) {
        off = arena_alloc(h, n_bytes);
        if (off == 0) return YON_HEAP_SLOT_INVALID;
        memcpy(h->arena + off, payload, n_bytes);
    }

    s->tag = (uint32_t)tag;
    s->payload_offset = off;
    s->payload_size = n_bytes;
    s->schema_version = schema_version;

    /* Register in the content_index */
    if (n_bytes > 0) {
        if (index_insert(h, hash, slot_idx) != 0) {
            s->tag = YON_TAG_FREE;
            s->payload_offset = 0;
            s->payload_size = 0;
            return YON_HEAP_SLOT_INVALID;
        }
    }
    h->n_occupied++;
    return slot_idx;
}

uint32_t yon_xheap_put(yon_xheap_t *h,
                        const void *payload, uint32_t n_bytes,
                        yon_xtag_t tag) {
    /* Default: schema_version = 0 (unspecified). */
    return yon_xheap_put_v(h, payload, n_bytes, tag, 0);
}

/* Content-based lookup (no insert). Exposed for consumers that want to know
 * whether a payload is already in the heap without forcing its insertion. */
uint32_t yon_xheap_lookup_content(const yon_xheap_t *h,
                                    const void *payload, uint32_t n_bytes) {
    if (!h || n_bytes == 0 || !payload) return YON_HEAP_SLOT_INVALID;
    uint64_t hash = content_hash(payload, n_bytes);
    return index_lookup(h, hash, payload, n_bytes);
}

/* Put + was_new flag. Returns slot_index; *out_was_new=true if new, false if
 * dedup. Essential for the dual structure (frontier += if new). */
uint32_t yon_xheap_put_or_get(yon_xheap_t *h,
                               const void *payload, uint32_t n_bytes,
                               yon_xtag_t tag, bool *out_was_new) {
    if (out_was_new) *out_was_new = false;
    if (!h || tag == YON_TAG_FREE || (n_bytes > 0 && !payload))
        return YON_HEAP_SLOT_INVALID;
    if (n_bytes > 0) {
        uint64_t hash = content_hash(payload, n_bytes);
        uint32_t existing = index_lookup(h, hash, payload, n_bytes);
        if (existing != YON_HEAP_SLOT_INVALID) {
            /* dedup hit: was_new resta false */
            return existing;
        }
    }
    uint32_t slot = yon_xheap_put_v(h, payload, n_bytes, tag, 0);
    if (slot != YON_HEAP_SLOT_INVALID && out_was_new) *out_was_new = true;
    return slot;
}

const yon_xheap_slot_t *yon_xheap_get(const yon_xheap_t *h, uint32_t slot_index) {
    if (!h || slot_index >= YON_HEAP_N_SLOTS) return NULL;
    const yon_xheap_slot_t *s = &h->slots[slot_index];
    if (s->tag == YON_TAG_FREE) return NULL;
    return s;
}

const void *yon_xheap_slot_payload(const yon_xheap_t *h,
                                     const yon_xheap_slot_t *slot) {
    if (!h || !slot || slot->payload_offset == 0) return NULL;
    return h->arena + slot->payload_offset;
}

bool yon_xheap_is_occupied(const yon_xheap_t *h, uint32_t slot_index) {
    return yon_xheap_get(h, slot_index) != NULL;
}

int yon_xheap_clear(yon_xheap_t *h, uint32_t slot_index) {
    if (!h || slot_index >= YON_HEAP_N_SLOTS) return -1;
    yon_xheap_slot_t *s = &h->slots[slot_index];
    if (s->tag == YON_TAG_FREE) return -1;

    /* Remove from content_index */
    index_remove(h, slot_index);

    s->tag = YON_TAG_FREE;
    s->payload_offset = 0;
    s->payload_size = 0;
    /* Note: the arena space stays orphaned. Compaction is future work. */
    /* Note: n_occupied does NOT decrease here, so slot_index stays
     * monotonically increasing. A new put always reuses n_occupied as the next
     * slot, but if intermediate slots were freed, n_occupied does not reflect
     * the true "next free". So we do not decrement: the slot stays as an
     * implicit tombstone. */
    /* (no decrement on h->n_occupied) */
    return 0;
}

size_t yon_xheap_occupancy(const yon_xheap_t *h) {    if (!h) return 0;
    /* Count the slots with tag != FREE to be precise (clear does not
     * decrement n_occupied). */
    size_t count = 0;
    for (uint32_t i = 0; i < h->n_occupied; i++) {
        if (h->slots[i].tag != YON_TAG_FREE) count++;
    }
    return count;
}

int yon_xheap_reset(yon_xheap_t *h) {
    if (!h) return -1;
    /* Slots: tag -> FREE, payload metadata zeroed (an explicit loop, not a
     * memset of all of slots[], to preserve any future fields). */
    for (uint32_t i = 0; i < h->n_occupied; i++) {
        h->slots[i].tag = YON_TAG_FREE;
        h->slots[i].payload_offset = 0;
        h->slots[i].payload_size = 0;
        h->slots[i].schema_version = 0;
    }
    /* content_index: all entries -> INVALID. */
    for (uint32_t i = 0; i < YON_HEAP_N_INDEX; i++) {
        h->content_index[i].hash = 0;
        h->content_index[i].slot_index = YON_HEAP_SLOT_INVALID;
        h->content_index[i].reserved = 0;
    }
    h->n_occupied = 0;
    h->arena_used = 1;  /* offset 0 = the "no payload" sentinel, as in init_header */
    return 0;
}

/* "anonymous" allocation — no dedup via the content_index. For data structures
 * (HashSet, HashMap, XSet) that must stay distinct even when empty. The payload
 * is zeroed. The caller writes via yon_xheap_slot_payload_mut. */
uint32_t yon_xheap_alloc(yon_xheap_t *h, uint32_t n_bytes, yon_xtag_t tag) {
    if (!h || tag == YON_TAG_FREE) return YON_HEAP_SLOT_INVALID;
    if (h->n_occupied >= YON_HEAP_N_SLOTS) return YON_HEAP_SLOT_INVALID;
    uint32_t slot_idx = h->n_occupied;
    yon_xheap_slot_t *s = &h->slots[slot_idx];
    uint32_t off = 0;
    if (n_bytes > 0) {
        off = arena_alloc(h, n_bytes);
        if (off == 0) return YON_HEAP_SLOT_INVALID;
        memset(h->arena + off, 0, n_bytes);
    }
    s->tag = (uint32_t)tag;
    s->payload_offset = off;
    s->payload_size = n_bytes;
    s->schema_version = 0;
    /* No registration in the content_index: this is an anonymous allocation. */
    h->n_occupied++;
    return slot_idx;
}

void *yon_xheap_slot_payload_mut(yon_xheap_t *h, uint32_t slot_index) {
    if (!h || slot_index >= YON_HEAP_N_SLOTS) return NULL;
    yon_xheap_slot_t *s = &h->slots[slot_index];
    if (s->tag == YON_TAG_FREE || s->payload_offset == 0) return NULL;
    return h->arena + s->payload_offset;
}

/* ============================================================== */
/* Cross-process locking                                           */
/* ============================================================== */

int yon_xheap_lock(yon_xheap_t *h) {
    if (!h) return -1;
    heap_meta_t *m = meta_for(h);
    if (!m || m->kind != YON_HEAP_BACKING_SHM) return 0;
    return flock(m->fd, LOCK_EX);
}

int yon_xheap_unlock(yon_xheap_t *h) {
    if (!h) return -1;
    heap_meta_t *m = meta_for(h);
    if (!m || m->kind != YON_HEAP_BACKING_SHM) return 0;
    return flock(m->fd, LOCK_UN);
}

/* ============================================================== */
/* HeapRef Registry + Chain                                        */
/* ============================================================== */
/* Global registry of heaps. Registration happens on first access in the
 * initialization sequence, not in a hot path. Cross-thread concurrency is
 * protected by g_registry_mutex.
 *
 * Linked list of heaps: each heap has an optional next for the chain.
 * Ds-heap chain: g_ds_heap -> g_ds_heap1 -> g_ds_heap2 -> ...
 * Conway operates on heap_id=0 only (preserves MPHF indexing).
 */

#include <pthread.h>

static yon_xheap_t *g_heap_registry[YON_HEAPREF_MAX_HEAPS] = {0};
static yon_xheap_t *g_heap_next[YON_HEAPREF_MAX_HEAPS] = {0};
static uint32_t     g_n_heaps_registered = 0;
static pthread_mutex_t g_registry_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Register a heap in the registry. Returns the assigned heap_id, or
 * 0xFFFFFFFF if the pool is exhausted. Called internally by create. */
static uint32_t registry_register(yon_xheap_t *h) {
    if (!h) return 0xFFFFFFFFu;
    pthread_mutex_lock(&g_registry_mutex);
    if (g_n_heaps_registered >= YON_HEAPREF_MAX_HEAPS) {
        pthread_mutex_unlock(&g_registry_mutex);
        return 0xFFFFFFFFu;
    }
    uint32_t id = g_n_heaps_registered++;
    g_heap_registry[id] = h;
    g_heap_next[id] = NULL;
    h->heap_id = id;
    pthread_mutex_unlock(&g_registry_mutex);
    return id;
}

yon_xheap_t *yon_xheap_registry_get(uint32_t heap_id) {
    if (heap_id >= YON_HEAPREF_MAX_HEAPS) return NULL;
    return g_heap_registry[heap_id];
}

uint32_t yon_xheap_registry_count(void) {
    return g_n_heaps_registered;
}

/* Allocate + link a new heap as the successor of prev. */
static yon_xheap_t *chain_extend(yon_xheap_t *prev) {
    if (!prev) return NULL;
    yon_xheap_t *new_heap = yon_xheap_create();  /* auto-register inside */
    if (!new_heap) return NULL;
    pthread_mutex_lock(&g_registry_mutex);
    /* 2026-06-04 FIX: link from the REAL predecessor, not always heap 0.
     * The old g_heap_next[0] = new_heap broke the chain at the third heap
     * (heap1 full -> next[0] overwritten, heap1 lost). */
    g_heap_next[prev->heap_id] = new_heap;
    pthread_mutex_unlock(&g_registry_mutex);
    return new_heap;
}

/* Per-chain hint: the last heap that accepted an insert. Avoids retrying
 * the insert on full heaps at every put. */
static yon_xheap_t *g_chain_hint[YON_HEAPREF_MAX_HEAPS] = {0};

/* ============================================================== */
/* GLOBAL content index (per chain root)                          */
/* ============================================================== */
/* 2026-06-04: put_chain's dedup phase no longer walks the chain heap by
 * heap: a single open-addressing table maps (root, hash64(content)) ->
 * HeapRef. O(1) regardless of how many heaps the chain has. The index is
 * complete by construction: every allocation on a chain root goes through
 * put_chain, which updates it. Payload verification (size + memcmp via
 * the global ref) removes hash false positives. Doubles at 70% load. */
typedef struct {
    uint64_t hash;
    uint32_t ref;     /* YON_HEAPREF_INVALID = empty entry */
    uint32_t root;
} yon_cidx_entry_t;

static yon_cidx_entry_t *g_cidx = NULL;
static uint32_t g_cidx_cap = 0;
static uint32_t g_cidx_n = 0;

static void cidx_ensure(void) {
    if (g_cidx) return;
    g_cidx_cap = 1u << 17;
    size_t bytes = (size_t)g_cidx_cap * sizeof(yon_cidx_entry_t);
    g_cidx = (yon_cidx_entry_t *)mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g_cidx == MAP_FAILED) { g_cidx = NULL; g_cidx_cap = 0; return; }
    for (uint32_t i = 0; i < g_cidx_cap; i++) g_cidx[i].ref = YON_HEAPREF_INVALID;
}

static void cidx_grow(void) {
    uint32_t new_cap = g_cidx_cap * 2;
    size_t new_bytes = (size_t)new_cap * sizeof(yon_cidx_entry_t);
    yon_cidx_entry_t *nt = (yon_cidx_entry_t *)mmap(NULL, new_bytes, PROT_READ | PROT_WRITE,
                                                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (nt == MAP_FAILED) return;   /* without growth the index degrades, never lies */
    for (uint32_t i = 0; i < new_cap; i++) nt[i].ref = YON_HEAPREF_INVALID;
    for (uint32_t i = 0; i < g_cidx_cap; i++) {
        if (g_cidx[i].ref == YON_HEAPREF_INVALID) continue;
        uint64_t h = g_cidx[i].hash;
        for (uint32_t j = 0; j < new_cap; j++) {
            uint32_t idx = (uint32_t)((h + j) & (new_cap - 1));
            if (nt[idx].ref == YON_HEAPREF_INVALID) { nt[idx] = g_cidx[i]; break; }
        }
    }
    munmap(g_cidx, (size_t)g_cidx_cap * sizeof(yon_cidx_entry_t));
    g_cidx = nt;
    g_cidx_cap = new_cap;
}

static uint32_t cidx_lookup(uint32_t root, uint64_t hash,
                            const void *payload, uint32_t n_bytes) {
    if (!g_cidx) return YON_HEAPREF_INVALID;
    for (uint32_t i = 0; i < g_cidx_cap; i++) {
        uint32_t idx = (uint32_t)((hash + i) & (g_cidx_cap - 1));
        if (g_cidx[idx].ref == YON_HEAPREF_INVALID) return YON_HEAPREF_INVALID;
        if (g_cidx[idx].hash != hash || g_cidx[idx].root != root) continue;
        /* verify the payload against the owning heap */
        const yon_xheap_slot_t *s = yon_xheap_get_chain(g_cidx[idx].ref);
        if (!s || s->payload_size != n_bytes) continue;
        const void *p = yon_xheap_payload_chain(g_cidx[idx].ref);
        if (p && memcmp(p, payload, n_bytes) == 0) return g_cidx[idx].ref;
    }
    return YON_HEAPREF_INVALID;
}

static void cidx_insert(uint32_t root, uint64_t hash, uint32_t ref) {
    cidx_ensure();
    if (!g_cidx) return;
    if ((uint64_t)g_cidx_n * 10u >= (uint64_t)g_cidx_cap * 7u) cidx_grow();
    for (uint32_t i = 0; i < g_cidx_cap; i++) {
        uint32_t idx = (uint32_t)((hash + i) & (g_cidx_cap - 1));
        if (g_cidx[idx].ref == YON_HEAPREF_INVALID) {
            g_cidx[idx].hash = hash;
            g_cidx[idx].ref = ref;
            g_cidx[idx].root = root;
            g_cidx_n++;
            return;
        }
        if (g_cidx[idx].hash == hash && g_cidx[idx].root == root
            && g_cidx[idx].ref == ref) return;   /* idempotent */
    }
}

uint32_t yon_xheap_put_chain(yon_xheap_t *h_first,
                              const void *payload, uint32_t n_bytes,
                              yon_xtag_t tag) {
    if (!h_first) return YON_HEAPREF_INVALID;
    /* Phase 1 — GLOBAL DEDUP via the content index: one O(1) lookup
     * per (root, hash), regardless of how many heaps the chain has.
     * The same content always returns the same ref, wherever it lives:
     * handle equality stays correct. */
    uint64_t chash = 0;
    if (n_bytes > 0 && payload) {
        chash = content_hash(payload, n_bytes);
        uint32_t ex = cidx_lookup(h_first->heap_id, chash, payload, n_bytes);
        if (ex != YON_HEAPREF_INVALID) return ex;
    }
    /* Phase 2 — INSERT at the hinted heap (last one that accepted),
     * then forward along the chain, extending if needed. */
    yon_xheap_t *h = g_chain_hint[h_first->heap_id];
    if (!h) h = h_first;
    for (uint32_t hops = 0; hops < YON_HEAPREF_MAX_HEAPS; hops++) {
        uint32_t local_slot = yon_xheap_put(h, payload, n_bytes, tag);
        if (local_slot != YON_HEAP_SLOT_INVALID) {
            g_chain_hint[h_first->heap_id] = h;
            uint32_t ref = YON_HEAPREF_MAKE(h->heap_id, local_slot);
            if (n_bytes > 0 && payload)
                cidx_insert(h_first->heap_id, chash, ref);
            return ref;
        }
        yon_xheap_t *next = g_heap_next[h->heap_id];
        if (!next) {
            next = chain_extend(h);
            if (!next) {
                fprintf(stderr, "[YON-XHEAP] chain extend failed (pool exhausted at id=%u)\n",
                        h->heap_id);
                return YON_HEAPREF_INVALID;
            }
            fprintf(stderr, "[YON-XHEAP] chain extended: heap_id=%u -> new heap_id=%u\n",
                    h->heap_id, next->heap_id);
        }
        h = next;
    }
    return YON_HEAPREF_INVALID;
}

/* Resolve a slot's payload WITHOUT knowing its heap: identify the owning
 * heap from the pointer (range check over the registry, <=256 comparisons)
 * and use ITS arena. Required once refs are global. */
const void *yon_xheap_slot_payload_any(const yon_xheap_slot_t *slot) {
    if (!slot) return NULL;
    for (uint32_t i = 0; i < g_n_heaps_registered; i++) {
        yon_xheap_t *h = g_heap_registry[i];
        if (!h) continue;
        if (slot >= h->slots && slot < h->slots + YON_HEAP_N_SLOTS)
            return yon_xheap_slot_payload(h, slot);
    }
    return NULL;
}

const yon_xheap_slot_t *yon_xheap_get_chain(uint32_t heapref) {
    if (heapref == YON_HEAPREF_INVALID) return NULL;
    uint32_t heap_id = YON_HEAPREF_HEAP_ID(heapref);
    uint32_t slot_idx = YON_HEAPREF_SLOT(heapref);
    yon_xheap_t *h = yon_xheap_registry_get(heap_id);
    if (!h) return NULL;
    return yon_xheap_get(h, slot_idx);
}

const void *yon_xheap_payload_chain(uint32_t heapref) {
    if (heapref == YON_HEAPREF_INVALID) return NULL;
    uint32_t heap_id = YON_HEAPREF_HEAP_ID(heapref);
    yon_xheap_t *h = yon_xheap_registry_get(heap_id);
    if (!h) return NULL;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(heapref);
    if (!s) return NULL;
    return yon_xheap_slot_payload(h, s);
}
