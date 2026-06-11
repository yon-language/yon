/* yon_rt.c — implementation of the cross-space single-process runtime API.
 *
 * Multiple logical heaps, all mapped to a single physical backing heap
 * (yon_xheap_t). The differentiation is in the content-addressing:
 *
 *   effective_xcoord = fnv1a(heap_id || payload)
 *
 * so that the same payload in different heaps produces different xcoords — an
 * implicit partitioning without separate physical heaps.
 *
 * Later this function changes: g_heaps[heap_id] becomes a separate yon_xheap_t
 * and the xcoord is computed only from the payload. The ABI is unchanged.
 */

#define _GNU_SOURCE  /* for strdup */
#include "yon_rt.h"
#include "xleech2_heap.h"
#include "xleech2_handler_stack.h"
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <sys/mman.h>
/* macOS: MAP_ANONYMOUS may be spelled MAP_ANON (BSD). */
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>

/* ============================================================== */
/* Physical singleton heap + Space table                          */
/* ============================================================== */

#define YON_MAX_SPACES 64

/* Backend mode:
 *   L1_SHARED   = a single shared yon_xheap_t (default)
 *   L2_SEPARATE = one yon_xheap_t per heap_id (physical separation)
 *   L2_SHM      = POSIX shared memory (multi-process)
 *
 * Selectable via the env var YON_BACKEND={memory,separate,shm}. */
typedef enum {
    YON_BACKEND_L1_SHARED   = 0,  /* default */
    YON_BACKEND_L2_SEPARATE = 1,
    YON_BACKEND_L2_SHM      = 2
} yon_backend_t;

static yon_backend_t g_backend = YON_BACKEND_L1_SHARED;
static yon_xheap_t *g_yon_heap = NULL;        /* used in L1_SHARED */
static int g_initialized = 0;

/* Space registry. Has an optional `fold_name` for the topos semilattice (a
 * characteristic of the topos itself, not of the dispatch). The cross-space
 * relations are in the g_geom_morphisms[] registry. */
static struct {
    char         *name;
    uint32_t      occupancy;
    char         *fold_name;       /* NULL if no fold declared */
    yon_xheap_t  *heap;
    /* Tracking of the current accumulator section. When the space has a fold
     * declared, each `new` calls fold with this as prev. Initially
     * YON_SECTION_INVALID = bottom. */
    yon_section_t accumulator;
} g_spaces[YON_MAX_SPACES];

static uint32_t g_n_spaces = 0;

/* Helper: return the physical heap associated with heap_id, per backend.
 * Exposed as yon_rt_heap_for in the header. */
yon_xheap_t *yon_rt_heap_for(uint32_t heap_id) {
    if (g_backend == YON_BACKEND_L1_SHARED) return g_yon_heap;
    if (heap_id >= g_n_spaces) return g_yon_heap;  /* safe fallback */
    if (g_spaces[heap_id].heap) return g_spaces[heap_id].heap;
    return g_yon_heap;
}

/* Backward-compat: il vecchio `heap_for` interno chiama il pubblico. */
static yon_xheap_t *heap_for(uint32_t heap_id) {
    return yon_rt_heap_for(heap_id);
}

void yon_rt_init(void) {
    if (g_initialized) return;
    /* Detect backend via env var. */
    const char *be = getenv("YON_BACKEND");
    if (be) {
        if (strcmp(be, "separate") == 0)  g_backend = YON_BACKEND_L2_SEPARATE;
        else if (strcmp(be, "shm") == 0)  g_backend = YON_BACKEND_L2_SHM;
        else g_backend = YON_BACKEND_L1_SHARED;
    }
    g_yon_heap = yon_xheap_create();
    if (!g_yon_heap) {
        fprintf(stderr, "[YON-RT] FATAL: yon_xheap_create failed\n");
        abort();
    }
    /* heap_id 0 = __Default, always present. */
    g_spaces[0].name = strdup("__Default");
    g_spaces[0].occupancy = 0;
    g_spaces[0].fold_name = NULL;
    g_spaces[0].accumulator = YON_SECTION_INVALID;
    /* L2_SEPARATE/SHM: heap_id 0 ha il proprio heap. */
    if (g_backend == YON_BACKEND_L2_SEPARATE) {
        g_spaces[0].heap = yon_xheap_create();
    } else if (g_backend == YON_BACKEND_L2_SHM) {
        g_spaces[0].heap = yon_xheap_create_with_backing(
            YON_HEAP_BACKING_SHM, "/yon_space___Default", 1);
        if (!g_spaces[0].heap) {
            fprintf(stderr,
                    "[YON-RT L2_SHM] failed shm for __Default, fallback PRIVATE\n");
            g_spaces[0].heap = yon_xheap_create();
        }
    } else {
        g_spaces[0].heap = NULL;
    }
    g_n_spaces = 1;
    g_initialized = 1;

    if (g_backend != YON_BACKEND_L1_SHARED) {
        const char *bname =
            g_backend == YON_BACKEND_L2_SEPARATE ? "L2_SEPARATE" :
            g_backend == YON_BACKEND_L2_SHM      ? "L2_SHM" : "UNKNOWN";
        fprintf(stderr, "[YON-RT L2] backend: %s\n", bname);
    }
}

static void ensure_init(void) {
    if (!g_initialized) yon_rt_init();
}

uint32_t yon_rt_register_space(const char *name) {
    ensure_init();
    if (!name) return YON_HEAP_ID_INVALID;
    /* Idempotent: if already registered, return the existing heap_id. */
    for (uint32_t i = 0; i < g_n_spaces; i++) {
        if (strcmp(g_spaces[i].name, name) == 0) return i;
    }
    if (g_n_spaces >= YON_MAX_SPACES) {
        fprintf(stderr, "[YON-RT] register_space: YON_MAX_SPACES exceeded\n");
        return YON_HEAP_ID_INVALID;
    }
    uint32_t id = g_n_spaces++;
    g_spaces[id].name = strdup(name);
    g_spaces[id].occupancy = 0;
    g_spaces[id].fold_name = NULL;
    g_spaces[id].accumulator = YON_SECTION_INVALID;
    /* Each space has its own physical heap under SEPARATE/SHM. In L1_SHARED it
     * stays NULL (heap_for returns g_yon_heap). */
    if (g_backend == YON_BACKEND_L2_SEPARATE) {
        g_spaces[id].heap = yon_xheap_create();
    } else if (g_backend == YON_BACKEND_L2_SHM) {
        /* The shm name is derived from the space name. Convention:
         * /yon_space_<name>. Idempotent: the first process creates it, the
         * others attach. */
        char shm_name[256];
        snprintf(shm_name, sizeof(shm_name), "/yon_space_%s", name);
        g_spaces[id].heap = yon_xheap_create_with_backing(
            YON_HEAP_BACKING_SHM, shm_name, 1);
        if (!g_spaces[id].heap) {
            fprintf(stderr,
                    "[YON-RT L2_SHM] failed to create/attach shm for space '%s'\n",
                    name);
            /* Safe fallback: heap NULL, heap_for will return g_yon_heap. */
        } else {
            fprintf(stderr,
                    "[YON-RT L2_SHM] space '%s' bound to shm '%s'\n",
                    name, shm_name);
        }
    } else {
        g_spaces[id].heap = NULL;
    }
    return id;
}

/* Register a space with a declared semilattice fold. fold_name is a string in
 * the whitelist (sum_f64/max_f64/min_f64/sum_i64/max_i64/min_i64/sum_vec_f64/
 * max_vec_f64/or_bitset). Validation is on the compiler side (already done by
 * the parser via validate_fold_name); here we only register. */
uint32_t yon_rt_register_space_with_fold(const char *name, const char *fold_name) {
    uint32_t id = yon_rt_register_space(name);
    if (id == YON_HEAP_ID_INVALID) return id;
    if (fold_name) {
        if (g_spaces[id].fold_name) free(g_spaces[id].fold_name);
        g_spaces[id].fold_name = strdup(fold_name);
        fprintf(stderr,
                "[YON-RT] space '%s' (heap=%u) with fold '%s'\n",
                name, id, fold_name);
    }
    return id;
}

uint32_t yon_rt_lookup_space(const char *name) {
    ensure_init();
    if (!name) return YON_HEAP_ID_INVALID;
    for (uint32_t i = 0; i < g_n_spaces; i++) {
        if (strcmp(g_spaces[i].name, name) == 0) return i;
    }
    return YON_HEAP_ID_INVALID;
}

uint32_t yon_rt_space_count(void) {
    ensure_init();
    return g_n_spaces;
}

/* ============================================================== */
/* Payload header: 4-byte length + 4-byte heap_id + payload         */
/* ============================================================== */

/* Layout:
 *   [uint32_t length][uint32_t heap_id][... length bytes of payload ...]
 *
 * The heap_id in the blob lets field_load validate that the access is
 * consistent with the heap the caller thinks it is reading.
 */

/* The blob helpers (alloc_payload_blob, blob_bytes, blob_length,
 * blob_heap_id) were retired. The heap stores payloads directly in its
 * internal arena; yon_xheap_slot_t has payload_offset and payload_size with no
 * separate header. */

/* Content-addressing now happens inside yon_xheap_put, which looks up the
 * content_index and returns the existing slot_index (dedup) or allocates a new
 * one.
 *
 * No more compute_xcoord/prefix heap_id: dedup is per-heap (each space has its
 * own yon_xheap_t under L2_SEPARATE/SHM; in L1_SHARED all spaces share the
 * singleton heap, so dedup is global — acceptable since it is pure
 * content-addressing). */

/* ============================================================== */
/* Place instance management                                       */
/* ============================================================== */

yon_section_t yon_rt_new(uint32_t heap_id,
                          const void *payload_bytes, uint32_t n_bytes) {
    ensure_init();
    if (heap_id >= g_n_spaces) {
        fprintf(stderr,
                "[YON-RT] yon_rt_new: heap_id=%u not registered (n_spaces=%u)\n",
                heap_id, g_n_spaces);
        return YON_SECTION_INVALID;
    }

    /* put into the heap returns slot_index. Natural dedup via the internal
     * content_index.
     *
     * In L2_SEPARATE/SHM each heap_id has its own yon_xheap_t (and thus its own
     * content_index and slot space) — physical partition. In L1_SHARED a single
     * heap for all — global dedup by content. To preserve the logical partition
     * even in L1_SHARED, we prefix the payload with heap_id (4 bytes). */
    yon_xheap_t *h = heap_for(heap_id);
    uint32_t slot_idx;
    if (g_backend == YON_BACKEND_L1_SHARED && heap_id != YON_HEAP_ID_DEFAULT) {
        /* Prefix heap_id for logical partition in a shared heap. */
        uint8_t stack_buf[256];
        uint8_t *combined = stack_buf;
        size_t combined_size = sizeof(uint32_t) + n_bytes;
        if (combined_size > sizeof(stack_buf)) {
            combined = malloc(combined_size);
            if (!combined) return YON_SECTION_INVALID;
        }
        memcpy(combined, &heap_id, sizeof(uint32_t));
        memcpy(combined + sizeof(uint32_t), payload_bytes, n_bytes);
        slot_idx = yon_xheap_put(h, combined, (uint32_t)combined_size, YON_TAG_USER1);
        if (combined != stack_buf) free(combined);
    } else {
        slot_idx = yon_xheap_put(h, payload_bytes, n_bytes, YON_TAG_USER1);
    }

    if (slot_idx == YON_HEAP_SLOT_INVALID) {
        fprintf(stderr, "[YON-RT] yon_rt_new: put failed (heap=%u n=%u)\n",
                heap_id, n_bytes);
        return YON_SECTION_INVALID;
    }
    g_spaces[heap_id].occupancy++;
    yon_section_t result = yon_section_pack(heap_id, slot_idx);
    return result;
}

int yon_rt_field_load(yon_section_t sec, uint32_t offset,
                      uint32_t size, void *out) {
    ensure_init();
    uint32_t heap_id = yon_section_heap(sec);
    uint32_t slot_idx = yon_section_slot(sec);
    yon_xheap_t *h = heap_for(heap_id);
    const yon_xheap_slot_t *slot = yon_xheap_get(h, slot_idx);
    if (!slot || slot->payload_offset == 0) {
        memset(out, 0, size);
        return -1;
    }
    if (offset + size > slot->payload_size) {
        memset(out, 0, size);
        fprintf(stderr,
                "[YON-RT] field_load OOB: offset=%u size=%u payload_size=%u\n",
                offset, size, slot->payload_size);
        return -1;
    }
    const uint8_t *payload = (const uint8_t *)yon_xheap_slot_payload(h, slot);
    if (!payload) {
        memset(out, 0, size);
        return -1;
    }
    /* In L1_SHARED the payload includes the heap_id prefix (4 bytes) for logical
     * partitioning. Skip it on read. */
    uint32_t prefix_skip = 0;
    if (g_backend == YON_BACKEND_L1_SHARED && heap_id != YON_HEAP_ID_DEFAULT) {
        prefix_skip = sizeof(uint32_t);
    }
    if (offset + size + prefix_skip > slot->payload_size) {
        memset(out, 0, size);
        fprintf(stderr,
                "[YON-RT] field_load OOB (with prefix): offset=%u size=%u payload_size=%u prefix=%u\n",
                offset, size, slot->payload_size, prefix_skip);
        return -1;
    }
    memcpy(out, payload + prefix_skip + offset, size);
    return 0;
}

/* ============================================================== */
/* Flatten: a place's content as position-independent bytes        */
/* ============================================================== */

/* The outbound half of the wormhole. Copy the section's raw payload (minus
 * the L1_SHARED heap_id prefix) into out_buf and return the byte count, or -1
 * on error / if cap is too small. The bytes are pure content, valid in any
 * heap: rebuild with yon_rt_new(consumer_heap, buf, n) in the consumer's own
 * heap. Scalar fields live inline in the payload, so for an all-scalar place
 * this is the whole story. Handle-valued fields (text, list) hold a foreign
 * handle inline and are NOT followed here; inlining them recursively is the
 * next seal (variable-length frames). */
int32_t yon_rt_flatten(yon_section_t sec, void *out_buf, uint32_t cap) {
    ensure_init();
    uint32_t heap_id = yon_section_heap(sec);
    uint32_t slot_idx = yon_section_slot(sec);
    yon_xheap_t *h = heap_for(heap_id);
    const yon_xheap_slot_t *slot = yon_xheap_get(h, slot_idx);
    if (!slot || slot->payload_offset == 0) return -1;
    const uint8_t *payload = (const uint8_t *)yon_xheap_slot_payload(h, slot);
    if (!payload) return -1;
    uint32_t prefix_skip = 0;
    if (g_backend == YON_BACKEND_L1_SHARED && heap_id != YON_HEAP_ID_DEFAULT) {
        prefix_skip = sizeof(uint32_t);
    }
    if (prefix_skip > slot->payload_size) return -1;
    uint32_t raw_size = slot->payload_size - prefix_skip;
    if (raw_size > cap) return -1;
    memcpy(out_buf, payload + prefix_skip, raw_size);
    return (int32_t)raw_size;
}



/* ============================================================== */
/* P8 #86: FREE_MERGE non-triviale via fold (CRDT-style)           */
/* ============================================================== */

/* Canonical folds on f64. All commutative + associative.
 * `sum` is not idempotent — but for CRDT counter-style it is fine if the
 * operations represent increments. For an idempotent LWW-Register, use `max`
 * on the timestamp. */

void yon_fold_sum_f64(void *acc, const void *new_val, uint32_t size) {
    if (size != sizeof(double)) return;
    double *a = (double *)acc;
    const double *v = (const double *)new_val;
    *a += *v;
}

void yon_fold_max_f64(void *acc, const void *new_val, uint32_t size) {
    if (size != sizeof(double)) return;
    double *a = (double *)acc;
    const double *v = (const double *)new_val;
    if (*v > *a) *a = *v;
}

void yon_fold_min_f64(void *acc, const void *new_val, uint32_t size) {
    if (size != sizeof(double)) return;
    double *a = (double *)acc;
    const double *v = (const double *)new_val;
    if (*v < *a) *a = *v;
}

/* === Fold int64 === */
void yon_fold_sum_i64(void *acc, const void *new_val, uint32_t size) {
    if (size != sizeof(int64_t)) return;
    int64_t *a = (int64_t *)acc;
    const int64_t *v = (const int64_t *)new_val;
    *a += *v;
}

void yon_fold_max_i64(void *acc, const void *new_val, uint32_t size) {
    if (size != sizeof(int64_t)) return;
    int64_t *a = (int64_t *)acc;
    const int64_t *v = (const int64_t *)new_val;
    if (*v > *a) *a = *v;
}

void yon_fold_min_i64(void *acc, const void *new_val, uint32_t size) {
    if (size != sizeof(int64_t)) return;
    int64_t *a = (int64_t *)acc;
    const int64_t *v = (const int64_t *)new_val;
    if (*v < *a) *a = *v;
}

/* === Fold element-wise vector f64 === */
void yon_fold_sum_vec_f64(void *acc, const void *new_val, uint32_t size) {
    if (size % sizeof(double) != 0) return;
    uint32_t n = size / sizeof(double);
    double *a = (double *)acc;
    const double *v = (const double *)new_val;
    for (uint32_t i = 0; i < n; i++) a[i] += v[i];
}

void yon_fold_max_vec_f64(void *acc, const void *new_val, uint32_t size) {
    if (size % sizeof(double) != 0) return;
    uint32_t n = size / sizeof(double);
    double *a = (double *)acc;
    const double *v = (const double *)new_val;
    for (uint32_t i = 0; i < n; i++) {
        if (v[i] > a[i]) a[i] = v[i];
    }
}

/* === OR-set bitset CRDT === */
void yon_fold_or_bitset(void *acc, const void *new_val, uint32_t size) {
    uint8_t *a = (uint8_t *)acc;
    const uint8_t *v = (const uint8_t *)new_val;
    /* Bulk via u64 when aligned */
    uint32_t n_u64 = size / sizeof(uint64_t);
    uint64_t *a64 = (uint64_t *)acc;
    const uint64_t *v64 = (const uint64_t *)new_val;
    for (uint32_t i = 0; i < n_u64; i++) a64[i] |= v64[i];
    /* Tail byte-by-byte */
    for (uint32_t i = n_u64 * sizeof(uint64_t); i < size; i++) a[i] |= v[i];
}

yon_section_t yon_rt_fold(uint32_t heap_id,
                          yon_section_t prev,
                          const void *initial,
                          uint32_t n_bytes,
                          yon_fold_fn fold) {
    ensure_init();
    if (heap_id >= g_n_spaces) {
        fprintf(stderr, "[YON-RT #86] fold: heap_id=%u not registered\n", heap_id);
        return YON_SECTION_INVALID;
    }
    if (!initial || n_bytes == 0 || !fold) return YON_SECTION_INVALID;

    /* Base case: prev INVALID -> allocate the initial slot (semilattice
     * bottom). Equivalent to yon_rt_new, reuses the same pipeline. */
    if (prev == YON_SECTION_INVALID) {
        yon_section_t result = yon_rt_new(heap_id, initial, n_bytes);
        if (result != YON_SECTION_INVALID) {
            fprintf(stderr,
                    "[YON-RT #86] fold init: heap=%u slot=%u (semilattice bottom)\n",
                    heap_id, yon_section_slot(result));
        }
        return result;
    }

    /* Inductive case: read the payload, apply the fold in place. */
    uint32_t prev_heap = yon_section_heap(prev);
    uint32_t prev_slot = yon_section_slot(prev);
    if (prev_heap != heap_id) {
        fprintf(stderr,
                "[YON-RT #86] fold: prev section heap=%u != heap_id=%u\n",
                prev_heap, heap_id);
        return YON_SECTION_INVALID;
    }

    yon_xheap_t *h = heap_for(heap_id);
    const yon_xheap_slot_t *slot = yon_xheap_get(h, prev_slot);
    if (!slot || slot->payload_offset == 0) {
        fprintf(stderr,
                "[YON-RT #86] fold: prev slot=%u invalid in heap=%u\n",
                prev_slot, heap_id);
        return YON_SECTION_INVALID;
    }

    /* In L1_SHARED the payload includes the heap_id prefix (4 bytes). Skip it
     * to get the raw bytes to modify. */
    uint32_t prefix_skip = 0;
    if (g_backend == YON_BACKEND_L1_SHARED && heap_id != YON_HEAP_ID_DEFAULT) {
        prefix_skip = sizeof(uint32_t);
    }
    uint32_t raw_size = slot->payload_size - prefix_skip;
    if (raw_size != n_bytes) {
        fprintf(stderr,
                "[YON-RT #86] fold: size mismatch (slot raw=%u, given=%u)\n",
                raw_size, n_bytes);
        return YON_SECTION_INVALID;
    }

    /* In-place mutation under a cross-process lock. The lock guarantees that
     * concurrent folds do not overlap in load->op->store; commutativity of the
     * fold already guaranteed eventual convergence, now we also have atomicity
     * for each individual apply.
     *
     * Trade-off: the cost of flock per fold; benefit: formal convergence even
     * on non-x86 hardware (ARM weak memory, etc).
     *
     * Under YON_BACKEND=L1_SHARED the lock is a no-op (no cross-process). Under
     * SEPARATE/SHM it is a cross-process flock LOCK_EX. */
    if (yon_xheap_lock(h) != 0) {
        fprintf(stderr, "[YON-RT #86] fold: lock acquisition failed\n");
        return YON_SECTION_INVALID;
    }
    void *payload_writable = (void *)(h->arena + slot->payload_offset + prefix_skip);
    fold(payload_writable, initial, n_bytes);
    yon_xheap_unlock(h);

    fprintf(stderr,
            "[YON-RT #86] fold applied: heap=%u slot=%u size=%u (atomic in-place)\n",
            heap_id, prev_slot, n_bytes);

    /* Section unchanged (same slot_index). */
    return prev;
}

yon_section_t yon_rt_fold_named(uint32_t heap_id,
                                 yon_section_t prev,
                                 const void *initial,
                                 uint32_t n_bytes,
                                 const char *fold_name) {
    yon_fold_fn fn = NULL;
    if (!fold_name) {
        fprintf(stderr, "[YON-RT #86] fold_named: NULL fold_name\n");
        return YON_SECTION_INVALID;
    }
    if (strcmp(fold_name, "sum_f64") == 0)         fn = yon_fold_sum_f64;
    else if (strcmp(fold_name, "max_f64") == 0)    fn = yon_fold_max_f64;
    else if (strcmp(fold_name, "min_f64") == 0)    fn = yon_fold_min_f64;
    else if (strcmp(fold_name, "sum_i64") == 0)    fn = yon_fold_sum_i64;
    else if (strcmp(fold_name, "max_i64") == 0)    fn = yon_fold_max_i64;
    else if (strcmp(fold_name, "min_i64") == 0)    fn = yon_fold_min_i64;
    else if (strcmp(fold_name, "sum_vec_f64") == 0) fn = yon_fold_sum_vec_f64;
    else if (strcmp(fold_name, "max_vec_f64") == 0) fn = yon_fold_max_vec_f64;
    else if (strcmp(fold_name, "or_bitset") == 0)   fn = yon_fold_or_bitset;
    else {
        fprintf(stderr, "[YON-RT #86] fold_named: unknown fold '%s'\n", fold_name);
        return YON_SECTION_INVALID;
    }
    /* If prev = INVALID (the caller passes bottom) but the space already has an
     * active accumulator, use it as prev to accumulate instead of creating a
     * new slot.
     *
     * In L2_SHM/L2_SEPARATE the accumulator must be visible cross-process.
     * Strategy: the first occupied slot of the xheap (slot=0) is the
     * convention "accumulator of the space-with-fold" in the L2 backend.
     *
     * Limitation: the slot=0=accumulator inference is active only in the
     * L2_SHM/L2_SEPARATE backend, where the per-space physical separation
     * guarantees that slot=0 is actually the accumulator. In L1_SHARED the
     * singleton heap may have slot=0 occupied by a non-fold payload, so it is
     * disabled. */
    if (prev == YON_SECTION_INVALID && heap_id < g_n_spaces
        && g_spaces[heap_id].fold_name != NULL) {
        /* Process-local accumulator first */
        if (g_spaces[heap_id].accumulator != YON_SECTION_INVALID) {
            prev = g_spaces[heap_id].accumulator;
            fprintf(stderr,
                    "[YON-RT S4] fold_named: using process-local accumulator prev=(heap=%u, slot=%u)\n",
                    yon_section_heap(prev), yon_section_slot(prev));
        } else if (g_backend != YON_BACKEND_L1_SHARED) {
            /* Cross-process L2: look for an occupied slot=0 (convention) */
            yon_xheap_t *h = heap_for(heap_id);
            if (h && yon_xheap_is_occupied(h, 0)) {
                prev = (yon_section_t)((uint64_t)heap_id << 32) | 0;
                fprintf(stderr,
                        "[YON-RT S4 multi-proc] fold_named: using SHM slot=0 accumulator (heap=%u)\n",
                        heap_id);
            }
        }
    }
    yon_section_t result = yon_rt_fold(heap_id, prev, initial, n_bytes, fn);
    /* Update the space's accumulator to the new result. */
    if (result != YON_SECTION_INVALID && heap_id < g_n_spaces) {
        g_spaces[heap_id].accumulator = result;
    }
    return result;
}

/* ============================================================== */
/* P8 #88: Stop-the-world checkpoint                              */
/* ============================================================== */

int yon_rt_checkpoint_begin(yon_rt_checkpoint_t *out) {
    ensure_init();
    if (!out) return -1;
    if (g_n_spaces == 0) {
        fprintf(stderr, "[YON-RT #88] checkpoint: no spaces registered\n");
        return -1;
    }
    if (g_n_spaces > YON_MAX_CHECKPOINT_HEAPS) {
        fprintf(stderr, "[YON-RT #88] checkpoint: too many spaces (%u > %u)\n",
                g_n_spaces, YON_MAX_CHECKPOINT_HEAPS);
        return -1;
    }

    memset(out, 0, sizeof(*out));
    out->n_heaps = g_n_spaces;

    /* Lock in ascending order to avoid deadlock with other cross-space ops
     * (TWO_PHASE uses the same order). */
    for (uint32_t i = 0; i < g_n_spaces; i++) {
        yon_xheap_t *h = heap_for(i);
        if (!h) continue;
        if (yon_xheap_lock(h) != 0) {
            fprintf(stderr,
                    "[YON-RT #88] checkpoint: lock failed on heap=%u\n", i);
            /* Rollback: unlock the ones already taken */
            for (uint32_t j = 0; j < i; j++) {
                yon_xheap_t *hj = heap_for(j);
                if (hj) yon_xheap_unlock(hj);
            }
            return -1;
        }
        out->heap_ids[i] = i;
        out->occupancy[i] = (uint32_t)yon_xheap_occupancy(h);
        out->arena_used[i] = h->arena_used;
        out->magic[i] = h->magic;
        out->version[i] = h->version;
    }

    fprintf(stderr,
            "[YON-RT #88] checkpoint begin: %u heaps frozen (stop-the-world)\n",
            out->n_heaps);
    return 0;
}

int yon_rt_checkpoint_check(const yon_rt_checkpoint_t *snap,
                             uint32_t *out_n_violations,
                             uint32_t *out_first_violator) {
    if (!snap) return -1;
    uint32_t n_violations = 0;
    uint32_t first_violator = (uint32_t)-1;

    for (uint32_t i = 0; i < snap->n_heaps; i++) {
        int violation = 0;
        if (snap->magic[i] != YON_HEAP_MAGIC) {
            fprintf(stderr,
                    "[YON-RT #88] coherence violation: heap=%u magic=0x%x != 0x%x\n",
                    snap->heap_ids[i], snap->magic[i], YON_HEAP_MAGIC);
            violation = 1;
        }
        if (snap->version[i] != YON_HEAP_VERSION) {
            fprintf(stderr,
                    "[YON-RT #88] coherence violation: heap=%u version=%u != %u\n",
                    snap->heap_ids[i], snap->version[i], YON_HEAP_VERSION);
            violation = 1;
        }
        if (violation) {
            n_violations++;
            if (first_violator == (uint32_t)-1) first_violator = snap->heap_ids[i];
        }
    }

    if (out_n_violations) *out_n_violations = n_violations;
    if (out_first_violator) *out_first_violator = first_violator;

    if (n_violations == 0) {
        fprintf(stderr,
                "[YON-RT #88] coherence check: OK (%u heaps verified)\n",
                snap->n_heaps);
        return 0;
    }
    fprintf(stderr,
            "[YON-RT #88] coherence check: %u violations (first heap=%u)\n",
            n_violations, first_violator);
    return -1;
}

int yon_rt_checkpoint_end(yon_rt_checkpoint_t *snap) {
    if (!snap) return -1;
    /* Unlock in reverse order */
    for (uint32_t i = snap->n_heaps; i > 0; i--) {
        yon_xheap_t *h = heap_for(i - 1);
        if (h) yon_xheap_unlock(h);
    }
    fprintf(stderr,
            "[YON-RT #88] checkpoint end: %u heaps released (resumed)\n",
            snap->n_heaps);
    return 0;
}

/* ============================================================== */
/* P8 #89 layer 0: Online schema evolution (versioning + migration) */
/* ============================================================== */

#define YON_MAX_MIGRATIONS 32

typedef struct {
    char     place_name[64];
    uint32_t v_from;
    uint32_t v_to;
    uint32_t new_payload_size;
    yon_migration_fn fn;
} migration_entry_t;

static migration_entry_t g_migrations[YON_MAX_MIGRATIONS];
static int g_n_migrations = 0;

int yon_rt_register_migration(const char *place_name,
                               uint32_t v_from,
                               uint32_t v_to,
                               uint32_t new_payload_size,
                               yon_migration_fn fn) {
    if (!place_name || !fn) return -1;
    if (g_n_migrations >= YON_MAX_MIGRATIONS) {
        fprintf(stderr, "[YON-RT #89] migration registry full\n");
        return -1;
    }
    /* Duplicate check */
    for (int i = 0; i < g_n_migrations; i++) {
        if (strcmp(g_migrations[i].place_name, place_name) == 0
            && g_migrations[i].v_from == v_from
            && g_migrations[i].v_to == v_to) {
            fprintf(stderr,
                    "[YON-RT #89] migration already registered: %s %u->%u\n",
                    place_name, v_from, v_to);
            return -1;
        }
    }
    migration_entry_t *m = &g_migrations[g_n_migrations++];
    strncpy(m->place_name, place_name, sizeof(m->place_name) - 1);
    m->place_name[sizeof(m->place_name) - 1] = '\0';
    m->v_from = v_from;
    m->v_to = v_to;
    m->new_payload_size = new_payload_size;
    m->fn = fn;
    fprintf(stderr,
            "[YON-RT #89] migration registered: %s v%u -> v%u (new_size=%u)\n",
            place_name, v_from, v_to, new_payload_size);
    return 0;
}

int yon_rt_migration_count(void) {
    return g_n_migrations;
}

/* Look up a migration. Returns NULL if not found. */
static const migration_entry_t *find_migration(const char *place_name,
                                                uint32_t v_from,
                                                uint32_t v_to) {
    for (int i = 0; i < g_n_migrations; i++) {
        if (strcmp(g_migrations[i].place_name, place_name) == 0
            && g_migrations[i].v_from == v_from
            && g_migrations[i].v_to == v_to) {
            return &g_migrations[i];
        }
    }
    return NULL;
}

/* yon_rt_new_v: allocate with an explicit schema_version. Reuses the yon_rt_new
 * path but calls yon_xheap_put_v instead of yon_xheap_put. */
yon_section_t yon_rt_new_v(uint32_t heap_id,
                            const void *payload_bytes, uint32_t n_bytes,
                            const char *place_name, uint32_t schema_version) {
    ensure_init();
    (void)place_name;  /* not used yet — reserved for higher layers */
    if (heap_id >= g_n_spaces) {
        fprintf(stderr,
                "[YON-RT #89] new_v: heap_id=%u not registered\n", heap_id);
        return YON_SECTION_INVALID;
    }

    /* Policy-based log removed; see the comment above. */

    yon_xheap_t *h = heap_for(heap_id);
    uint32_t slot_idx;
    if (g_backend == YON_BACKEND_L1_SHARED && heap_id != YON_HEAP_ID_DEFAULT) {
        uint8_t stack_buf[256];
        uint8_t *combined = stack_buf;
        size_t combined_size = sizeof(uint32_t) + n_bytes;
        if (combined_size > sizeof(stack_buf)) {
            combined = malloc(combined_size);
            if (!combined) return YON_SECTION_INVALID;
        }
        memcpy(combined, &heap_id, sizeof(uint32_t));
        memcpy(combined + sizeof(uint32_t), payload_bytes, n_bytes);
        slot_idx = yon_xheap_put_v(h, combined, (uint32_t)combined_size,
                                    YON_TAG_USER1, schema_version);
        if (combined != stack_buf) free(combined);
    } else {
        slot_idx = yon_xheap_put_v(h, payload_bytes, n_bytes,
                                    YON_TAG_USER1, schema_version);
    }

    if (slot_idx == YON_HEAP_SLOT_INVALID) {
        fprintf(stderr, "[YON-RT #89] new_v: put failed\n");
        return YON_SECTION_INVALID;
    }
    g_spaces[heap_id].occupancy++;
    yon_section_t result = yon_section_pack(heap_id, slot_idx);
    return result;
}

int yon_rt_field_load_v(yon_section_t sec,
                         const char *place_name,
                         uint32_t requested_version,
                         uint32_t offset, uint32_t size, void *out) {
    ensure_init();
    uint32_t heap_id = yon_section_heap(sec);
    uint32_t slot_idx = yon_section_slot(sec);
    yon_xheap_t *h = heap_for(heap_id);
    const yon_xheap_slot_t *slot = yon_xheap_get(h, slot_idx);
    if (!slot || slot->payload_offset == 0) {
        memset(out, 0, size);
        return -1;
    }

    uint32_t slot_version = slot->schema_version;
    if (slot_version == requested_version || requested_version == 0) {
        /* No migration: read directly. */
        return yon_rt_field_load(sec, offset, size, out);
    }

    /* Migration requested: look for a chain v_slot -> ... -> v_requested. */
    if (!place_name) {
        fprintf(stderr,
                "[YON-RT #89] field_load_v: place_name NULL but versions differ (%u vs %u)\n",
                slot_version, requested_version);
        return -1;
    }

    /* For simplicity: we support only direct migration v_slot -> v_req.
     * A multi-step chain is a future layer. */
    const migration_entry_t *m = find_migration(place_name,
                                                  slot_version,
                                                  requested_version);
    if (!m) {
        fprintf(stderr,
                "[YON-RT #89] field_load_v: no migration %s v%u -> v%u\n",
                place_name, slot_version, requested_version);
        return -1;
    }

    /* Retrieve the current payload */
    const uint8_t *src_payload = (const uint8_t *)yon_xheap_slot_payload(h, slot);
    if (!src_payload) return -1;
    uint32_t prefix_skip = 0;
    if (g_backend == YON_BACKEND_L1_SHARED && heap_id != YON_HEAP_ID_DEFAULT) {
        prefix_skip = sizeof(uint32_t);
    }
    if (prefix_skip > slot->payload_size) return -1;
    uint32_t raw_size = slot->payload_size - prefix_skip;

    /* Allocate a temporary buffer for the migrated payload */
    uint8_t stack_buf[512];
    uint8_t *new_buf = stack_buf;
    if (m->new_payload_size > sizeof(stack_buf)) {
        new_buf = malloc(m->new_payload_size);
        if (!new_buf) return -1;
    }

    int rc = m->fn(src_payload + prefix_skip, raw_size,
                   new_buf, m->new_payload_size);
    if (rc != 0) {
        if (new_buf != stack_buf) free(new_buf);
        fprintf(stderr, "[YON-RT #89] migration fn failed rc=%d\n", rc);
        return -1;
    }

    fprintf(stderr,
            "[YON-RT #89] lazy migration applied: %s v%u -> v%u (slot=%u)\n",
            place_name, slot_version, requested_version, slot_idx);

    /* Read from the migrated buffer */
    if (offset + size > m->new_payload_size) {
        if (new_buf != stack_buf) free(new_buf);
        return -1;
    }
    memcpy(out, new_buf + offset, size);
    if (new_buf != stack_buf) free(new_buf);
    return 0;
}

/* ============================================================== */
/* Coordination protocol derivation                                */
/* ============================================================== */

/* Derivation of the coordination shape from the properties of the geometric
 * morphism. The 3 YON_POLICY_* macros and the function
 * yon_rt_derive_coordination were removed; the coordination shape is now
 * derived only via yon_rt_derive_coordination_from_gm, activated in
 * begin_cross_space_op when it finds registered gm in the runtime registry.
 *
 * Categorically honest mapping:
 *   adj + both_exact  -> TWO_PHASE  (both adjoints preserve their limits
 *                                    -> linearizability)
 *   adj + one_exact   -> SAGA       (only one lax -> compensation needed)
 *   adj + neither     -> FREE_MERGE (both lax -> semilattice join)
 *   no adj            -> LOCAL      (no cross-topos relation)
 *
 * Completely replaces the pre-existing policy enum table. The automatic
 * dispatch happens in begin_cross_space_op via yon_rt_lookup_geom_morphism. */
uint32_t yon_rt_derive_coordination_from_gm(
    const yon_geom_morphism_props_t *props) {
    if (!props) return YON_COORD_LOCAL;
    if (!props->adjunction) {
        /* Without an adjunction there is no formal relation; fallback. */
        return YON_COORD_LOCAL;
    }
    int both_exact = props->f_star_exact && props->f_lower_star_exact;
    int one_exact  = props->f_star_exact ^ props->f_lower_star_exact;
    if (both_exact) return YON_COORD_TWO_PHASE;
    if (one_exact)  return YON_COORD_LAX;
    return YON_COORD_FREE_MERGE;
}

/* ============================================================== */
/* Runtime geom_morphism registry                                  */
/* ============================================================== */

typedef struct {
    char     name[64];
    char     source_topos[64];
    char     target_topos[64];
    yon_geom_morphism_props_t props;
    int      occupied;
} geom_morphism_entry_t;

static geom_morphism_entry_t g_geom_morphisms[YON_MAX_GEOM_MORPHISMS];
static int g_n_geom_morphisms = 0;

int yon_rt_register_geom_morphism(const char *name,
                                   const char *source_topos,
                                   const char *target_topos,
                                   const yon_geom_morphism_props_t *props) {
    if (!name || !source_topos || !target_topos || !props) return -1;
    if (g_n_geom_morphisms >= YON_MAX_GEOM_MORPHISMS) {
        fprintf(stderr, "[YON-RT] gm registry full (max %d)\n",
                YON_MAX_GEOM_MORPHISMS);
        return -1;
    }
    /* Duplicate check (same source+target). */
    for (int i = 0; i < g_n_geom_morphisms; i++) {
        if (g_geom_morphisms[i].occupied
            && strcmp(g_geom_morphisms[i].source_topos, source_topos) == 0
            && strcmp(g_geom_morphisms[i].target_topos, target_topos) == 0) {
            fprintf(stderr,
                    "[YON-RT] gm already registered for %s -> %s\n",
                    source_topos, target_topos);
            return -1;
        }
    }
    geom_morphism_entry_t *e = &g_geom_morphisms[g_n_geom_morphisms++];
    strncpy(e->name, name, sizeof(e->name) - 1); e->name[sizeof(e->name)-1] = '\0';
    strncpy(e->source_topos, source_topos, sizeof(e->source_topos) - 1);
    e->source_topos[sizeof(e->source_topos)-1] = '\0';
    strncpy(e->target_topos, target_topos, sizeof(e->target_topos) - 1);
    e->target_topos[sizeof(e->target_topos)-1] = '\0';
    e->props = *props;
    e->occupied = 1;
    fprintf(stderr,
            "[YON-RT] geom_morphism registered: %s : %s -> %s "
            "(adj=%u, f*_exact=%u, f_*_exact=%u)\n",
            name, source_topos, target_topos,
            props->adjunction, props->f_star_exact, props->f_lower_star_exact);
    return 0;
}

int yon_rt_geom_morphism_count(void) {
    return g_n_geom_morphisms;
}

int yon_rt_lookup_geom_morphism(const char *source_topos,
                                 const char *target_topos,
                                 yon_geom_morphism_props_t *out_props) {
    if (!source_topos || !target_topos || !out_props) return 0;
    for (int i = 0; i < g_n_geom_morphisms; i++) {
        if (!g_geom_morphisms[i].occupied) continue;
        if (strcmp(g_geom_morphisms[i].source_topos, source_topos) == 0
            && strcmp(g_geom_morphisms[i].target_topos, target_topos) == 0) {
            *out_props = g_geom_morphisms[i].props;
            return 1;
        }
    }
    return 0;
}

static const char *coord_name(uint32_t c) {
    switch (c) {
        case YON_COORD_LOCAL:      return "LOCAL";
        case YON_COORD_TWO_PHASE:  return "TWO_PHASE";
        case YON_COORD_LAX:       return "LAX";
        case YON_COORD_FREE_MERGE: return "FREE_MERGE";
        default:                   return "UNKNOWN";
    }
}

uint32_t yon_rt_begin_cross_space_op(const uint32_t *heap_ids, uint32_t n) {
    ensure_init();
    /* If there are registered geometric morphisms connecting the topoi
     * involved, derive the coordination shape categorically. Otherwise fall
     * back to the policy enum table (yon_rt_derive_coordination).
     *
     * Lookup strategy: for each pair (heap_a, heap_b) with a != b in the set,
     * look for a gm a -> b or b -> a among the registered ones. If found (at
     * least one): use derive_from_gm. Otherwise: enum fallback.
     *
     * Note: if several gm match different pairs, the most constraining wins
     * (TWO_PHASE > SAGA > FREE_MERGE > LOCAL). This is the canonical robustness
     * order: better to over-coordinate than under. */
    uint32_t coord = YON_COORD_LOCAL;
    int found_gm = 0;
    if (g_n_geom_morphisms > 0 && n >= 2) {
        for (uint32_t i = 0; i < n; i++) {
            for (uint32_t j = 0; j < n; j++) {
                if (i == j) continue;
                if (heap_ids[i] >= g_n_spaces || heap_ids[j] >= g_n_spaces) continue;
                const char *src = g_spaces[heap_ids[i]].name;
                const char *tgt = g_spaces[heap_ids[j]].name;
                yon_geom_morphism_props_t p;
                if (yon_rt_lookup_geom_morphism(src, tgt, &p)) {
                    uint32_t candidate = yon_rt_derive_coordination_from_gm(&p);
                    /* The most constraining one wins */
                    if (candidate == YON_COORD_TWO_PHASE) coord = YON_COORD_TWO_PHASE;
                    else if (candidate == YON_COORD_LAX && coord != YON_COORD_TWO_PHASE)
                        coord = YON_COORD_LAX;
                    else if (candidate == YON_COORD_FREE_MERGE
                             && coord != YON_COORD_TWO_PHASE
                             && coord != YON_COORD_LAX)
                        coord = YON_COORD_FREE_MERGE;
                    found_gm = 1;
                }
            }
        }
    }
    if (!found_gm) {
        /* No geom_morphism declared for the topoi involved: the semantics is
         * LOCAL (no cross-space coordination activated). If the program wanted
         * coordination, it had to declare a gm. */
        coord = YON_COORD_LOCAL;
        fprintf(stderr, "[YON-RT #83] begin cross-Space op: n=%u coord=%s heaps=[",
                n, coord_name(coord));
    } else {
        fprintf(stderr,
                "[YON-RT] begin cross-Space op via geom_morphism: "
                "n=%u coord=%s heaps=[", n, coord_name(coord));
    }
    for (uint32_t i = 0; i < n; i++) {
        fprintf(stderr, "%s%u", i > 0 ? "," : "", heap_ids[i]);
    }
    fprintf(stderr, "]\n");

    /* SAGA was removed from the runtime. The SAGA pattern is derived
     * categorically from a geom_morphism (adjunction without f_star exact), but
     * the runtime dispatch is no longer needed — the pattern is expressed via
     * reductions directly.
     *
     *  - TWO_PHASE  -> lock heaps in ascending order to avoid deadlock
     *  - FREE_MERGE / LOCAL / SAGA -> no-op (no runtime side effects) */
    if (coord == YON_COORD_TWO_PHASE) {
        /* Cross-process lock of all heaps involved. Only in L2_SHM does it
         * have real effect (flock); elsewhere a no-op. */
        for (uint32_t i = 0; i < n; i++) {
            yon_xheap_t *h = heap_for(heap_ids[i]);
            if (h) yon_xheap_lock(h);
        }
        fprintf(stderr, "[YON-RT #84] 2pc lock acquired on %u heap(s)\n", n);
    }

    /* Encode coord in the high bits of the token; low bits reserved for
     * future extension. */
    return coord;
}

void yon_rt_end_cross_space_op(uint32_t token) {
    ensure_init();
    uint32_t coord = token;

    /* P8 #85: saga commit rimossa.
     *  - TWO_PHASE  -> unlock in reverse order
     *  - SAGA / FREE_MERGE / LOCAL -> no-op */
    if (coord == YON_COORD_TWO_PHASE) {
        /* Unlock in reverse order. Without heap_ids as input we cannot unlock
         * specific ones; instead, unlock all registered heaps (no-op if not
         * locked). */
        for (uint32_t i = g_n_spaces; i > 0; i--) {
            yon_xheap_t *h = heap_for(i - 1);
            if (h) yon_xheap_unlock(h);
        }
        fprintf(stderr, "[YON-RT #84] 2pc unlock done\n");
    }

    fprintf(stderr, "[YON-RT #83] end cross-Space op: coord=%s\n",
            coord_name(token));
}

/* ============================================================== */
/* Cross-space streams                                             */
/* ============================================================== */

/* Stream registry: a static array, identified by stream_id. Each stream is an
 * in-memory ring buffer. */
#define YON_MAX_STREAMS 32

typedef struct yon_stream_s {
    char     *name;
    uint32_t  target_heap_id;  /* the consumer's space */
    uint32_t  slot_size;       /* bytes per value */
    uint8_t  *buffer;          /* ring buffer of n_slots x slot_size bytes */
    uint32_t  head;            /* next position to await */
    uint32_t  tail;            /* next position to emit */
    uint32_t  count;           /* number of values present */
    uint32_t  capacity;        /* in slots */
    uint32_t  closed;          /* structural EOF: no more writes will come */
} yon_stream_t;

static yon_stream_t g_streams[YON_MAX_STREAMS];
static uint32_t g_n_streams = 0;

uint32_t yon_rt_stream_create(const char *name,
                               uint32_t target_heap_id,
                               uint32_t slot_size) {
    ensure_init();
    if (!name) return YON_STREAM_INVALID;
    /* Idempotente: lookup per nome. */
    for (uint32_t i = 0; i < g_n_streams; i++) {
        if (strcmp(g_streams[i].name, name) == 0) return i;
    }
    if (g_n_streams >= YON_MAX_STREAMS) return YON_STREAM_INVALID;
    if (slot_size == 0 || slot_size > 256) return YON_STREAM_INVALID;
    uint32_t id = g_n_streams++;
    yon_stream_t *s = &g_streams[id];
    s->name = strdup(name);
    s->target_heap_id = target_heap_id;
    s->slot_size = slot_size;
    s->capacity = YON_STREAM_MAX_SLOTS;
    s->buffer = (uint8_t*)calloc(s->capacity, slot_size);
    s->head = 0;
    s->tail = 0;
    s->count = 0;
    s->closed = 0;
    if (!s->buffer) {
        free(s->name);
        g_n_streams--;
        return YON_STREAM_INVALID;
    }
    fprintf(stderr,
            "[YON-RT #87] stream_create: id=%u name='%s' target_heap=%u slot_size=%u\n",
            id, name, target_heap_id, slot_size);
    return id;
}

uint32_t yon_rt_stream_lookup(const char *name) {
    ensure_init();
    if (!name) return YON_STREAM_INVALID;
    for (uint32_t i = 0; i < g_n_streams; i++) {
        if (strcmp(g_streams[i].name, name) == 0) return i;
    }
    return YON_STREAM_INVALID;
}

int yon_rt_stream_emit(uint32_t stream_id, const void *value_ptr) {
    ensure_init();
    if (stream_id >= g_n_streams) return -1;
    yon_stream_t *s = &g_streams[stream_id];
    if (s->closed) return -1;  /* no writes after close */
    if (s->count >= s->capacity) {
        fprintf(stderr, "[YON-RT #87] stream_emit: stream %u FULL\n", stream_id);
        return -1;
    }
    memcpy(s->buffer + s->tail * s->slot_size, value_ptr, s->slot_size);
    s->tail = (s->tail + 1) % s->capacity;
    s->count++;
    return 0;
}

int yon_rt_stream_produce(uint32_t stream_id, const void *value_ptr) {
    /* P8 #87: produce == emit in L1 (no failure, no back-pressure).
     * In L2+ produce attendera' ack del consumer. */
    return yon_rt_stream_emit(stream_id, value_ptr);
}

int yon_rt_stream_await(uint32_t stream_id, void *out_ptr) {
    ensure_init();
    if (stream_id >= g_n_streams) return -1;
    yon_stream_t *s = &g_streams[stream_id];
    if (s->count == 0) {
        if (s->closed) return -2;  /* drained AND closed: structural EOF */
        fprintf(stderr, "[YON-RT #87] stream_await: stream %u EMPTY\n", stream_id);
        return -1;
    }
    memcpy(out_ptr, s->buffer + s->head * s->slot_size, s->slot_size);
    s->head = (s->head + 1) % s->capacity;
    s->count--;
    return 0;
}

uint32_t yon_rt_stream_size(uint32_t stream_id) {
    ensure_init();
    if (stream_id >= g_n_streams) return 0;
    return g_streams[stream_id].count;
}

/* ---- f64 wrappers for the frontend stdlib P8 #87 ---- */

/* Stream__make(target_heap_id_f64) -> stream_id as f64.
 * Creates a stream with an auto-generated name (in a future version the name
 * will come from the syntax `stream Name in Space { ty }`).
 * slot_size fissato a 8 byte (f64). */
double yon_rt_stream_make_f64(double target_heap_f64) {
    static uint32_t anon_counter = 0;
    char name[32];
    snprintf(name, sizeof(name), "__anon_stream_%u", anon_counter++);
    uint32_t target_heap = (uint32_t)target_heap_f64;
    uint32_t id = yon_rt_stream_create(name, target_heap, sizeof(double));
    if (id == YON_STREAM_INVALID) return -1.0;
    return (double)id;
}

double yon_rt_stream_emit_f64(double stream_id_f64, double value) {
    uint32_t id = (uint32_t)stream_id_f64;
    int rc = yon_rt_stream_emit(id, &value);
    return (double)rc;
}

double yon_rt_stream_await_f64(double stream_id_f64) {
    uint32_t id = (uint32_t)stream_id_f64;
    double out = 0.0;
    int rc = yon_rt_stream_await(id, &out);
    if (rc == -2) return (double)0xFFFFFFFFu;  /* EOF sentinel, same as the
                                                  fused pipelines' end marker */
    if (rc < 0) return -1.0;
    return out;
}

/* Structural close: no more writes will come. Queued values remain
 * readable; recv on a drained closed wire returns the EOF sentinel. */
uint32_t yon_rt_stream_close(uint32_t stream_id) {
    ensure_init();
    if (stream_id >= g_n_streams) return 1;
    g_streams[stream_id].closed = 1;
    return 0;
}

/* C aliases for the symbols used by the frontend stdlib. */
double Stream__make(double t)         { return yon_rt_stream_make_f64(t); }
double Stream__send(double s, double v) { return yon_rt_stream_emit_f64(s, v); }
double Stream__recv(double s)        { return yon_rt_stream_await_f64(s); }
double Stream__close(double s)       { return (double)yon_rt_stream_close((uint32_t)s); }

/* ============================================================== */
/* Cross-PROCESS streams over POSIX shared memory (mattone A)      */
/* ============================================================== */
/* The in-process streams above live in g_streams (this process only).
 * For two isolated Space processes on the SAME machine (PostgreSQL-style:
 * separate processes, no shared address space, communicating only over an
 * explicit channel) we back the stream's ring buffer with POSIX shared
 * memory, reusing the exact pattern proven for the SHM heap:
 *   shm_open + mmap(MAP_SHARED) for the region, flock(LOCK_EX) around the
 *   head/tail/count updates so concurrent emit/await across processes are
 *   serialized. No absolute pointers: the buffer is an offset inside the
 *   mapped region, valid regardless of where each process maps it.
 *
 * This is the L1->L2 jump the code anticipated ("In L2+ produce attendera'
 * ack del consumer"): same emit/await API, the buffer now crosses the
 * process boundary. Different-CPU transport (sockets, a modern protocol) is
 * the next brick (B); SHM is same-machine. */

#define YON_SHM_STREAM_PREFIX "/yon_stream_"

/* Layout of the shared region: a fixed header followed by the ring buffer.
 * All fields are plain integers/bytes (no pointers) so the region is
 * position-independent across processes. */
typedef struct {
    uint32_t magic;        /* initialization sentinel */
    uint32_t slot_size;    /* bytes per value */
    uint32_t capacity;     /* slots */
    uint32_t head;         /* next position to await */
    uint32_t tail;         /* next position to emit */
    uint32_t count;        /* values present */
    uint32_t closed;       /* 1 = producer closed the stream (clean EOF) */
    uint32_t producers;    /* live producer attach count (fault detection) */
    /* ring buffer bytes follow immediately after this header */
} yon_shm_stream_hdr_t;

#define YON_SHM_STREAM_MAGIC 0x53545245u  /* "STRE" */

typedef struct {
    int   fd;
    void *region;          /* mmap'd: header + buffer */
    size_t region_size;
    char *name;
} yon_shm_stream_t;

/* Open (create or attach) a cross-process stream by name. create=1 makes it
 * if absent and initializes the header. slot_size/capacity are used only on
 * creation; on attach they are read from the existing header. */
yon_shm_stream_t *yon_rt_stream_shm_open(const char *name,
                                         uint32_t slot_size,
                                         uint32_t capacity,
                                         int create) {
    char shm_name[256];
    snprintf(shm_name, sizeof(shm_name), "%s%s", YON_SHM_STREAM_PREFIX, name);
    int flags = O_RDWR;
    if (create) flags |= O_CREAT;
    int fd = shm_open(shm_name, flags, 0600);
    if (fd < 0) { perror("[YON-RT stream-shm] shm_open"); return NULL; }

    size_t region_size = sizeof(yon_shm_stream_hdr_t)
                        + (slot_size == 0u
                              ? (size_t)capacity            /* byte ring: capacity = ring bytes */
                              : (size_t)slot_size * (size_t)capacity);
    struct stat st;
    int is_new = 0;
    if (fstat(fd, &st) == 0 && (size_t)st.st_size < region_size) {
        is_new = 1;
        if (ftruncate(fd, (off_t)region_size) < 0) {
            perror("[YON-RT stream-shm] ftruncate");
            close(fd);
            if (create) shm_unlink(shm_name);
            return NULL;
        }
    }
    void *region = mmap(NULL, region_size, PROT_READ | PROT_WRITE,
                        MAP_SHARED, fd, 0);
    if (region == MAP_FAILED) {
        perror("[YON-RT stream-shm] mmap");
        close(fd);
        return NULL;
    }
    yon_shm_stream_hdr_t *hdr = (yon_shm_stream_hdr_t *)region;
    if (is_new && create) {
        hdr->magic = YON_SHM_STREAM_MAGIC;
        hdr->slot_size = slot_size;
        hdr->capacity = capacity;
        hdr->head = 0; hdr->tail = 0; hdr->count = 0;
        hdr->closed = 0; hdr->producers = 0;
    }
    yon_shm_stream_t *s = (yon_shm_stream_t *)malloc(sizeof(yon_shm_stream_t));
    s->fd = fd;
    s->region = region;
    s->region_size = region_size;
    s->name = strdup(shm_name);
    return s;
}

/* Emit a value across the process boundary. flock serializes the update. */
int yon_rt_stream_shm_emit(yon_shm_stream_t *s, const void *value_ptr) {
    if (!s) return -1;
    yon_shm_stream_hdr_t *hdr = (yon_shm_stream_hdr_t *)s->region;
    uint8_t *buf = (uint8_t *)s->region + sizeof(yon_shm_stream_hdr_t);
    flock(s->fd, LOCK_EX);
    int rc;
    if (hdr->count >= hdr->capacity) {
        rc = -1;  /* full */
    } else {
        memcpy(buf + (size_t)hdr->tail * hdr->slot_size, value_ptr,
               hdr->slot_size);
        hdr->tail = (hdr->tail + 1) % hdr->capacity;
        hdr->count++;
        rc = 0;
    }
    flock(s->fd, LOCK_UN);
    return rc;
}

/* Await (consume) a value from another process. Returns -1 if empty. */
int yon_rt_stream_shm_await(yon_shm_stream_t *s, void *out_ptr) {
    if (!s) return -1;
    yon_shm_stream_hdr_t *hdr = (yon_shm_stream_hdr_t *)s->region;
    uint8_t *buf = (uint8_t *)s->region + sizeof(yon_shm_stream_hdr_t);
    flock(s->fd, LOCK_EX);
    int rc;
    if (hdr->count == 0) {
        rc = -1;  /* empty */
    } else {
        memcpy(out_ptr, buf + (size_t)hdr->head * hdr->slot_size,
               hdr->slot_size);
        hdr->head = (hdr->head + 1) % hdr->capacity;
        hdr->count--;
        rc = 0;
    }
    flock(s->fd, LOCK_UN);
    return rc;
}

/* ---- (3) Back-pressure: blocking variants. produce_blocking waits until there
 * is room (the consumer has drained enough); await_blocking waits until a value
 * is present. We poll with a short sleep + a bounded number of attempts so a
 * dead peer cannot hang forever (timeout -> -1). This realizes the L2 semantics
 * the code anticipated ("In L2+ produce attendera' ack del consumer"): produce
 * no longer drops on full, it back-pressures the producer. ---- */
#define YON_SHM_POLL_USEC   1000      /* 1ms between polls */
#define YON_SHM_MAX_POLLS   60000     /* ~60s bound */

int yon_rt_stream_shm_produce_blocking(yon_shm_stream_t *s, const void *value_ptr) {
    if (!s) return -1;
    for (uint32_t i = 0; i < YON_SHM_MAX_POLLS; i++) {
        int rc = yon_rt_stream_shm_emit(s, value_ptr);
        if (rc == 0) return 0;          /* sent */
        usleep(YON_SHM_POLL_USEC);      /* full: back-pressure, wait for room */
    }
    return -1;                          /* timed out */
}

int yon_rt_stream_shm_await_blocking(yon_shm_stream_t *s, void *out_ptr) {
    if (!s) return -1;
    yon_shm_stream_hdr_t *hdr = (yon_shm_stream_hdr_t *)s->region;
    for (uint32_t i = 0; i < YON_SHM_MAX_POLLS; i++) {
        int rc = yon_rt_stream_shm_await(s, out_ptr);
        if (rc == 0) return 0;          /* got a value */
        /* If the producer has closed and the buffer is drained, this is a clean
         * end-of-stream, not a timeout: report it distinctly so the consumer
         * stops instead of spinning to the timeout. */
        flock(s->fd, LOCK_EX);
        int eof = (hdr->closed && hdr->count == 0);
        flock(s->fd, LOCK_UN);
        if (eof) return -2;             /* EOF: closed + empty */
        usleep(YON_SHM_POLL_USEC);      /* empty but open: wait for a value */
    }
    return -1;                          /* timed out (peer alive but silent) */
}

/* Producer announces it will send no more: a clean shutdown so consumers can
 * distinguish end-of-stream from a stalled/dead peer (fault-tolerance,
 * same-machine). */
int yon_rt_stream_shm_close_write(yon_shm_stream_t *s) {
    if (!s) return -1;
    yon_shm_stream_hdr_t *hdr = (yon_shm_stream_hdr_t *)s->region;
    flock(s->fd, LOCK_EX);
    hdr->closed = 1;
    flock(s->fd, LOCK_UN);
    return 0;
}

uint32_t yon_rt_stream_shm_size(yon_shm_stream_t *s) {
    if (!s) return 0;
    return ((yon_shm_stream_hdr_t *)s->region)->count;
}

void yon_rt_stream_shm_close(yon_shm_stream_t *s) {
    if (!s) return;
    munmap(s->region, s->region_size);
    close(s->fd);
    free(s->name);
    free(s);
}

int yon_rt_stream_shm_unlink(const char *name) {
    char shm_name[256];
    snprintf(shm_name, sizeof(shm_name), "%s%s", YON_SHM_STREAM_PREFIX, name);
    return shm_unlink(shm_name);
}

/* ---- (4) Byte-ring variant for variable-length DTO frames. A DTO channel is
 * opened with slot_size == 0; then `capacity` is the ring size in BYTES and
 * head/tail/count are byte offsets/counts. Frames ([u32 schema_id][u32
 * payload_len][payload]) are written densely, wrapping at the buffer end by
 * splitting the copy in two; the frame's own header carries its length, so the
 * ring is self-delimiting and there is no fixed per-element cap (a frame is
 * bounded only by the ring size). flock + the closed flag give the same
 * back-pressure and EOF discipline as the slot ring. An oversized frame is a
 * loud failure (rc -3), never a silent truncation. ---- */

/* Emit one variable frame. rc 0 sent, -1 full (back-pressure), -3 frame larger
 * than the whole ring (can never fit). */
int yon_rt_stream_shm_emit_frame(yon_shm_stream_t *s,
                                 const void *frame, uint32_t frame_len) {
    if (!s) return -1;
    yon_shm_stream_hdr_t *hdr = (yon_shm_stream_hdr_t *)s->region;
    uint8_t *buf = (uint8_t *)s->region + sizeof(yon_shm_stream_hdr_t);
    uint32_t cap = hdr->capacity;
    if (frame_len > cap) return -3;          /* cannot ever fit: loud */
    flock(s->fd, LOCK_EX);
    int rc;
    if (cap - hdr->count < frame_len) {
        rc = -1;                              /* full: back-pressure */
    } else {
        uint32_t t = hdr->tail;
        uint32_t first = cap - t;             /* bytes until the buffer end */
        if (first >= frame_len) {
            memcpy(buf + t, frame, frame_len);
        } else {                              /* straddle: split in two */
            memcpy(buf + t, frame, first);
            memcpy(buf, (const uint8_t *)frame + first, frame_len - first);
        }
        hdr->tail = (t + frame_len) % cap;
        hdr->count += frame_len;
        rc = 0;
    }
    flock(s->fd, LOCK_UN);
    return rc;
}

/* Await one variable frame into out (out_cap bytes); on success *out_len is the
 * frame length. rc 0 got a frame, -1 empty-but-open (retry), -2 EOF
 * (closed+empty), -3 loud error (frame larger than out_cap, or a closed channel
 * left a partial frame = drift). */
int yon_rt_stream_shm_await_frame(yon_shm_stream_t *s,
                                  void *out, uint32_t out_cap,
                                  uint32_t *out_len) {
    if (!s) return -1;
    yon_shm_stream_hdr_t *hdr = (yon_shm_stream_hdr_t *)s->region;
    uint8_t *buf = (uint8_t *)s->region + sizeof(yon_shm_stream_hdr_t);
    uint32_t cap = hdr->capacity;
    flock(s->fd, LOCK_EX);
    int rc;
    if (hdr->count < 8u) {
        if (hdr->count == 0u) rc = hdr->closed ? -2 : -1;  /* EOF or empty */
        else                  rc = hdr->closed ? -3 : -1;  /* drift or wait */
    } else {
        uint32_t h = hdr->head;
        uint8_t hb[8];
        for (uint32_t i = 0; i < 8u; i++) hb[i] = buf[(h + i) % cap];
        uint32_t payload_len;
        memcpy(&payload_len, hb + 4, 4u);
        uint32_t frame_len = 8u + payload_len;
        if (hdr->count < frame_len) {
            rc = hdr->closed ? -3 : -1;       /* partial: drift if closed, else wait */
        } else if (frame_len > out_cap) {
            rc = -3;                          /* consumer buffer too small: loud */
        } else {
            uint32_t first = cap - h;
            if (first >= frame_len) {
                memcpy(out, buf + h, frame_len);
            } else {
                memcpy(out, buf + h, first);
                memcpy((uint8_t *)out + first, buf, frame_len - first);
            }
            hdr->head = (h + frame_len) % cap;
            hdr->count -= frame_len;
            if (out_len) *out_len = frame_len;
            rc = 0;
        }
    }
    flock(s->fd, LOCK_UN);
    return rc;
}

int yon_rt_stream_shm_produce_frame_blocking(yon_shm_stream_t *s,
                                             const void *frame, uint32_t frame_len) {
    if (!s) return -1;
    for (uint32_t i = 0; i < YON_SHM_MAX_POLLS; i++) {
        int rc = yon_rt_stream_shm_emit_frame(s, frame, frame_len);
        if (rc == 0) return 0;
        if (rc == -3) return -3;              /* frame > ring: loud, do not spin */
        usleep(YON_SHM_POLL_USEC);            /* full: back-pressure, wait for room */
    }
    return -1;
}

int yon_rt_stream_shm_await_frame_blocking(yon_shm_stream_t *s,
                                           void *out, uint32_t out_cap,
                                           uint32_t *out_len) {
    if (!s) return -1;
    for (uint32_t i = 0; i < YON_SHM_MAX_POLLS; i++) {
        int rc = yon_rt_stream_shm_await_frame(s, out, out_cap, out_len);
        if (rc == 0) return 0;
        if (rc == -2 || rc == -3) return rc;  /* EOF or loud error: stop */
        usleep(YON_SHM_POLL_USEC);            /* empty but open: wait for a frame */
    }
    return -1;
}


/* ---- f64-id wrappers, so the frontend (which carries everything as f64) can
 * use cross-process streams the same way it uses intra-process ones. Handles
 * are kept in a small registry indexed by id; the id is carried as f64. The
 * stream NAME is derived from the id, so two processes that agree on the id
 * (e.g. by convention) attach to the same shared region. ---- */
#define YON_MAX_SHM_STREAMS 64
static yon_shm_stream_t *g_shm_stream_handles[YON_MAX_SHM_STREAMS];
/* The f64 handle IS the channel id (nominal, e.g. a dispatch selector,
 * up to 23 bits); the table slot is found by scanning this map. Slot
 * and identity are separate: 64 simultaneous channels per process,
 * any id value. */
static uint32_t g_shm_stream_slot_ids[YON_MAX_SHM_STREAMS];
static int yon_rt_shm_slot_of(uint32_t id) {
    for (int i = 0; i < YON_MAX_SHM_STREAMS; i++)
        if (g_shm_stream_handles[i] && g_shm_stream_slot_ids[i] == id) return i;
    return -1;
}
static uint32_t g_n_shm_streams = 0;

/* Open/attach a cross-process stream identified by an integer id. create=1
 * makes it. Returns the id as f64, or -1.0 on failure. Both processes call
 * with the same id to rendezvous on the same shared region. */
double yon_rt_stream_shm_open_f64(double id_f64, double create_f64) {
    uint32_t id = (uint32_t)id_f64;
    int slot = yon_rt_shm_slot_of(id);
    if (slot < 0) {
        for (int i = 0; i < YON_MAX_SHM_STREAMS; i++)
            if (!g_shm_stream_handles[i]) { slot = i; break; }
    }
    if (slot < 0) return -1.0;  /* 64 simultaneous channels exhausted */
    char name[32];
    snprintf(name, sizeof(name), "id_%u", id);
    yon_shm_stream_t *s =
        yon_rt_stream_shm_open(name, sizeof(double), 256, (int)create_f64);
    if (!s) return -1.0;
    g_shm_stream_handles[slot] = s;
    g_shm_stream_slot_ids[slot] = id;
    if ((uint32_t)slot >= g_n_shm_streams) g_n_shm_streams = (uint32_t)slot + 1;
    return (double)id;
}

/* Sized variant: create/attach a channel whose slots are slot_size bytes wide,
 * for place-DTO frames. slot_size == 0 selects the byte ring (a dense
 * variable-frame channel of YON_WIRE_RING_BYTES bytes); the scalar f64 channel
 * is the slot_size == 8 case. On attach the existing header's geometry wins. */
#define YON_WIRE_RING_BYTES 65536u   /* 64KB dense byte ring for DTO frames */

double yon_rt_stream_shm_open_sized_f64(double id_f64, double create_f64,
                                        double slot_size_f64) {
    uint32_t id = (uint32_t)id_f64;
    uint32_t ss = (uint32_t)slot_size_f64;
    if (ss > 256u) return -1.0;
    int slot = yon_rt_shm_slot_of(id);
    if (slot < 0) {
        for (int i = 0; i < YON_MAX_SHM_STREAMS; i++)
            if (!g_shm_stream_handles[i]) { slot = i; break; }
    }
    if (slot < 0) return -1.0;
    char name[32];
    snprintf(name, sizeof(name), "id_%u", id);
    yon_shm_stream_t *s =
        (ss == 0u)
          ? yon_rt_stream_shm_open(name, 0u, YON_WIRE_RING_BYTES, (int)create_f64)
          : yon_rt_stream_shm_open(name, ss, 256, (int)create_f64);
    if (!s) return -1.0;
    g_shm_stream_handles[slot] = s;
    g_shm_stream_slot_ids[slot] = id;
    if ((uint32_t)slot >= g_n_shm_streams) g_n_shm_streams = (uint32_t)slot + 1;
    return (double)id;
}

double Stream__make_shm_sized(double id, double create, double slot_size) {
    return yon_rt_stream_shm_open_sized_f64(id, create, slot_size);
}

double yon_rt_stream_shm_send_f64(double id_f64, double value) {
    uint32_t id = (uint32_t)id_f64;
    int slot = yon_rt_shm_slot_of(id);
    if (slot < 0) return -1.0;
    return (double)yon_rt_stream_shm_emit(g_shm_stream_handles[slot], &value);
}

double yon_rt_stream_shm_recv_f64(double id_f64) {
    uint32_t id = (uint32_t)id_f64;
    int slot = yon_rt_shm_slot_of(id);
    if (slot < 0) return -1.0;
    double out = 0.0;
    if (yon_rt_stream_shm_await(g_shm_stream_handles[slot], &out) != 0) return -1.0;
    return out;
}

/* Frontend-facing aliases (mirroring Stream__make/send/recv). */
double Stream__make_shm(double id, double create) { return yon_rt_stream_shm_open_f64(id, create); }double Stream__send_shm(double id, double v)       { return yon_rt_stream_shm_send_f64(id, v); }
double Stream__recv_shm(double id)                 { return yon_rt_stream_shm_recv_f64(id); }

/* Blocking (back-pressure) f64 wrappers + aliases. produce waits for room,
 * await waits for a value, both with a bounded timeout (-1 on timeout). */
double yon_rt_stream_shm_produce_f64(double id_f64, double value) {
    uint32_t id = (uint32_t)id_f64;
    int slot = yon_rt_shm_slot_of(id);
    if (slot < 0) return -1.0;
    return (double)yon_rt_stream_shm_produce_blocking(g_shm_stream_handles[slot], &value);
}
double yon_rt_stream_shm_await_blocking_f64(double id_f64) {
    uint32_t id = (uint32_t)id_f64;
    int slot = yon_rt_shm_slot_of(id);
    if (slot < 0) return -1.0;
    double out = 0.0;
    int rc = yon_rt_stream_shm_await_blocking(g_shm_stream_handles[slot], &out);
    if (rc == -2) return (double)0xFFFFFFFFu;  /* drained AND closed: the
                                                  unified EOF sentinel */
    if (rc != 0) return -1.0;
    return out;
}
double Stream__produce_shm(double id, double v) { return yon_rt_stream_shm_produce_f64(id, v); }
double Stream__await_shm(double id)             { return yon_rt_stream_shm_await_blocking_f64(id); }

/* Close the write side: id-based wrapper + alias. Consumers' await then returns
 * the EOF sentinel (-2 at C level) once the buffer drains, instead of timing
 * out — clean shutdown vs dead peer. */
double yon_rt_stream_shm_close_write_f64(double id_f64) {
    uint32_t id = (uint32_t)id_f64;
    int slot = yon_rt_shm_slot_of(id);
    if (slot < 0) return -1.0;
    return (double)yon_rt_stream_shm_close_write(g_shm_stream_handles[slot]);
}
double Stream__close_shm(double id) { return yon_rt_stream_shm_close_write_f64(id); }

/* Subscription .stream: drain a completed shm channel into a local
 * stream, structurally closed; the stream methods then work unchanged.
 * One copy of the values, by design (v1). */
double Wire__subscription_stream(double chan_id) {
    char nm[64];
    snprintf(nm, sizeof(nm), "__sub_stream_%u", (unsigned)chan_id);
    double local = (double)yon_rt_stream_create(nm, 0, 8);
    if (local < 0.0) return -1.0;
    for (;;) {
        double v = yon_rt_stream_shm_await_blocking_f64(chan_id);
        if (v == (double)0xFFFFFFFFu || v == -1.0) break;
        yon_rt_stream_emit_f64(local, v);
    }
    yon_rt_stream_close((uint32_t)local);
    return local;
}

/* Subscription .stream for a place DTO: drain a completed shm channel whose
 * slots are n_bytes-wide place payloads, rebuild each in THIS process's heap
 * (yon_rt_new), and emit the local handle into a structurally closed local
 * stream. The wormhole's inbound half: content crosses, the object is born
 * anew here, the producer's handle never leaves its process. EOF is the
 * channel's structural close (await rc == -2), not a value sentinel. */
double Wire__subscription_stream_dto(double chan_id, double n_bytes_d) {
    uint32_t n = (uint32_t)n_bytes_d;
    if (n == 0) return -1.0;             /* n>0 only signals "place DTO channel" */
    char nm[64];
    snprintf(nm, sizeof(nm), "__sub_stream_%u", (unsigned)chan_id);
    double local = (double)yon_rt_stream_create(nm, 0, 8);
    if (local < 0.0) return -1.0;
    int ch = yon_rt_shm_slot_of((uint32_t)chan_id);
    if (ch < 0) { yon_rt_stream_close((uint32_t)local); return -1.0; }
    unsigned char *buf = (unsigned char *)malloc(YON_WIRE_RING_BYTES);
    if (!buf) { yon_rt_stream_close((uint32_t)local); return -1.0; }
    for (;;) {
        uint32_t flen = 0;
        int rc = yon_rt_stream_shm_await_frame_blocking(
                     g_shm_stream_handles[ch], buf, YON_WIRE_RING_BYTES, &flen);
        if (rc != 0) break;  /* -2 EOF, -3 loud error, -1 timeout: stop draining */
        yon_section_t sec = yon_rt_deserialize(buf, flen, YON_HEAP_ID_DEFAULT);
        if (sec == YON_SECTION_INVALID) break;
        yon_rt_stream_emit_f64(local, (double)(int64_t)(uint64_t)sec);
    }
    free(buf);
    yon_rt_stream_close((uint32_t)local);
    return local;
}
/* (the serve loop, spawn and registry live in the v2 section)     */
/* ============================================================== */
/* The generated binary provides __yon_dispatch(selector, a1..a4) -> result, a
 * switch over the package's public (non-internal) number functions (arity 0-4;
 * extra slots are ignored by lower-arity branches). The runtime owns the loop
 * and the process plumbing. */
extern double __yon_dispatch(double selector, double a1, double a2, double a3,
                             double a4);

/* argv is stashed at startup so the generated main can ask "am I a server?"
 * without threading argc/argv through the MLIR. */
static int    g_argc = 0;
static char **g_argv = NULL;
void yon_rt_set_args(int argc, char **argv) { g_argc = argc; g_argv = argv; }

/* Both glibc and macOS pass (argc, argv, envp) to ELF/Mach-O constructors:
 * capture them here so Args.count/get (and the /proc-less serve detection
 * fallback) work even though the generated MLIR main is () -> i32 and never
 * sees argc/argv. An explicit yon_rt_set_args later simply rewrites the
 * same data. */
__attribute__((constructor))
static void yon_rt_capture_args(int argc, char **argv, char **envp) {
    (void)envp;
    if (g_argc == 0 && argv) {
        g_argc = argc;
        g_argv = argv;
    }
}

/* Process plumbing shared with the v2 section. */
#include <signal.h>
#include <sys/wait.h>

/* Single entry the generated main calls FIRST. If this process was launched
 * as a server (`--serve2 <SpaceName>`), run the v2 dispatch loop and exit —
 * never returning to the user main. Otherwise return immediately and let
 * main run normally. This keeps the generated MLIR to one call, with no
 * branching emitted by hand. */
int    yon_rt_should_serve2(char *out, size_t outsz);   /* fwd (v2, below) */
double yon_rt_rpc2_serve_loop(const char *space_name);  /* fwd (v2, below) */
void yon_rt_maybe_serve(void) {
    char nm[64];
    if (yon_rt_should_serve2(nm, sizeof(nm))) {
        yon_rt_rpc2_serve_loop(nm);
        exit(0);
    }
}




/* ============================================================== */
/* Idraulica v2 — actor-model RPC: named request mailbox +         */
/* private reply channels + PROCESS_SHARED mutex/cond wakeup       */
/* ============================================================== */
/* Locked decisions (docs/cross_package_design.md, 2026-06-03):
 *   1. Channel identity is the NOMINAL Space name: /yon_stream_<Space>.
 *      Zero collisions by construction; truncation+hash fallback only past
 *      the NAME_MAX budget.
 *   2. Server mux: ONE shared request queue per Space (multi-producer) +
 *      a PRIVATE reply channel per caller session (Erlang-mailbox style).
 *      The server stays single-threaded and sequential: no locks in the
 *      Space heap, deterministic transitions, serial arrow application.
 *      Head-of-line blocking is an accepted property of the model.
 *   3. Wakeup primitive: pthread_mutex_t + pthread_cond_t with
 *      PTHREAD_PROCESS_SHARED (portable Linux + macOS M1; sem_init
 *      pshared=1 is ENOSYS on macOS). Waits are TIMED slices with a
 *      liveness check, never unbounded — a dead peer cannot hang us, and
 *      we need no robust-mutex support (absent on macOS).
 *      The v1 `turn` token does not exist in this layer.
 *
 * Correlation: the request carries (session nonce, per-call seq). The
 * session nonce is 64-bit random (guards against PID recycling); the seq
 * disambiguates a late reply of a TIMED-OUT earlier call from the reply of
 * the current one (same session, same channel). A reply is accepted only
 * if both echo back.
 *
 * Timed waits use CLOCK_REALTIME absolute deadlines: portable to macOS,
 * where pthread_condattr_setclock(CLOCK_MONOTONIC) is unavailable. The
 * (accepted) caveat is sensitivity to wall-clock jumps; waits are short
 * slices, so the worst case is one early/late slice, re-checked. */

#include <pthread.h>
#include <time.h>
#include <errno.h>

#define YON_RPC2_REQ_PREFIX  "/yon_stream_"   /* decision 1: nominal name */
#define YON_RPC2_REP_PREFIX  "/yon_reply_"
#define YON_RPC2_QUEUE_CAP   16u
#define YON_RPC2_MAGIC       0x52504332u      /* "RPC2" */
#define YON_RPC2_REP_MAGIC   0x52455032u      /* "REP2" */
#define YON_RPC2_VERSION     2u
#define YON_RPC2_SLICE_MS    100u             /* one timed-wait slice */
#define YON_RPC2_ENQ_TIMEOUT_MS 2000u         /* full-queue back-pressure cap */

/* Request slot (yon_rpc2_req_t): declared in yon_rt.h — fixed size, no
 * pointers, position-independent in SHM. */

/* Shared request mailbox: header + ring of request slots. */
typedef struct {
    uint32_t magic;            /* published LAST by the creator */
    uint32_t version;
    uint32_t epoch;            /* diagnostics; freshness = unlink+recreate */
    pid_t    server_pid;       /* liveness validation (kill(pid,0)/ESRCH) */
    pthread_mutex_t mu;        /* PROCESS_SHARED */
    pthread_cond_t  nonempty;  /* server waits here */
    pthread_cond_t  nonfull;   /* producers wait here (back-pressure) */
    uint32_t head, tail, count;
    uint32_t capacity;
    uint32_t closed;
    yon_rpc2_req_t slots[YON_RPC2_QUEUE_CAP];
} yon_rpc2_queue_t;

/* Private reply channel: single slot, owned by the caller session. */
typedef struct {
    uint32_t magic;
    uint32_t has_value;
    pthread_mutex_t mu;
    pthread_cond_t  filled;
    double   value;
    uint64_t nonce_echo;
    uint64_t seq_echo;
} yon_rpc2_reply_t;

/* decision 1 fallback: nominal name, truncation+fnv1a only past NAME_MAX. */
static void yon_rpc2_shm_name(char *out, size_t outsz,
                              const char *prefix, const char *name) {
    if (strlen(prefix) + strlen(name) < 200) {
        snprintf(out, outsz, "%s%s", prefix, name);
        return;
    }
    uint32_t h = 2166136261u;
    for (const char *p = name; *p; p++) {
        h ^= (uint32_t)(unsigned char)*p;
        h *= 16777619u;
    }
    snprintf(out, outsz, "%s%.*s_%08x", prefix, 160, name, h);
}

static void yon_rpc2_deadline(struct timespec *ts, uint32_t ms) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec  += (time_t)(ms / 1000u);
    ts->tv_nsec += (long)(ms % 1000u) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) { ts->tv_sec++; ts->tv_nsec -= 1000000000L; }
}

static int yon_rpc2_past(const struct timespec *dl) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return now.tv_sec > dl->tv_sec ||
           (now.tv_sec == dl->tv_sec && now.tv_nsec >= dl->tv_nsec);
}

/* Liveness. Subtlety: a spawned server killed before we reap it is a
 * ZOMBIE of ours, and kill(zombie, 0) still returns 0 — kill-based liveness
 * is blind to zombies. So for our own children we ask waitpid(WNOHANG)
 * first: 0 = running; ==pid = it was a zombie (reaped here, dead);
 * ECHILD = not our child, fall back to kill(pid,0)/ESRCH. */
static int yon_rpc2_pid_alive(pid_t p) {
    if (p <= 0) return 1;  /* unknown yet: give the benefit of the doubt */
    int st;
    pid_t w = waitpid(p, &st, WNOHANG);
    if (w == p) return 0;              /* our zombie: reaped now — dead */
    if (w == 0) return 1;              /* our child, still running */
    return kill(p, 0) == 0 || errno != ESRCH;
}

/* Bounded mutex acquisition: trylock + 1ms sleeps until the deadline.
 * Rationale (decision 3): a peer can die WHILE HOLDING a PROCESS_SHARED
 * mutex; robust mutexes are absent on macOS, so an unbounded
 * pthread_mutex_lock could hang forever. Every lock in this layer is
 * bounded; a timeout is treated as a dead/corrupt channel, never spun on.
 * 0 = locked, -1 = timeout. */
static int yon_rpc2_lock_timed(pthread_mutex_t *mu, uint32_t timeout_ms) {
    struct timespec dl;
    yon_rpc2_deadline(&dl, timeout_ms);
    for (;;) {
        int rc = pthread_mutex_trylock(mu);
        if (rc == 0) return 0;
        if (rc != EBUSY) return -1;          /* invalid/corrupt mutex */
        if (yon_rpc2_past(&dl)) return -1;
        usleep(1000);
    }
}
#define YON_RPC2_LOCK_MS 2000u               /* lock-acquisition budget */

static int yon_rpc2_sync_init(pthread_mutex_t *mu,
                              pthread_cond_t *c1, pthread_cond_t *c2) {
    pthread_mutexattr_t ma;
    pthread_condattr_t  ca;
    if (pthread_mutexattr_init(&ma) != 0) return -1;
    pthread_mutexattr_setpshared(&ma, PTHREAD_PROCESS_SHARED);
    int rc = pthread_mutex_init(mu, &ma);
    pthread_mutexattr_destroy(&ma);
    if (rc != 0) return -1;
    if (pthread_condattr_init(&ca) != 0) return -1;
    pthread_condattr_setpshared(&ca, PTHREAD_PROCESS_SHARED);
    if (c1) rc |= pthread_cond_init(c1, &ca);
    if (c2) rc |= pthread_cond_init(c2, &ca);
    pthread_condattr_destroy(&ca);
    return rc == 0 ? 0 : -1;
}

/* Map an shm region of `size` bytes by name. O_CREAT|O_EXCL decides ONE
 * initializer even when several processes race to create; the losers attach
 * and wait for the published magic. *out_created reports the winner. */
static void *yon_rpc2_map(const char *shm_name, size_t size, int *out_created) {
    int created = 1;
    int fd = shm_open(shm_name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) {
        if (errno != EEXIST) return NULL;
        created = 0;
        fd = shm_open(shm_name, O_RDWR, 0600);
        if (fd < 0) return NULL;
        struct stat st;
        for (int i = 0; i < 5000; i++) {           /* creator may still size it */
            if (fstat(fd, &st) == 0 && (size_t)st.st_size >= size) break;
            usleep(1000);
        }
        if (fstat(fd, &st) != 0 || (size_t)st.st_size < size) {
            close(fd);
            return NULL;
        }
    } else if (ftruncate(fd, (off_t)size) < 0) {
        close(fd);
        shm_unlink(shm_name);
        return NULL;
    }
    void *r = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);  /* the mapping persists */
    if (r == MAP_FAILED) return NULL;
    if (out_created) *out_created = created;
    return r;
}

/* Map (create or attach) the mailbox of a Space. The creator initializes
 * with the given epoch and publishes the magic LAST; attachers wait for it.
 * out_created reports who won the O_EXCL creation race. */
static yon_rpc2_queue_t *yon_rpc2_queue_map_init(const char *space_name,
                                                 uint32_t epoch_hint,
                                                 int *out_created) {
    char nm[256];
    yon_rpc2_shm_name(nm, sizeof(nm), YON_RPC2_REQ_PREFIX, space_name);
    int created = 0;
    yon_rpc2_queue_t *q =
        (yon_rpc2_queue_t *)yon_rpc2_map(nm, sizeof(yon_rpc2_queue_t), &created);
    if (!q) return NULL;
    if (created) {
        /* region is zero-filled by ftruncate; init sync, publish magic LAST */
        q->version  = YON_RPC2_VERSION;
        q->epoch    = epoch_hint;
        q->capacity = YON_RPC2_QUEUE_CAP;
        if (yon_rpc2_sync_init(&q->mu, &q->nonempty, &q->nonfull) != 0) {
            munmap(q, sizeof(*q));
            shm_unlink(nm);
            return NULL;
        }
        __atomic_store_n(&q->magic, YON_RPC2_MAGIC, __ATOMIC_SEQ_CST);
    } else {
        int ok = 0;
        for (int i = 0; i < 5000; i++) {
            if (__atomic_load_n(&q->magic, __ATOMIC_SEQ_CST) == YON_RPC2_MAGIC) {
                ok = 1;
                break;
            }
            usleep(1000);
        }
        if (!ok) { munmap(q, sizeof(*q)); return NULL; }
    }
    if (out_created) *out_created = created;
    return q;
}

/* Open (create or attach) the request mailbox of a Space by NAME.
 * as_server=1 also claims server_pid for liveness validation. */
void *yon_rt_rpc2_queue_open(const char *space_name, int as_server) {
    yon_rpc2_queue_t *q = yon_rpc2_queue_map_init(space_name, 0, NULL);
    if (!q) return NULL;
    if (as_server) {
        if (yon_rpc2_lock_timed(&q->mu, YON_RPC2_LOCK_MS) != 0) {
            /* a predecessor died HOLDING the mutex: NEVER re-init in place
             * (decision 3). Surrender the object: unlink the name and
             * recreate virgin, epoch advanced. Stragglers' mappings of the
             * orphaned object stay valid; they recover by name. */
            char nm[256];
            yon_rpc2_shm_name(nm, sizeof(nm), YON_RPC2_REQ_PREFIX, space_name);
            uint32_t e_old = q->epoch;
            munmap(q, sizeof(*q));
            shm_unlink(nm);
            q = yon_rpc2_queue_map_init(space_name, e_old + 1, NULL);
            if (!q) return NULL;
            if (yon_rpc2_lock_timed(&q->mu, YON_RPC2_LOCK_MS) != 0) {
                munmap(q, sizeof(*q));
                return NULL;
            }
        }
        q->server_pid = getpid();
        pthread_mutex_unlock(&q->mu);
    }
    return q;
}

/* Diagnostic: current epoch of a mapped mailbox. */
uint32_t yon_rt_rpc2_queue_epoch(void *qh) {
    return qh ? ((yon_rpc2_queue_t *)qh)->epoch : 0u;
}

void yon_rt_rpc2_queue_close(void *qh) {
    if (qh) munmap(qh, sizeof(yon_rpc2_queue_t));
}

int yon_rt_rpc2_queue_unlink(const char *space_name) {
    char nm[256];
    yon_rpc2_shm_name(nm, sizeof(nm), YON_RPC2_REQ_PREFIX, space_name);
    return shm_unlink(nm);
}

/* Producer side: enqueue one request, back-pressuring on a full queue with
 * timed slices + liveness check. 0 on success, -1 on timeout/dead server. */
static int yon_rpc2_enqueue(yon_rpc2_queue_t *q, const yon_rpc2_req_t *req,
                            uint32_t timeout_ms) {
    if (!q) return -1;
    struct timespec dl;
    yon_rpc2_deadline(&dl, timeout_ms);
    if (yon_rpc2_lock_timed(&q->mu, timeout_ms) != 0) return -1;
    while (q->count >= q->capacity) {
        struct timespec slice;
        yon_rpc2_deadline(&slice, YON_RPC2_SLICE_MS);
        pthread_cond_timedwait(&q->nonfull, &q->mu, &slice);
        if (q->count < q->capacity) break;
        if (yon_rpc2_past(&dl) ||
            (q->server_pid != 0 && !yon_rpc2_pid_alive(q->server_pid))) {
            pthread_mutex_unlock(&q->mu);
            return -1;
        }
    }
    q->slots[q->tail] = *req;
    q->tail = (q->tail + 1) % q->capacity;
    q->count++;
    pthread_cond_signal(&q->nonempty);
    pthread_mutex_unlock(&q->mu);
    return 0;
}

/* Server side: block (timed slices) for one request. Returns argc >= 0, or
 * -1 on idle timeout (the existing idle-death policy of the serve loop). */
int yon_rt_rpc2_take(void *qh, yon_rpc2_req_t *out, uint32_t idle_ms) {
    yon_rpc2_queue_t *q = (yon_rpc2_queue_t *)qh;
    if (!q || !out) return -1;
    struct timespec dl;
    yon_rpc2_deadline(&dl, idle_ms);
    if (yon_rpc2_lock_timed(&q->mu, YON_RPC2_LOCK_MS) != 0) return -1;
    while (q->count == 0) {
        struct timespec slice;
        yon_rpc2_deadline(&slice, YON_RPC2_SLICE_MS);
        pthread_cond_timedwait(&q->nonempty, &q->mu, &slice);
        if (q->count > 0) break;
        if (yon_rpc2_past(&dl)) {
            pthread_mutex_unlock(&q->mu);
            return -1;
        }
    }
    *out = q->slots[q->head];
    q->head = (q->head + 1) % q->capacity;
    q->count--;
    pthread_cond_signal(&q->nonfull);
    pthread_mutex_unlock(&q->mu);
    return (int)out->argc;
}

/* Server side: write the result into the caller's PRIVATE reply channel,
 * named in the request itself. A missing channel means the caller is gone:
 * the request is dropped (-1), the server moves on. */
int yon_rt_rpc2_reply(const yon_rpc2_req_t *req, double result) {
    if (!req || !req->reply_name[0]) return -1;
    int fd = shm_open(req->reply_name, O_RDWR, 0600);
    if (fd < 0) return -1;
    yon_rpc2_reply_t *rep = (yon_rpc2_reply_t *)
        mmap(NULL, sizeof(yon_rpc2_reply_t), PROT_READ | PROT_WRITE,
             MAP_SHARED, fd, 0);
    close(fd);
    if (rep == MAP_FAILED) return -1;
    if (__atomic_load_n(&rep->magic, __ATOMIC_SEQ_CST) != YON_RPC2_REP_MAGIC) {
        munmap(rep, sizeof(*rep));
        return -1;
    }
    if (yon_rpc2_lock_timed(&rep->mu, YON_RPC2_LOCK_MS) != 0) {
        munmap(rep, sizeof(*rep));
        return -1;                            /* caller-side corrupt: drop */
    }
    rep->value      = result;
    rep->nonce_echo = req->nonce;
    rep->seq_echo   = req->seq;
    rep->has_value  = 1;
    pthread_cond_signal(&rep->filled);
    pthread_mutex_unlock(&rep->mu);
    munmap(rep, sizeof(*rep));
    return 0;
}

/* ---- caller session: one nonce + one private reply channel per Space ---- */

static uint64_t yon_rpc2_random64(void) {
    uint64_t n = 0;
    FILE *f = fopen("/dev/urandom", "rb");
    if (f) {
        size_t got = fread(&n, 1, sizeof(n), f);
        fclose(f);
        if (got == sizeof(n) && n != 0) return n;
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    n = ((uint64_t)ts.tv_sec * 1000000007ull) ^
        ((uint64_t)ts.tv_nsec << 17) ^
        ((uint64_t)getpid() * 2654435761ull);
    return n ? n : 1u;
}

typedef struct {
    char              space[64];
    pid_t             owner;        /* fork-safety: sessions do NOT survive fork */
    uint64_t          nonce;
    uint64_t          seq;          /* per-call, monotonic in the session */
    char              reply_name[128];
    yon_rpc2_reply_t *rep;
    yon_rpc2_queue_t *q;
} yon_rpc2_session_t;

#define YON_RPC2_MAX_SESSIONS 16
static yon_rpc2_session_t g_rpc2_sessions[YON_RPC2_MAX_SESSIONS];
static uint32_t g_rpc2_n_sessions = 0;

/* (Re)arm a session's identity: fresh nonce, fresh PRIVATE reply channel.
 * Used on first contact and after a fork (the child inherits the parent's
 * session table and reply mapping — sharing them would cross the replies of
 * two processes on one channel, so the child must mint its own). */
static void yon_rpc2_unlink_own_replies(void) {
    for (uint32_t i = 0; i < g_rpc2_n_sessions; i++) {
        yon_rpc2_session_t *s = &g_rpc2_sessions[i];
        if (s->owner != getpid()) continue;
        if (s->reply_name[0])
            shm_unlink(s->reply_name);   /* our PRIVATE channel: remove it */
        /* A mailbox WE created for a Space no server ever claimed
         * (server_pid still 0) is garbage: remove the name too. A claimed
         * mailbox belongs to its server, which unlinks it on shutdown. */
        if (s->q && s->q->server_pid == 0)
            yon_rt_rpc2_queue_unlink(s->space);
    }
}
static int g_rpc2_cleanup_registered = 0;

static int yon_rpc2_session_arm(yon_rpc2_session_t *s, const char *space) {
    s->owner = getpid();
    s->seq   = 0;
    s->nonce = yon_rpc2_random64();
    /* macOS caps shm names at 31 characters (PSHMNAMLEN, slash included):
     * short prefix + 10 chars of Space + 12 hex of nonce = max 27.
     * The name is only a unique rendezvous: CORRELATION uses the FULL
     * 64-bit nonce inside the payload (nonce_echo). */
    snprintf(s->reply_name, sizeof(s->reply_name), "/yr_%.10s_%012llx",
             space, (unsigned long long)(s->nonce & 0xFFFFFFFFFFFFull));
    int created = 0;
    s->rep = (yon_rpc2_reply_t *)
        yon_rpc2_map(s->reply_name, sizeof(yon_rpc2_reply_t), &created);
    if (!s->rep) return -1;
    if (created) {
        if (yon_rpc2_sync_init(&s->rep->mu, &s->rep->filled, NULL) != 0) {
            munmap(s->rep, sizeof(*s->rep));
            shm_unlink(s->reply_name);
            s->rep = NULL;
            return -1;
        }
        __atomic_store_n(&s->rep->magic, YON_RPC2_REP_MAGIC, __ATOMIC_SEQ_CST);
    }
    if (!g_rpc2_cleanup_registered) {
        atexit(yon_rpc2_unlink_own_replies);
        g_rpc2_cleanup_registered = 1;
    }
    return 0;
}

static yon_rpc2_session_t *yon_rpc2_session(const char *space) {
    for (uint32_t i = 0; i < g_rpc2_n_sessions; i++)
        if (strcmp(g_rpc2_sessions[i].space, space) == 0) {
            yon_rpc2_session_t *s = &g_rpc2_sessions[i];
            if (s->owner != getpid()) {
                /* we are a fork child: drop OUR VIEW of the parent's reply
                 * channel (the parent's mapping is untouched) and mint a
                 * fresh identity. The mailbox mapping stays: it is the
                 * shared multi-producer queue, valid across fork. */
                if (s->rep) munmap(s->rep, sizeof(*s->rep));
                s->rep = NULL;
                if (yon_rpc2_session_arm(s, space) != 0) return NULL;
            }
            return s;
        }
    if (g_rpc2_n_sessions >= YON_RPC2_MAX_SESSIONS) return NULL;
    yon_rpc2_session_t *s = &g_rpc2_sessions[g_rpc2_n_sessions];
    memset(s, 0, sizeof(*s));
    snprintf(s->space, sizeof(s->space), "%.63s", space);
    if (yon_rpc2_session_arm(s, space) != 0) return NULL;
    /* attach the mailbox (create if first: the later-spawned server attaches
     * to the same region — same convention as v1). */
    s->q = (yon_rpc2_queue_t *)yon_rt_rpc2_queue_open(space, 0);
    if (!s->q) {
        munmap(s->rep, sizeof(*s->rep));
        shm_unlink(s->reply_name);
        s->rep = NULL;
        return NULL;
    }
    g_rpc2_n_sessions++;
    return s;
}

/* ─── spawn { } collection primitive (step 4a) ──────────────────────────
 * See the header for the contract. Reuses the v2 PROCESS_SHARED queue
 * (yon_rpc2_queue_t) as the N-producers -> 1-consumer collection channel:
 * the parent is the consumer, the forked children are the producers. The
 * deadlock between the bounded (16-slot) queue and the join is avoided by
 * interleaving take() with a non-blocking WNOHANG reap in the parent, so the
 * parent is always draining and producers never block forever.
 *
 * Limit: a promoted value is one f64 (args[0]); rich types (strings, nested
 * places) will route through the DTO serialize path in a later step and are
 * not handled here. */
typedef struct {
    int    role;          /* 0 = parent, 1 = child */
    int    index;         /* child index 0..n-1 (child only) */
    int    n;             /* replica count */
    void  *q;             /* yon_rpc2_queue_t* shared collection channel */
    char   name[96];      /* unique channel name */
    pid_t  pids[256];     /* parent only */
    int    n_spawned;     /* parent only */
} yon_spawn_ctx_t;

static unsigned g_yon_spawn_counter = 0u;

void *yon_rt_spawn_open(double n_replicas_f64) {
    int n = (int)n_replicas_f64;
    if (n <= 0) n = 1;
    if (n > 256) {
        fprintf(stderr, "[YON-RT spawn] n=%d exceeds max 256, clamping\n", n);
        n = 256;
    }
    yon_spawn_ctx_t *ctx = (yon_spawn_ctx_t *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->n = n;
    snprintf(ctx->name, sizeof(ctx->name), "spawncollect_%d_%u",
             (int)getpid(), g_yon_spawn_counter++);
    /* Parent is the consumer: create and claim the queue BEFORE forking so the
     * children inherit the same PROCESS_SHARED mapping. */
    int created = 0;
    yon_rpc2_queue_t *q = yon_rpc2_queue_map_init(ctx->name, 0u, &created);
    if (!q) { free(ctx); return NULL; }
    q->server_pid = (uint64_t)getpid();   /* children check parent liveness */
    ctx->q = q;
    for (int i = 0; i < n; i++) {
        char idx[16];
        snprintf(idx, sizeof(idx), "%d", i);
        setenv("YON_SPAWN_INDEX", idx, 1);   /* keep yon_rt_spawn_index() working */
        pid_t pid = fork();
        if (pid < 0) { perror("[YON-RT spawn] fork failed"); break; }
        if (pid == 0) {
            ctx->role = 1;   /* this is a post-fork private copy */
            ctx->index = i;
            return ctx;
        }
        ctx->pids[ctx->n_spawned++] = pid;
    }
    unsetenv("YON_SPAWN_INDEX");
    ctx->role = 0;
    return ctx;
}

double yon_rt_spawn_role(void *h) {
    yon_spawn_ctx_t *c = (yon_spawn_ctx_t *)h;
    return c ? (double)c->role : 0.0;
}

double yon_rt_spawn_index_of(void *h) {
    yon_spawn_ctx_t *c = (yon_spawn_ctx_t *)h;
    return c ? (double)c->index : -1.0;
}

void yon_rt_spawn_promote(void *h, double value) {
    yon_spawn_ctx_t *c = (yon_spawn_ctx_t *)h;
    if (!c || !c->q) return;
    yon_rpc2_req_t r;
    memset(&r, 0, sizeof(r));
    r.argc = 1u;
    r.args[0] = value;
    /* Generous timeout: the parent drains continuously, so back-pressure on
     * the 16-slot queue clears quickly. -1 (value dropped, loud) only if the
     * parent has died. */
    if (yon_rpc2_enqueue((yon_rpc2_queue_t *)c->q, &r, 10000u) != 0)
        fprintf(stderr, "[YON-RT spawn] promote dropped (parent gone?)\n");
}

void yon_rt_spawn_child_exit(void *h) {
    (void)h;
    _exit(0);   /* do NOT run the parent's continuation */
}

int yon_rt_spawn_join_collect(void *h, double *out, int cap) {
    yon_spawn_ctx_t *c = (yon_spawn_ctx_t *)h;
    if (!c || c->role != 0) return 0;
    int got = 0, reaped = 0;
    for (;;) {
        yon_rpc2_req_t r;
        int rc = yon_rt_rpc2_take(c->q, &r, 50u);   /* short idle slice */
        if (rc >= 0) {
            if (got < cap) out[got] = r.args[0];
            got++;
            continue;   /* keep draining while values are flowing */
        }
        /* Queue idle: reap any children that have exited (non-blocking). */
        for (int i = 0; i < c->n_spawned; i++) {
            if (c->pids[i] > 0) {
                int st = 0;
                if (waitpid(c->pids[i], &st, WNOHANG) == c->pids[i]) {
                    c->pids[i] = -1;
                    reaped++;
                }
            }
        }
        if (reaped >= c->n_spawned) {
            /* All children have exited: every value they will ever push is
             * already enqueued. Drain whatever remains, then stop. */
            int rc2 = yon_rt_rpc2_take(c->q, &r, 0u);
            if (rc2 >= 0) { if (got < cap) out[got] = r.args[0]; got++; continue; }
            break;
        }
    }
    return got;
}

void yon_rt_spawn_close(void *h) {
    yon_spawn_ctx_t *c = (yon_spawn_ctx_t *)h;
    if (!c) return;
    if (c->role == 0 && c->q) {
        yon_rt_rpc2_queue_close(c->q);
        yon_rt_rpc2_queue_unlink(c->name);
    }
    free(c);
}

/* Parent bridge: drain+reap (same interleave as join_collect) but emit each
 * collected value directly into a fresh stream, then close it; returns the
 * stream id as f64. This is what the spawn expression evaluates to. Draining
 * straight into the stream avoids an intermediate buffer of unknown size. */
double yon_rt_spawn_join_stream(void *h) {
    yon_spawn_ctx_t *c = (yon_spawn_ctx_t *)h;
    if (!c || c->role != 0) return -1.0;
    double sid_f = yon_rt_stream_make_f64(0.0);   /* default heap */
    uint32_t sid = (uint32_t)sid_f;
    int reaped = 0;
    for (;;) {
        yon_rpc2_req_t r;
        int rc = yon_rt_rpc2_take(c->q, &r, 50u);
        if (rc >= 0) { double v = r.args[0]; yon_rt_stream_emit(sid, &v); continue; }
        for (int i = 0; i < c->n_spawned; i++) {
            if (c->pids[i] > 0) {
                int st = 0;
                if (waitpid(c->pids[i], &st, WNOHANG) == c->pids[i]) {
                    c->pids[i] = -1;
                    reaped++;
                }
            }
        }
        if (reaped >= c->n_spawned) {
            int rc2 = yon_rt_rpc2_take(c->q, &r, 0u);
            if (rc2 >= 0) { double v = r.args[0]; yon_rt_stream_emit(sid, &v); continue; }
            break;
        }
    }
    yon_rt_stream_close(sid);
    return sid_f;
}

/* ─── f64 id-based facade for the Core lowering ──────────────────────────
 * The Core layer traffics in f64, so a raw ctx pointer cannot ride through it.
 * Instead Spawn__open registers the ctx in a small fixed table and returns a
 * session id. fork() copies the table, so a child and the parent resolve the
 * same id to their own ctx copy. Names match the externs in emit_mlir, exactly
 * like the Stream__ wrappers below. */
#define YON_SPAWN_MAX 64
static yon_spawn_ctx_t *g_yon_spawn_tab[YON_SPAWN_MAX];

static yon_spawn_ctx_t *yon_spawn_by_id(double id_f) {
    int id = (int)id_f;
    if (id < 0 || id >= YON_SPAWN_MAX) return NULL;
    return g_yon_spawn_tab[id];
}

double Spawn__open(double n) {
    void *ctx = yon_rt_spawn_open(n);
    if (!ctx) return -1.0;
    int id = -1;
    for (int i = 0; i < YON_SPAWN_MAX; i++)
        if (!g_yon_spawn_tab[i]) { id = i; break; }  /* deterministic: same pre/post fork */
    if (id < 0) { yon_rt_spawn_close(ctx); return -1.0; }
    g_yon_spawn_tab[id] = (yon_spawn_ctx_t *)ctx;
    return (double)id;
}

double Spawn__role(double id)  { return yon_rt_spawn_role(yon_spawn_by_id(id)); }
double Spawn__index(double id) { return yon_rt_spawn_index_of(yon_spawn_by_id(id)); }
double Spawn__promote(double id, double v) { yon_rt_spawn_promote(yon_spawn_by_id(id), v); return 0.0; }
double Spawn__child_exit(double id) { yon_rt_spawn_child_exit(yon_spawn_by_id(id)); return 0.0; /* unreachable */ }
double Spawn__join_stream(double id) {
    yon_spawn_ctx_t *c = yon_spawn_by_id(id);
    double sid = yon_rt_spawn_join_stream(c);
    int i = (int)id;
    if (i >= 0 && i < YON_SPAWN_MAX) { yon_rt_spawn_close(c); g_yon_spawn_tab[i] = NULL; }
    return sid;
}

/* Caller side, the v2 core: enqueue the request in the Space's NAMED mailbox,
 * then wait on the private reply channel. -777.0 = unreachable/failed (the
 * language layer turns the sentinel into a clear English error; the in-band
 * sentinel itself is scheduled to become a framed status in a later layer). */
double yon_rt_rpc2_call_named(const char *space_name, double selector,
                              double argc, const double *args,
                              uint32_t reply_timeout_ms) {
    yon_rpc2_session_t *s = yon_rpc2_session(space_name);
    if (!s || !s->q || !s->rep) return -777.0;
    yon_rpc2_req_t req;
    memset(&req, 0, sizeof(req));
    s->seq++;
    req.nonce    = s->nonce;
    req.seq      = s->seq;
    snprintf(req.reply_name, sizeof(req.reply_name), "%s", s->reply_name);
    req.selector = (uint32_t)selector;
    req.argc     = (uint32_t)argc;
    for (uint32_t i = 0; i < req.argc && i < 8u; i++) req.args[i] = args[i];

    if (yon_rpc2_enqueue(s->q, &req, YON_RPC2_ENQ_TIMEOUT_MS) != 0)
        return -777.0;

    struct timespec dl;
    yon_rpc2_deadline(&dl, reply_timeout_ms);
    if (yon_rpc2_lock_timed(&s->rep->mu, YON_RPC2_LOCK_MS) != 0)
        return -777.0;                        /* our own channel corrupt */
    for (;;) {
        if (s->rep->has_value) {
            /* correlation check: accept only OUR call's reply; a late reply
             * of a timed-out earlier call is consumed and discarded. */
            if (s->rep->nonce_echo == s->nonce && s->rep->seq_echo == s->seq) {
                double v = s->rep->value;
                s->rep->has_value = 0;
                pthread_mutex_unlock(&s->rep->mu);
                return v;
            }
            s->rep->has_value = 0;  /* stale: drop and keep waiting */
        }
        struct timespec slice;
        yon_rpc2_deadline(&slice, YON_RPC2_SLICE_MS);
        pthread_cond_timedwait(&s->rep->filled, &s->rep->mu, &slice);
        if (s->rep->has_value) continue;
        if (yon_rpc2_past(&dl)) break;
        pid_t srv = s->q->server_pid;  /* hint read; exactness not required */
        if (srv != 0 && !yon_rpc2_pid_alive(srv)) break;
    }
    pthread_mutex_unlock(&s->rep->mu);
    return -777.0;
}

/* ---- Strato 1: serve loop, name-keyed spawn/lifecycle, named invoke ---- */

/* Server dispatch loop over the v2 mailbox. Idle death after 60s of silence
 * (same policy as v1); reserved selector 0 = protocol shutdown. On both exit
 * paths the server unlinks ITS OWN mailbox: the next first contact recreates
 * a virgin channel (the epoch hygiene Strato 3 builds on). */
double yon_rt_rpc2_serve_loop(const char *space_name) {
    void *q = yon_rt_rpc2_queue_open(space_name, 1);
    if (!q) return -1.0;
    for (;;) {
        yon_rpc2_req_t req;
        int argc = yon_rt_rpc2_take(q, &req, 60000);
        if (argc < 0) break;                        /* idle: peer gone */
        if (req.selector == 0u) {                   /* protocol shutdown */
            yon_rt_rpc2_reply(&req, 0.0);
            break;
        }
        if (req.selector == 0xFFFFFFFFu) {
            /* SUBSCRIPTION (reserved selector): args = (producer_selector,
             * channel_id). Run the producer via the dispatch, obtaining the
             * local stream it returned; drain it (the structural-close
             * sentinel ends the drain); forward each value over the shm
             * channel with back-pressure; close the write side. Synchronous
             * in the loop, by design (v1): producers terminate. */
            double producer_sel = req.args[0];
            double chan_id = req.args[1];
            uint32_t elem_bytes = (uint32_t)req.args[2]; /* 0 = scalar f64;
                                                            >0 = place DTO (byte-ring) */
            double attach = (elem_bytes == 0)
                ? yon_rt_stream_shm_open_f64(chan_id, 0.0)              /* scalar slot ring */
                : yon_rt_stream_shm_open_sized_f64(chan_id, 0.0, 0.0); /* byte ring attach */
            double local_sid = __yon_dispatch(producer_sel, 0.0, 0.0, 0.0, 0.0);
            if (attach >= 0.0 && local_sid >= 0.0) {
                int ch = yon_rt_shm_slot_of((uint32_t)chan_id);
                unsigned char *fbuf = (elem_bytes == 0) ? NULL
                                      : (unsigned char *)malloc(YON_WIRE_RING_BYTES);
                for (;;) {
                    double v = yon_rt_stream_await_f64(local_sid);
                    if (v == (double)0xFFFFFFFFu) break;
                    if (v == -1.0) break;  /* open-but-empty: producer misdeclared */
                    if (elem_bytes == 0) {
                        yon_rt_stream_shm_produce_f64(attach, v); /* scalar: unchanged */
                    } else if (ch >= 0 && fbuf) {
                        /* place: serialize the section's content (recursive,
                         * length prefixed) into a variable frame and push it
                         * onto the dense byte ring. The frame is bounded only by
                         * the ring; an oversized one is a loud failure, never a
                         * silent truncation. */
                        yon_section_t sec = (yon_section_t)(uint64_t)(int64_t)v;
                        int32_t fn = yon_rt_serialize(sec, fbuf, YON_WIRE_RING_BYTES);
                        if (fn < 0) break;
                        int prc = yon_rt_stream_shm_produce_frame_blocking(
                                      g_shm_stream_handles[ch], fbuf, (uint32_t)fn);
                        if (prc == -3) {
                            fprintf(stderr, "[YON-RT] wire: DTO frame (%d bytes) "
                                    "exceeds the %u-byte ring; closing the stream "
                                    "instead of truncating\n", fn, YON_WIRE_RING_BYTES);
                            break;
                        }
                        if (prc != 0) break;
                    } else {
                        break;
                    }
                }
                free(fbuf);
                yon_rt_stream_shm_close_write_f64(attach);
            }
            yon_rt_rpc2_reply(&req, 0.0);
            continue;
        }
        double r = __yon_dispatch((double)req.selector,
                                  req.args[0], req.args[1],
                                  req.args[2], req.args[3]);
        yon_rt_rpc2_reply(&req, r);
    }
    yon_rt_rpc2_queue_close(q);
    yon_rt_rpc2_queue_unlink(space_name);
    return 0.0;
}

/* Name-keyed server registry: binary path + spawned pid per Space. */
typedef struct {
    char  space[64];
    char  path[256];
    pid_t pid;        /* 0 = not spawned by us */
} yon_rpc2_srv_t;

static yon_rpc2_srv_t g_rpc2_srv[YON_RPC2_MAX_SESSIONS];
static uint32_t g_rpc2_n_srv = 0;

static yon_rpc2_srv_t *yon_rpc2_srv_slot(const char *space, int create) {
    for (uint32_t i = 0; i < g_rpc2_n_srv; i++)
        if (strcmp(g_rpc2_srv[i].space, space) == 0) return &g_rpc2_srv[i];
    if (!create || g_rpc2_n_srv >= YON_RPC2_MAX_SESSIONS) return NULL;
    yon_rpc2_srv_t *s = &g_rpc2_srv[g_rpc2_n_srv++];
    memset(s, 0, sizeof(*s));
    snprintf(s->space, sizeof(s->space), "%.63s", space);
    return s;
}

/* Same YON_SRV_DIR override semantics as v1: the env var replaces the
 * directory of the conventional path, the basename is kept. */
void yon_rt_rpc2_register_space_binary(const char *space, const char *path) {
    yon_rpc2_srv_t *s = yon_rpc2_srv_slot(space, 1);
    if (!s) return;
    const char *dir = getenv("YON_SRV_DIR");
    if (dir && dir[0]) {
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        snprintf(s->path, sizeof(s->path), "%s/%s", dir, base);
    } else {
        snprintf(s->path, sizeof(s->path), "%.255s", path);
    }
}

/* Cascade lifecycle: at caller exit, protocol-shutdown every server we
 * spawned, then reap; SIGKILL as a last resort (mirrors the v1 policy that
 * was VERIFIED on the A->B->C composition). */
static void yon_rt_rpc2_shutdown_spawned(void) {
    for (uint32_t i = 0; i < g_rpc2_n_srv; i++) {
        yon_rpc2_srv_t *s = &g_rpc2_srv[i];
        if (s->pid <= 0) continue;
        yon_rt_rpc2_call_named(s->space, 0.0, 0.0, NULL, 1000);
        int status;
        int reaped = 0;
        for (int k = 0; k < 20; k++) {              /* up to 1s grace */
            pid_t w = waitpid(s->pid, &status, WNOHANG);
            if (w == s->pid ||
                (w < 0 && errno == ECHILD)) {       /* reaped (maybe elsewhere) */
                reaped = 1;
                break;
            }
            usleep(50000);
        }
        if (!reaped) { kill(s->pid, SIGKILL); waitpid(s->pid, &status, 0); }
        s->pid = 0;
    }
}
static int g_rpc2_shutdown_registered = 0;

/* Fork/exec the Space's registered binary in serve mode (`--serve2 <name>`).
 * Fail fast if no path is registered or the binary is missing. */
static double yon_rt_rpc2_spawn_server(const char *space) {
    yon_rpc2_srv_t *s = yon_rpc2_srv_slot(space, 0);
    if (!s || s->path[0] == 0) return -1.0;
    if (access(s->path, X_OK) != 0) return -1.0;
    pid_t pid = fork();
    if (pid < 0) return -1.0;
    if (pid == 0) {
        execl(s->path, s->path, "--serve2", s->space, (char *)NULL);
        _exit(127);
    }
    s->pid = pid;
    if (!g_rpc2_shutdown_registered) {
        atexit(yon_rt_rpc2_shutdown_spawned);
        g_rpc2_shutdown_registered = 1;
    }
    return (double)pid;
}

static yon_rpc2_session_t *yon_rpc2_session_find(const char *space) {
    for (uint32_t i = 0; i < g_rpc2_n_sessions; i++)
        if (strcmp(g_rpc2_sessions[i].space, space) == 0 &&
            g_rpc2_sessions[i].owner == getpid())
            return &g_rpc2_sessions[i];
    return NULL;
}

static int yon_rpc2_session_exists(const char *space) {
    for (uint32_t i = 0; i < g_rpc2_n_sessions; i++)
        if (strcmp(g_rpc2_sessions[i].space, space) == 0 &&
            g_rpc2_sessions[i].owner == getpid())
            return 1;
    return 0;
}

/* Core of the lowered cross-Space call, v2: NAMED Space, first-contact spawn,
 * v1 timeout policy (60s steady / 10s just-spawned / 3s unspawnable). */
/* Epoch recovery (decision 3): if the Space's server is CONFIRMED dead
 * (kill(pid,0) -> ESRCH on the claimed server_pid), surrender the orphaned
 * mailbox — NEVER re-init in place — and rendezvous on a VIRGIN channel
 * under the same nominal name, epoch advanced. Only the winner of the
 * O_EXCL re-creation race re-spawns the server (one server per Space);
 * losers simply retry on the fresh channel while it boots.
 * Returns 0 = no recovery applicable, 1 = recovered (retry warranted). */
static int yon_rpc2_recover(const char *space) {
    yon_rpc2_session_t *sess = yon_rpc2_session_find(space);
    if (!sess || !sess->q) return 0;
    pid_t srv_pid = sess->q->server_pid;
    if (srv_pid == 0 || yon_rpc2_pid_alive(srv_pid)) return 0;
    uint32_t e_old = sess->q->epoch;
    munmap(sess->q, sizeof(*sess->q));
    sess->q = NULL;
    char nm[256];
    yon_rpc2_shm_name(nm, sizeof(nm), YON_RPC2_REQ_PREFIX, space);
    shm_unlink(nm);                       /* idempotent across recoverers */
    int created = 0;
    sess->q = yon_rpc2_queue_map_init(space, e_old + 1, &created);
    if (!sess->q) return 0;
    /* If the dead server was OUR spawned child, reap the zombie before the
     * pid slot is overwritten (bounded: it just died, the zombie is there). */
    yon_rpc2_srv_t *srv = yon_rpc2_srv_slot(space, 0);
    if (srv && srv->pid > 0 && !yon_rpc2_pid_alive(srv->pid)) {
        int st;
        for (int k = 0; k < 20; k++) {
            pid_t w = waitpid(srv->pid, &st, WNOHANG);
            if (w == srv->pid || (w < 0 && errno == ECHILD)) break;
            usleep(10000);
        }
        srv->pid = 0;
    }
    if (created)
        yon_rt_rpc2_spawn_server(space);  /* the race winner re-spawns */
    return 1;
}

static double yon_rt_rpc2_invoke_named_n(const char *space, double op_selector,
                                         double argc, const double *args) {
    uint32_t reply_ms = 60000u;
    if (!yon_rpc2_session_exists(space)) {
        double pid = yon_rt_rpc2_spawn_server(space);
        reply_ms = (pid >= 0.0) ? 10000u : 3000u;
    }
    double r = yon_rt_rpc2_call_named(space, op_selector, argc, args, reply_ms);
    if (r == -777.0 && yon_rpc2_recover(space)) {
        /* virgin channel + (re)spawned server: one retry, spawn window */
        r = yon_rt_rpc2_call_named(space, op_selector, argc, args, 10000u);
    }
    if (r == -777.0) {
        yon_rpc2_srv_t *s = yon_rpc2_srv_slot(space, 0);
        if (s && s->path[0])
            fprintf(stderr, "error: cross-Space call failed — Space server '%s' "
                            "did not answer or the operation is not exported\n",
                    s->path);
        else
            fprintf(stderr, "error: cross-Space call failed — no server reachable "
                            "for Space '%s'\n", space);
    }
    return r;
}

/* Arity wrappers for the lowered code (the MLIR passes the Space name as a
 * pointer to a global string — nominal identity, decision 1). */
double yon_rt_rpc2_invoke_named0(const char *sp, double sel) {
    return yon_rt_rpc2_invoke_named_n(sp, sel, 0.0, NULL);
}
double yon_rt_rpc2_invoke_named(const char *sp, double sel, double x) {
    double a[1] = { x };
    return yon_rt_rpc2_invoke_named_n(sp, sel, 1.0, a);
}
double yon_rt_rpc2_invoke_named2(const char *sp, double sel, double x, double y) {
    double a[2] = { x, y };
    return yon_rt_rpc2_invoke_named_n(sp, sel, 2.0, a);
}
double yon_rt_rpc2_invoke_named3(const char *sp, double sel, double x, double y,
                                 double z) {
    double a[3] = { x, y, z };
    return yon_rt_rpc2_invoke_named_n(sp, sel, 3.0, a);
}
double yon_rt_rpc2_invoke_named4(const char *sp, double sel, double x, double y,
                                 double z, double w) {
    double a[4] = { x, y, z, w };
    return yon_rt_rpc2_invoke_named_n(sp, sel, 4.0, a);
}

/* `--serve2 <SpaceName>` detection, mirroring yon_rt_should_serve (v1):
 * /proc/self/cmdline first, stashed argv fallback (macOS has no /proc).
 * Returns 1 and fills `out` if this process must serve in v2 mode. */
int yon_rt_should_serve2(char *out, size_t outsz) {
    FILE *f = fopen("/proc/self/cmdline", "rb");
    if (f) {
        char buf[4096];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        buf[n] = 0;
        size_t i = 0;
        while (i < n) {
            const char *arg = buf + i;
            size_t len = strlen(arg);
            if (strcmp(arg, "--serve2") == 0 && i + len + 1 < n) {
                snprintf(out, outsz, "%s", buf + i + len + 1);
                return 1;
            }
            i += len + 1;
        }
        return 0;
    }
    for (int i = 1; i + 1 < g_argc; i++)
        if (strcmp(g_argv[i], "--serve2") == 0) {
            snprintf(out, outsz, "%s", g_argv[i + 1]);
            return 1;
        }
    return 0;
}

/* ============================================================== */
/* Mattone B, Strato 1: cross-MACHINE stream over raw TCP          */
/* ============================================================== */
/* Same-machine used SHM. Across machines we use a raw TCP socket with a
 * deliberately tiny, hardened framing layer. We are NOT writing an HTTP server
 * parsing arbitrary input: we exchange fixed-size xheap slots. The frame is
 * simply [u32 length][length bytes]. The three golden rules are enforced here:
 *
 *   1. NO packet-driven allocation. The max slot size is known at compile time
 *      (YON_NET_MAX_SLOT). A frame declaring more is rejected and the
 *      connection is dropped as malicious — we never malloc what the wire says.
 *   2. Read into a FIXED stack buffer of YON_NET_MAX_SLOT bytes, never a
 *      wire-sized heap buffer.
 *   3. We transport raw value bytes (offsets/content), never pointers: the
 *      receiver validates structure, it does not execute anything from the wire.
 *
 * Security note (network, orthogonal): TCP is cleartext. Acceptable inside a
 * trusted network (VPC/LAN), exactly like a PostgreSQL cluster. Encryption is a
 * later, non-invasive add (TLS over the socket, or a WireGuard tunnel) that
 * changes no Space logic. */

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define YON_NET_MAX_SLOT 256u   /* compile-time cap; mirrors the SHM slot cap */

/* Read exactly n bytes (handles short reads). Returns 0 on success, -1 on
 * EOF/error. n is bounded by the caller to <= YON_NET_MAX_SLOT. */
static int net_read_exact(int fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

static int net_write_exact(int fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t put = 0;
    while (put < n) {
        ssize_t w = write(fd, p + put, n - put);
        if (w <= 0) return -1;
        put += (size_t)w;
    }
    return 0;
}

/* Server side (the consumer node): bind+listen on a port, accept ONE peer,
 * return the connected fd. Returns -1 on failure. */
int yon_rt_net_listen(uint16_t port) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("[YON-NET] socket"); return -1; }
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("[YON-NET] bind"); close(srv); return -1;
    }
    if (listen(srv, 1) < 0) { perror("[YON-NET] listen"); close(srv); return -1; }
    int fd = accept(srv, NULL, NULL);
    close(srv);
    if (fd < 0) { perror("[YON-NET] accept"); return -1; }
    return fd;
}

/* Client side (the producer node): connect to host:port, return the fd. */
int yon_rt_net_connect(const char *host, uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("[YON-NET] socket"); return -1; }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        fprintf(stderr, "[YON-NET] bad host %s\n", host); close(fd); return -1;
    }
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("[YON-NET] connect"); close(fd); return -1;
    }
    return fd;
}

/* Send one frame: [u32 length][payload]. length is the caller's slot size,
 * which the caller guarantees <= YON_NET_MAX_SLOT. */
int yon_rt_net_send_frame(int fd, const void *payload, uint32_t length) {
    if (length > YON_NET_MAX_SLOT) {
        fprintf(stderr, "[YON-NET] refusing oversize send (%u)\n", length);
        return -1;
    }
    uint32_t net_len = htonl(length);
    if (net_write_exact(fd, &net_len, sizeof(net_len)) != 0) return -1;
    if (net_write_exact(fd, payload, length) != 0) return -1;
    return 0;
}

/* Receive one frame into a FIXED buffer. Golden rule #1: if the wire declares a
 * length beyond YON_NET_MAX_SLOT, we DROP the connection (return -1) and never
 * allocate. out_len receives the actual byte count. out_buf must be at least
 * YON_NET_MAX_SLOT bytes. */
int yon_rt_net_recv_frame(int fd, void *out_buf, uint32_t *out_len) {
    uint32_t net_len;
    if (net_read_exact(fd, &net_len, sizeof(net_len)) != 0) return -1;
    uint32_t length = ntohl(net_len);
    if (length > YON_NET_MAX_SLOT) {
        fprintf(stderr,
                "[YON-NET] frame length %u exceeds max %u -> dropping (malicious)\n",
                length, YON_NET_MAX_SLOT);
        return -1;  /* connection treated as hostile; caller closes fd */
    }
    if (net_read_exact(fd, out_buf, length) != 0) return -1;
    *out_len = length;
    return 0;
}

void yon_rt_net_close(int fd) { if (fd >= 0) close(fd); }

/* ── Strato 2+3: net-stream with the SHM stream's emit/await API ────────────
 *
 * Strato 2 (serialization) is trivial here: a value is a fixed-size double, so
 * serialization is a memcpy of sizeof(double) bytes — done inside send/recv.
 *
 * Strato 3 exposes the SAME id-f64 calling convention as the SHM stream, so a
 * Space writes cross-MACHINE exactly as it writes cross-process: make_net then
 * send_net/recv_net, mirroring make_shm/send_shm/recv_shm. The only extra
 * parameter is role+port: a server node listens, a client node connects. The
 * handle registry maps an id to the connected socket fd. */

#define YON_MAX_NET_STREAMS 64
static int g_net_stream_fds[YON_MAX_NET_STREAMS];
static int g_net_streams_init = 0;

static void net_streams_ensure_init(void) {
    if (g_net_streams_init) return;
    for (int i = 0; i < YON_MAX_NET_STREAMS; i++) g_net_stream_fds[i] = -1;
    g_net_streams_init = 1;
}

/* Open a net-stream identified by id. is_server=1 -> listen on `port` and
 * accept one peer; is_server=0 -> connect to 127.0.0.1:port (host is a
 * parameter to generalize later — the IP is just an argument). Returns id as
 * f64, or -1.0 on failure. Both sides agree on the same id by convention, as
 * with the SHM streams. */
double yon_rt_stream_net_open_f64(double id_f64, double port_f64,
                                  double is_server_f64) {
    net_streams_ensure_init();
    uint32_t id = (uint32_t)id_f64;
    if (id >= YON_MAX_NET_STREAMS) return -1.0;
    uint16_t port = (uint16_t)port_f64;
    int fd = ((int)is_server_f64)
             ? yon_rt_net_listen(port)
             : yon_rt_net_connect("127.0.0.1", port);
    if (fd < 0) return -1.0;
    g_net_stream_fds[id] = fd;
    return (double)id;
}

/* Send a value across the machine boundary. Serialization = memcpy of the
 * double into the frame payload (Strato 2). */
double yon_rt_stream_net_send_f64(double id_f64, double value) {
    net_streams_ensure_init();
    uint32_t id = (uint32_t)id_f64;
    if (id >= YON_MAX_NET_STREAMS || g_net_stream_fds[id] < 0) return -1.0;
    return (double)yon_rt_net_send_frame(g_net_stream_fds[id], &value,
                                         (uint32_t)sizeof(double));
}

/* Receive a value. Golden rules already enforced inside recv_frame. */
double yon_rt_stream_net_recv_f64(double id_f64) {
    net_streams_ensure_init();
    uint32_t id = (uint32_t)id_f64;
    if (id >= YON_MAX_NET_STREAMS || g_net_stream_fds[id] < 0) return -1.0;
    uint8_t buf[YON_NET_MAX_SLOT];
    uint32_t len = 0;
    if (yon_rt_net_recv_frame(g_net_stream_fds[id], buf, &len) != 0) return -1.0;
    if (len != sizeof(double)) return -1.0;
    double out;
    memcpy(&out, buf, sizeof(double));
    return out;
}

double yon_rt_stream_net_close_f64(double id_f64) {
    net_streams_ensure_init();
    uint32_t id = (uint32_t)id_f64;
    if (id >= YON_MAX_NET_STREAMS || g_net_stream_fds[id] < 0) return -1.0;
    yon_rt_net_close(g_net_stream_fds[id]);
    g_net_stream_fds[id] = -1;
    return 0.0;
}

/* Frontend-facing aliases, mirroring Stream__make_shm/send_shm/recv_shm. */
double Stream__make_net(double id, double port, double is_server) {
    return yon_rt_stream_net_open_f64(id, port, is_server);
}
double Stream__send_net(double id, double v) { return yon_rt_stream_net_send_f64(id, v); }
double Stream__recv_net(double id)           { return yon_rt_stream_net_recv_f64(id); }
double Stream__close_net(double id)          { return yon_rt_stream_net_close_f64(id); }


/* ============================================================== */
/* Handler dispatch (thin wrappers)                                */
/* ============================================================== */

int yon_rt_handler_push(uint64_t hash, void *fn_ptr) {
    ensure_init();
    return yon_handler_push(hash, fn_ptr);
}

int yon_rt_handler_pop(uint64_t hash) {
    ensure_init();
    return yon_handler_pop(hash);
}

void *yon_rt_handler_lookup(uint64_t hash) {
    ensure_init();
    return yon_handler_lookup(hash);
}

/* ============================================================== */
/* Stdlib coercions                                                */
/* ============================================================== */

/* String fusion (2026-06-03): a text/String value is an xheap handle.
 * text_to_prop: absent (1) for the 0.0 failure sentinel or an empty string,
 * present (0) otherwise — same semantics as the old pointer version, which
 * only ever received NULL (literals were emitted as llvm.mlir.zero). */
uint8_t yon_rt_text_to_prop(double h) {
    const char *yon_ds_cstr_fwd(double);   /* defined later in this file */
    const char *s = h == 0.0 ? NULL : yon_ds_cstr_fwd(h);
    if (!s || s[0] == '\0') return 1;
    return 0;
}

uint8_t yon_rt_to_prop(int8_t b) { return b ? 0 : 1; }
int8_t  yon_rt_to_bool(uint8_t prop) { return (prop == 0) ? 1 : 0; }
double  yon_rt_transport(double witness, double value) {
    (void)witness; return value;
}

/* ============================================================== */
/* Diagnostic                                                      */
/* ============================================================== */

uint32_t yon_rt_heap_occupancy(uint32_t heap_id) {
    ensure_init();
    if (heap_id >= g_n_spaces) return 0;
    return g_spaces[heap_id].occupancy;
}

/* ============================================================== */
/* P10 Data structures — singleton xheap content-addressed         */
/* ============================================================== */

#include "xleech2_heap.h"

static yon_xheap_t *g_ds_heap = NULL;

static void ds_ensure_init(void) {
    if (!g_ds_heap) {
        /* Unification of the Leech allocator. All data structures (List,
         * HashSet, HashMap, XSet, Merkle) share the same xheap g_yon_heap.
         * Benefit: content-addressing works cross-structure, and separate heaps
         * are not exhausted. Previously g_ds_heap was a separate
         * yon_xheap_create(), so list_cons could fill up even with an almost
         * empty HashSet. Now g_ds_heap = g_yon_heap (unified). */
        extern yon_xheap_t *g_yon_heap;
        if (!g_yon_heap) {
            g_yon_heap = yon_xheap_create();
        }
        g_ds_heap = g_yon_heap;
    }
}

/* slot_index encoding in the double: integers up to 2^53 are exactly
 * representable in f64. N_SLOTS = 196560 fits in 18 bits, so the full f64
 * range is fine. map_id = slot_index, 0 = empty. */

/* ---- HASHMAP ----------------------------------------------------- */
/* A real O(1) get/put HashMap.
 *
 * Design:
 *   - Storage entries (key, value): xheap arena content-addressed.
 *     Dedup naturale per entries (k, v) identiche.
 *   - Directory: an array of N_INDEX xheap slots (mutable in-place).
 *     hash(key) % N_INDEX -> directory slot -> xheap_get -> entry.
 *   - Collision resolution: linear probing in the directory.
 *
 * HashMap_id = pointer to the directory (mapped to double via index in g_hashmaps[]).
 * 0 = empty (lazy init on first put).
 *
 * The old linked-list Map (O(n) walk) was removed. The new API keeps the same
 * yon_rt_map_* names for backward-compat of the MLIR emit; the surface API is
 * renamed HashMap.X (see tycheck/desugar).
 *
 * Honest: it does NOT use the xleech2 MPHF (which is specific to type-2
 * xcoords). It uses FNV1a on the f64 bit pattern, ideal for a general-purpose
 * f64 key. */

/* 2026-06-04: DYNAMIC directory. Starts at YON_HM_DIR_INIT slots and
 * doubles (with rehash) when the load factor would exceed 70%. NO cap:
 * load α <= 0.7 is an INVARIANT, always upheld — with linear probing it
 * guarantees an expected O(1) probe count (~1/(1-α)) at every size. The
 * limit is memory, like the heap chain. No knobs to tune, no degraded
 * regimes. */
#define YON_HM_DIR_INIT  4096u
#define YON_HM_MAX_MAPS  256u    /* numero massimo di HashMap concorrenti */

typedef struct {
    double key;
    double value;
    uint32_t occupied;  /* 0 = empty, 1 = present, 2 = tombstone (deleted) */
    uint32_t pad;
} ds_hashmap_entry_t;

typedef struct {
    /* Directory: for each directory slot, the xheap slot of the entry.
     * SLOT_INVALID = empty bucket. Allocata lazy, cresce con rehash. */
    uint32_t *entry_slot;
    uint32_t dir_slots;
    uint32_t n_entries;
    uint32_t is_used;  /* 1 = HashMap instantiated */
} ds_hashmap_t;

static ds_hashmap_t g_hashmaps[YON_HM_MAX_MAPS];
static uint32_t g_n_hashmaps = 0;

/* FNV1a hash su 8 byte (f64 bit pattern) */
static uint32_t hash_f64(double key) {
    union { double d; uint64_t u; } conv;
    conv.d = key;
    uint32_t h = 2166136261u;
    for (int i = 0; i < 8; i++) {
        uint8_t b = (conv.u >> (i * 8)) & 0xFFu;
        h ^= b;
        h *= 16777619u;
    }
    return h;
}

double yon_rt_map_empty(void) {
    ds_ensure_init();
    /* Allocate a new HashMap. Returns id+1 (shifted to avoid a valid 0). */
    if (g_n_hashmaps >= YON_HM_MAX_MAPS) {
        fprintf(stderr, "[YON-RT] map_empty: HashMap pool exhausted\n");
        return 0.0;
    }
    uint32_t id = g_n_hashmaps++;
    ds_hashmap_t *hm = &g_hashmaps[id];
    hm->dir_slots = YON_HM_DIR_INIT;
    hm->entry_slot = (uint32_t *)malloc(hm->dir_slots * sizeof(uint32_t));
    if (!hm->entry_slot) {
        fprintf(stderr, "[YON-RT] map_empty: out of memory\n");
        g_n_hashmaps--;
        return 0.0;
    }
    for (uint32_t i = 0; i < hm->dir_slots; i++) {
        hm->entry_slot[i] = YON_HEAP_SLOT_INVALID;
    }
    hm->n_entries = 0;
    hm->is_used = 1;
    return (double)(id + 1);
}

static ds_hashmap_t *hashmap_lookup(double map_id) {
    if (map_id < 0.5) return NULL;  /* empty marker */
    uint32_t shifted = (uint32_t)map_id;
    if (shifted == 0 || shifted > g_n_hashmaps) return NULL;
    ds_hashmap_t *hm = &g_hashmaps[shifted - 1];
    if (!hm->is_used) return NULL;
    return hm;
}

/* Raddoppia la directory e ripiazza tutte le entry vive (rehash).
 * Le entry restano dove sono (slot xheap): si rimappano solo gli indici. */
static int hashmap_grow(ds_hashmap_t *hm) {
    uint32_t new_slots = hm->dir_slots * 2;
    if (new_slots <= hm->dir_slots) return 0;   /* arithmetic overflow only */
    uint32_t *nd = (uint32_t *)malloc(new_slots * sizeof(uint32_t));
    if (!nd) return 0;
    for (uint32_t i = 0; i < new_slots; i++) nd[i] = YON_HEAP_SLOT_INVALID;
    uint32_t live = 0;
    for (uint32_t i = 0; i < hm->dir_slots; i++) {
        uint32_t slot = hm->entry_slot[i];
        if (slot == YON_HEAP_SLOT_INVALID) continue;
        const ds_hashmap_entry_t *e =
            (const ds_hashmap_entry_t *)yon_xheap_payload_chain(slot);
        if (!e || e->occupied != 1) continue;   /* tombstone: si scarta */
        uint32_t h = hash_f64(e->key);
        for (uint32_t j = 0; j < new_slots; j++) {
            uint32_t idx = (h + j) % new_slots;
            if (nd[idx] == YON_HEAP_SLOT_INVALID) { nd[idx] = slot; live++; break; }
        }
    }
    free(hm->entry_slot);
    hm->entry_slot = nd;
    hm->dir_slots = new_slots;
    hm->n_entries = live;
    return 1;
}

double yon_rt_map_put(double map_id, double key, double value) {
    ds_ensure_init();
    /* Lazy init: if map_id == 0, allocate a new HashMap. */
    ds_hashmap_t *hm = (map_id < 0.5) ? NULL : hashmap_lookup(map_id);
    if (!hm) {
        double new_id = yon_rt_map_empty();
        hm = hashmap_lookup(new_id);
        if (!hm) return 0.0;
        map_id = new_id;
    }
    /* Create a payload entry in the xheap (content-addressed dedup). */
    ds_hashmap_entry_t entry;
    entry.key = key;
    entry.value = value;
    entry.occupied = 1;
    entry.pad = 0;
    /* 2026-06-04: allocazione via CHAIN — quando l'heap corrente e' pieno
     * la catena si estende da sola (xleech2: HeapRef Registry + Chain).
     * entry_slot[] contiene HeapRef globali (8 bit heap | 24 bit slot);
     * per heap 0 il valore coincide col vecchio slot nudo. */
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &entry, sizeof(entry), YON_TAG_USER1);
    if (slot == YON_HEAPREF_INVALID) return map_id;
    /* Crescita al 70% di load: mai saturazione silenziosa sotto DIR_MAX. */
    if ((uint64_t)hm->n_entries * 10u >= (uint64_t)hm->dir_slots * 7u) {
        (void)hashmap_grow(hm);
    }
    /* Linear probing in the directory. */
    uint32_t h = hash_f64(key);
    for (uint32_t i = 0; i < hm->dir_slots; i++) {
        uint32_t idx = (h + i) % hm->dir_slots;
        if (hm->entry_slot[idx] == YON_HEAP_SLOT_INVALID) {
            /* Slot libero: inserisci. */
            hm->entry_slot[idx] = slot;
            hm->n_entries++;
            return map_id;
        }
        /* Slot occupied: check if it is the same key (update value). */
        {
            const ds_hashmap_entry_t *e =
                (const ds_hashmap_entry_t *)yon_xheap_payload_chain(hm->entry_slot[idx]);
            if (e && e->occupied == 1 && e->key == key) {
                /* Same key: overwrite with a new slot. */
                hm->entry_slot[idx] = slot;
                return map_id;
            }
        }
    }
    fprintf(stderr, "[YON-RT] map_put: directory full (load 100%%)\n");
    return map_id;
}

double yon_rt_map_get(double map_id, double key) {
    ds_ensure_init();
    ds_hashmap_t *hm = hashmap_lookup(map_id);
    if (!hm) return 0.0;
    uint32_t h = hash_f64(key);
    for (uint32_t i = 0; i < hm->dir_slots; i++) {
        uint32_t idx = (h + i) % hm->dir_slots;
        if (hm->entry_slot[idx] == YON_HEAP_SLOT_INVALID) return 0.0;  /* not found */
        const ds_hashmap_entry_t *e =
            (const ds_hashmap_entry_t *)yon_xheap_payload_chain(hm->entry_slot[idx]);
        if (!e) continue;
        if (e->occupied == 1 && e->key == key) return e->value;
    }
    return 0.0;
}

double yon_rt_map_contains(double map_id, double key) {
    ds_ensure_init();
    ds_hashmap_t *hm = hashmap_lookup(map_id);
    if (!hm) return 0.0;
    uint32_t h = hash_f64(key);
    for (uint32_t i = 0; i < hm->dir_slots; i++) {
        uint32_t idx = (h + i) % hm->dir_slots;
        if (hm->entry_slot[idx] == YON_HEAP_SLOT_INVALID) return 0.0;
        const ds_hashmap_entry_t *e =
            (const ds_hashmap_entry_t *)yon_xheap_payload_chain(hm->entry_slot[idx]);
        if (!e) continue;
        if (e->occupied == 1 && e->key == key) return 1.0;
    }
    return 0.0;
}

double yon_rt_map_size(double map_id) {
    ds_hashmap_t *hm = hashmap_lookup(map_id);
    if (!hm) return 0.0;
    return (double)hm->n_entries;
}

/* ---- HashMap.to_stream --------------------- */

double yon_rt_map_to_list(double map_id) {
    ds_ensure_init();
    ds_hashmap_t *hm = hashmap_lookup(map_id);
    if (!hm) return yon_rt_list_empty(0.0);
    double list_id = yon_rt_list_empty(0.0);
    for (uint32_t i = 0; i < hm->dir_slots; i++) {
        if (hm->entry_slot[i] == YON_HEAP_SLOT_INVALID) continue;
        const ds_hashmap_entry_t *e =
            (const ds_hashmap_entry_t *)yon_xheap_payload_chain(hm->entry_slot[i]);
        if (!e || e->occupied != 1) continue;
        list_id = yon_rt_list_cons(e->value, list_id);
    }
    return list_id;
}

/* ---- HASHSET -------------------------------- */
/* Drop HashSet-via-HashMap. Nuovo runtime dedicato:
 *
 * Storage: keys inline in directory (8 byte ciascuna), bitmap separato
 * per `occupied`. Niente xheap entries — risparmio 50% spazio rispetto
 * al riuso di HashMap (16 byte entry vs 8 byte key-only).
 *
 * API: empty/add/contains/size/to_list. Niente get/has/set.
 *
 * Hash function: the same FNV1a (general-purpose f64 key). */

/* 2026-06-04: dynamic directory, same invariant as the HashMap
 * (α <= 0.7 always, doubling with rehash, no cap). */
#define YON_HS_DIR_INIT  4096u
#define YON_HS_MAX_SETS  256u

typedef struct {
    double *keys;
    uint32_t *occupied;   /* bitmap 1 bit per slot */
    uint32_t dir_slots;
    uint32_t n_entries;
    uint32_t is_used;
} ds_hashset_t;

static ds_hashset_t g_hashsets[YON_HS_MAX_SETS];
static uint32_t g_n_hashsets = 0;

static inline int hs_bit_get(const uint32_t *bm, uint32_t idx) {
    return (bm[idx >> 5] >> (idx & 31)) & 1;
}
static inline void hs_bit_set(uint32_t *bm, uint32_t idx) {
    bm[idx >> 5] |= (1u << (idx & 31));
}

double yon_rt_hashset_empty(void) {
    ds_ensure_init();
    if (g_n_hashsets >= YON_HS_MAX_SETS) {
        fprintf(stderr, "[YON-RT] hashset_empty: pool exhausted\n");
        return 0.0;
    }
    uint32_t id = g_n_hashsets++;
    ds_hashset_t *hs = &g_hashsets[id];
    hs->dir_slots = YON_HS_DIR_INIT;
    hs->keys = (double *)malloc(hs->dir_slots * sizeof(double));
    hs->occupied = (uint32_t *)calloc(hs->dir_slots / 32, sizeof(uint32_t));
    if (!hs->keys || !hs->occupied) {
        fprintf(stderr, "[YON-RT] hashset_empty: out of memory\n");
        free(hs->keys); free(hs->occupied);
        g_n_hashsets--;
        return 0.0;
    }
    hs->n_entries = 0;
    hs->is_used = 1;
    return (double)(id + 1);
}

static ds_hashset_t *hashset_lookup(double set_id) {
    if (set_id < 0.5) return NULL;
    uint32_t shifted = (uint32_t)set_id;
    if (shifted == 0 || shifted > g_n_hashsets) return NULL;
    ds_hashset_t *hs = &g_hashsets[shifted - 1];
    if (!hs->is_used) return NULL;
    return hs;
}

static int hashset_grow(ds_hashset_t *hs) {
    uint32_t new_slots = hs->dir_slots * 2;
    if (new_slots <= hs->dir_slots) return 0;
    double *nk = (double *)malloc(new_slots * sizeof(double));
    uint32_t *no = (uint32_t *)calloc(new_slots / 32, sizeof(uint32_t));
    if (!nk || !no) { free(nk); free(no); return 0; }
    for (uint32_t i = 0; i < hs->dir_slots; i++) {
        if (!hs_bit_get(hs->occupied, i)) continue;
        uint32_t h = hash_f64(hs->keys[i]);
        for (uint32_t j = 0; j < new_slots; j++) {
            uint32_t idx = (h + j) % new_slots;
            if (!hs_bit_get(no, idx)) { nk[idx] = hs->keys[i]; hs_bit_set(no, idx); break; }
        }
    }
    free(hs->keys); free(hs->occupied);
    hs->keys = nk; hs->occupied = no; hs->dir_slots = new_slots;
    return 1;
}

double yon_rt_hashset_add(double set_id, double elem) {
    ds_ensure_init();
    ds_hashset_t *hs = (set_id < 0.5) ? NULL : hashset_lookup(set_id);
    if (!hs) {
        double new_id = yon_rt_hashset_empty();
        hs = hashset_lookup(new_id);
        if (!hs) return 0.0;
        set_id = new_id;
    }
    if ((uint64_t)hs->n_entries * 10u >= (uint64_t)hs->dir_slots * 7u) {
        (void)hashset_grow(hs);
    }
    uint32_t h = hash_f64(elem);
    for (uint32_t i = 0; i < hs->dir_slots; i++) {
        uint32_t idx = (h + i) % hs->dir_slots;
        if (!hs_bit_get(hs->occupied, idx)) {
            hs->keys[idx] = elem;
            hs_bit_set(hs->occupied, idx);
            hs->n_entries++;
            return set_id;
        }
        if (hs->keys[idx] == elem) return set_id;  /* dedup */
    }
    fprintf(stderr, "[YON-RT] hashset_add: directory full\n");
    return set_id;
}

double yon_rt_hashset_contains(double set_id, double elem) {
    ds_hashset_t *hs = hashset_lookup(set_id);
    if (!hs) return 0.0;
    uint32_t h = hash_f64(elem);
    for (uint32_t i = 0; i < hs->dir_slots; i++) {
        uint32_t idx = (h + i) % hs->dir_slots;
        if (!hs_bit_get(hs->occupied, idx)) return 0.0;
        if (hs->keys[idx] == elem) return 1.0;
    }
    return 0.0;
}

double yon_rt_hashset_size(double set_id) {
    ds_hashset_t *hs = hashset_lookup(set_id);
    if (!hs) return 0.0;
    return (double)hs->n_entries;
}

double yon_rt_hashset_to_list(double set_id) {
    ds_ensure_init();
    ds_hashset_t *hs = hashset_lookup(set_id);
    if (!hs) return yon_rt_list_empty(0.0);
    double list_id = yon_rt_list_empty(0.0);
    for (uint32_t i = 0; i < hs->dir_slots; i++) {
        if (hs_bit_get(hs->occupied, i)) {
            list_id = yon_rt_list_cons(hs->keys[i], list_id);
        }
    }
    return list_id;
}

/* ---- XSet -------------------------------------------------------- */
/* MPHF-backed set: elements are type-2 xcoords of the 24D Leech lattice.
 * Backing: a bitmap of 196560 bits (= 24570 bytes = ~24 KB) per set.
 *
 * Operations:
 *   add(s, xcoord)        : bit[mphf_index(xcoord)] = 1                 O(1)
 *   contains(s, xcoord)   : bit[mphf_index(xcoord)] == 1                O(1)
 *   size(s)               : popcount over the 3072 uint64 chunks         O(196560/64)
 *   union(s1, s2)         : parallel bit-OR over 3072 uint64             O(3072)
 *   intersect(s1, s2)     : parallel bit-AND over 3072 uint64            O(3072)
 *   to_list(s)            : iterate bits, yields the original xcoords    O(196560)
 *
 * Limit: xcoord must be a valid type-2 vector (checked via MPHF). A non-type-2
 * value -> add is ignored (silently). */

extern uint32_t yon_mphf_index(uint32_t v);
extern uint32_t yon_mphf_unindex(uint32_t idx);
#define YON_MPHF_INVALID UINT32_MAX

#define YON_XSET_N_BITS    196560u
#define YON_XSET_N_CHUNKS  (YON_XSET_N_BITS / 64u + 1u)   /* 3072 + 1 padding */
#define YON_XSET_MAX_SETS  256u

typedef struct {
    uint64_t bits[YON_XSET_N_CHUNKS];
    uint32_t n_entries;  /* cached popcount, recomputed lazily */
    uint32_t is_used;
    uint32_t cache_valid;
} ds_xset_t;

static ds_xset_t g_xsets[YON_XSET_MAX_SETS];
static uint32_t g_n_xsets = 0;

double yon_rt_xset_empty(void) {
    if (g_n_xsets >= YON_XSET_MAX_SETS) {
        fprintf(stderr, "[YON-RT] xset_empty: pool exhausted\n");
        return 0.0;
    }
    uint32_t id = g_n_xsets++;
    ds_xset_t *xs = &g_xsets[id];
    memset(xs->bits, 0, sizeof(xs->bits));
    xs->n_entries = 0;
    xs->is_used = 1;
    xs->cache_valid = 1;
    return (double)(id + 1);
}

static ds_xset_t *xset_lookup(double set_id) {
    if (set_id < 0.5) return NULL;
    uint32_t shifted = (uint32_t)set_id;
    if (shifted == 0 || shifted > g_n_xsets) return NULL;
    ds_xset_t *xs = &g_xsets[shifted - 1];
    if (!xs->is_used) return NULL;
    return xs;
}

double yon_rt_xset_add(double set_id, double xcoord_f64) {
    ds_xset_t *xs = (set_id < 0.5) ? NULL : xset_lookup(set_id);
    if (!xs) {
        double new_id = yon_rt_xset_empty();
        xs = xset_lookup(new_id);
        if (!xs) return 0.0;
        set_id = new_id;
    }
    /* xcoord as f64 -> uint32. Range 0..2^25 fits exactly in f64. */
    uint32_t xc = (uint32_t)xcoord_f64;
    uint32_t idx = yon_mphf_index(xc);
    if (idx == YON_MPHF_INVALID) {
        /* non type-2 xcoord -> silently ignore. */
        return set_id;
    }
    uint64_t mask = 1ULL << (idx & 63);
    if (!(xs->bits[idx >> 6] & mask)) {
        xs->bits[idx >> 6] |= mask;
        xs->cache_valid = 0;
    }
    return set_id;
}

double yon_rt_xset_contains(double set_id, double xcoord_f64) {
    ds_xset_t *xs = xset_lookup(set_id);
    if (!xs) return 0.0;
    uint32_t xc = (uint32_t)xcoord_f64;
    uint32_t idx = yon_mphf_index(xc);
    if (idx == YON_MPHF_INVALID) return 0.0;
    uint64_t mask = 1ULL << (idx & 63);
    return (xs->bits[idx >> 6] & mask) ? 1.0 : 0.0;
}

double yon_rt_xset_size(double set_id) {
    ds_xset_t *xs = xset_lookup(set_id);
    if (!xs) return 0.0;
    if (!xs->cache_valid) {
        uint32_t n = 0;
        for (uint32_t i = 0; i < YON_XSET_N_CHUNKS; i++) {
            n += (uint32_t)__builtin_popcountll(xs->bits[i]);
        }
        xs->n_entries = n;
        xs->cache_valid = 1;
    }
    return (double)xs->n_entries;
}

double yon_rt_xset_union(double a_id, double b_id) {
    ds_xset_t *a = xset_lookup(a_id);
    ds_xset_t *b = xset_lookup(b_id);
    if (!a || !b) return 0.0;
    double res_id = yon_rt_xset_empty();
    ds_xset_t *r = xset_lookup(res_id);
    if (!r) return 0.0;
    for (uint32_t i = 0; i < YON_XSET_N_CHUNKS; i++) {
        r->bits[i] = a->bits[i] | b->bits[i];
    }
    r->cache_valid = 0;
    return res_id;
}

double yon_rt_xset_intersect(double a_id, double b_id) {
    ds_xset_t *a = xset_lookup(a_id);
    ds_xset_t *b = xset_lookup(b_id);
    if (!a || !b) return 0.0;
    double res_id = yon_rt_xset_empty();
    ds_xset_t *r = xset_lookup(res_id);
    if (!r) return 0.0;
    for (uint32_t i = 0; i < YON_XSET_N_CHUNKS; i++) {
        r->bits[i] = a->bits[i] & b->bits[i];
    }
    r->cache_valid = 0;
    return res_id;
}

double yon_rt_xset_to_list(double set_id) {
    ds_xset_t *xs = xset_lookup(set_id);
    if (!xs) return yon_rt_list_empty(0.0);
    double list_id = yon_rt_list_empty(0.0);
    for (uint32_t idx = 0; idx < YON_XSET_N_BITS; idx++) {
        uint64_t mask = 1ULL << (idx & 63);
        if (xs->bits[idx >> 6] & mask) {
            uint32_t xc = yon_mphf_unindex(idx);
            list_id = yon_rt_list_cons((double)xc, list_id);
        }
    }
    return list_id;
}

/* ---- Legacy yon_rt_set_* alias (backward-compat per pattern emit) -- */
/* Routing to the new HashSet runtime. The old yon_rt_set_* calls (used by
 * __set_add, __set_contains, __set_size, Set__ etc) are forwarded to the
 * dedicated HashSet. */

double yon_rt_set_empty(void) {
    return yon_rt_hashset_empty();
}

double yon_rt_set_add(double set_id, double elem) {
    return yon_rt_hashset_add(set_id, elem);
}

double yon_rt_set_contains(double set_id, double elem) {
    return yon_rt_hashset_contains(set_id, elem);
}

double yon_rt_set_size(double set_id) {
    return yon_rt_hashset_size(set_id);
}

double yon_rt_set_to_list(double set_id) {
    return yon_rt_hashset_to_list(set_id);
}

/* ---- DAG ------------------------------------------------------ */

typedef struct {
    double label;
    uint32_t child1_slot;
    uint32_t child2_slot;
    uint32_t arity;  /* 0=leaf, 1=unary, 2=binary */
    uint32_t pad;
} ds_merkle_node_t;

/* nodeN multi-arity per S_n canonicalization. */
typedef struct {
    double label;
    uint32_t arity;     /* 3 o 4 */
    uint32_t pad;
    uint32_t children[4];  /* slot indices, up to 4 children */
} ds_merkle_nodeN_t;

/* Sort the n children ascending in place (n=3 or n=4). */
static void sort_children_3(uint32_t a[3]) {
    if (a[0] > a[1]) { uint32_t t = a[0]; a[0] = a[1]; a[1] = t; }
    if (a[1] > a[2]) { uint32_t t = a[1]; a[1] = a[2]; a[2] = t; }
    if (a[0] > a[1]) { uint32_t t = a[0]; a[0] = a[1]; a[1] = t; }
}
static void sort_children_4(uint32_t a[4]) {
    /* insertion sort, 4 elem */
    for (int i = 1; i < 4; i++) {
        uint32_t key = a[i];
        int j = i - 1;
        while (j >= 0 && a[j] > key) { a[j+1] = a[j]; j--; }
        a[j+1] = key;
    }
}

double yon_rt_merkle_leaf(double label) {
    ds_ensure_init();
    ds_merkle_node_t node;
    node.label = label;
    node.child1_slot = 0;
    node.child2_slot = 0;
    node.arity = 0;
    node.pad = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &node, sizeof(node), YON_TAG_USER2);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

double yon_rt_merkle_node2(double label, double child1, double child2) {
    ds_ensure_init();
    /* Order preserved. Correct for the general case and for non-commutative
     * operators: node2(MINUS,a,b) != node2(MINUS,b,a). The commutative quotient
     * (sorting the children) is in the explicit variant
     * merkle_node2_commutative, chosen by the frontend only for known
     * commutative operators (and/or/+). No magic table in the runtime:
     * commutativity is expressed by the choice of function, not by a parameter
     * or a set of hardcoded labels. */
    uint32_t c1 = (uint32_t)child1;
    uint32_t c2 = (uint32_t)child2;
    ds_merkle_node_t node;
    node.label = label;
    node.child1_slot = c1;
    node.child2_slot = c2;
    node.arity = 2;
    node.pad = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &node, sizeof(node), YON_TAG_USER2);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

double yon_rt_merkle_node2_commutative(double label, double child1, double child2) {
    ds_ensure_init();
    /* S_2 commutative quotient: for commutative operators (and/or/+),
     * node2_comm(L, a, b) and node2_comm(L, b, a) produce the same slot
     * (content-address) by ordering the two children before hashing. Exact
     * canonicalization of the S_2 orbit over the 2 positions — zero parameters,
     * a deterministic decision (comparison of the slots). Use only when L is
     * commutative: the frontend guarantees it by construction. */
    uint32_t c1 = (uint32_t)child1;
    uint32_t c2 = (uint32_t)child2;
    ds_merkle_node_t node;
    node.label = label;
    if (c1 <= c2) { node.child1_slot = c1; node.child2_slot = c2; }
    else          { node.child1_slot = c2; node.child2_slot = c1; }
    node.arity = 2;
    node.pad = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &node, sizeof(node), YON_TAG_USER2);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

/* node3 / node4 with S_n canonicalize-by-sort.
 *
 * node3(L, a, b, c) and all 6 of its S_3 permutations produce the same xheap
 * slot (orbit hash under S_3). node4(L, a, b, c, d) likewise for the 24 S_4
 * permutations.
 *
 * A separate XHEAP tag (YON_TAG_USER3) to avoid hash collisions with binary
 * node2. */
double yon_rt_merkle_node3(double label, double c1, double c2, double c3) {
    ds_ensure_init();
    uint32_t ch[3] = {(uint32_t)c1, (uint32_t)c2, (uint32_t)c3};
    sort_children_3(ch);
    ds_merkle_nodeN_t node;
    node.label = label;
    node.arity = 3;
    node.pad = 0;
    node.children[0] = ch[0];
    node.children[1] = ch[1];
    node.children[2] = ch[2];
    node.children[3] = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &node, sizeof(node), YON_TAG_USER3);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

double yon_rt_merkle_node4(double label, double c1, double c2,
                           double c3, double c4) {
    ds_ensure_init();
    uint32_t ch[4] = {(uint32_t)c1, (uint32_t)c2, (uint32_t)c3, (uint32_t)c4};
    sort_children_4(ch);
    ds_merkle_nodeN_t node;
    node.label = label;
    node.arity = 4;
    node.pad = 0;
    node.children[0] = ch[0];
    node.children[1] = ch[1];
    node.children[2] = ch[2];
    node.children[3] = ch[3];
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &node, sizeof(node), YON_TAG_USER3);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

double yon_rt_merkle_label(double node_id) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)node_id;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return -1.0;
    const ds_merkle_node_t *n = (const ds_merkle_node_t *)yon_xheap_slot_payload_any(s);
    if (!n) return -1.0;
    return n->label;
}

double yon_rt_merkle_child(double node_id, double child_idx) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)node_id;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return 0.0;
    const ds_merkle_node_t *n = (const ds_merkle_node_t *)yon_xheap_slot_payload_any(s);
    if (!n) return 0.0;
    int idx = (int)child_idx;
    if (idx == 0) return (double)n->child1_slot;
    if (idx == 1) return (double)n->child2_slot;
    return 0.0;
}

double yon_rt_merkle_equal(double a, double b) {
    /* Content-addressing: two identical DAGs have an identical slot. Deep
     * equality = pointer equality. This is the point of the Merkle tree. */
    return (a == b) ? 1.0 : 0.0;
}

/* ---- Merkle DAG.to_stream --------------------------------------- */
/* Yields the labels of the LEAVES via a left-first DFS. Static iterative stack
 * (max depth = 256). For DAGs with sharing, content-addressing means the same
 * slot is naturally not visited more than once (each slot has a single label,
 * leaf or node). */

#define YON_MERKLE_DFS_MAX 256u

double yon_rt_merkle_to_list(double root_id) {
    ds_ensure_init();
    double list_id = yon_rt_list_empty(0.0);
    if (root_id == 0.0) return list_id;
    /* 2026-06-04: DYNAMIC stack. The old fixed 256-entry array silently
     * dropped children past the bound. The Merkle DAG is acyclic by
     * construction (children are allocated before parents), so the visit
     * terminates; the stack only has to be able to grow. */
    uint32_t cap = YON_MERKLE_DFS_MAX;
    uint32_t *stack = (uint32_t *)malloc(cap * sizeof(uint32_t));
    if (!stack) return list_id;
    int sp = 0;
    stack[sp++] = (uint32_t)root_id;
    while (sp > 0) {
        if ((uint32_t)sp + 2 >= cap) {
            uint32_t nc = cap * 2;
            uint32_t *ns = (uint32_t *)realloc(stack, nc * sizeof(uint32_t));
            if (!ns) break;
            stack = ns; cap = nc;
        }
        uint32_t slot = stack[--sp];
        const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
        if (!s) continue;
        const ds_merkle_node_t *n =
            (const ds_merkle_node_t *)yon_xheap_slot_payload_any(s);
        if (!n) continue;
        if (n->arity == 0) {
            /* Leaf: emit label */
            list_id = yon_rt_list_cons(n->label, list_id);
        } else if (n->arity == 2) {
            /* DFS: push child2 first to visit child1 FIRST (LIFO). */
            stack[sp++] = n->child2_slot;
            stack[sp++] = n->child1_slot;
        }
    }
    free(stack);
    return list_id;
}

/* ============================================================== */
/* S6 — Leech G_24 sign-flip canonicalization */
/* ============================================================== */

extern uint32_t mat24_syndrome(uint32_t v1, uint32_t u_tetrad);

/* yon_rt_leech_sign_canonical: canonicalize a 24-bit sign pattern under the
 * Golay code G_24 orbit, return an xheap slot.
 *
 * Algorithm:
 *   1. mat24_syndrome(s, 0) returns the syndrome of s = the canonical cocode
 *      rep for the equivalence class s + G_24
 *   2. Two sign patterns s1, s2 in the same G_24 orbit (s1 = s2 XOR c for
 *      c in G_24) have the same syndrome
 *   3. Hash (label, syndrome) as the xheap payload
 *
 * Result: orbit hash under (Z/2)^12 sign-flip via G_24. Structural collapse up
 * to 4096x for sign patterns in the same orbit.
 *
 * Parameters:
 *   label: user-defined double tag (to distinguish contexts)
 *   signs_24bit: 24-bit bitmask of the sign pattern (range 0 .. 2^24-1)
 *
 * NB: signs_24bit > 2^24 is masked to 24 bits (the rest is ignored). */
double yon_rt_leech_sign_canonical(double label, double signs_24bit) {
    ds_ensure_init();
    uint32_t s = ((uint32_t)signs_24bit) & 0xFFFFFFu;  /* 24-bit mask */
    uint32_t canonical = mat24_syndrome(s, 0);

    /* Payload struct: (label_f64, canonical_u32, padding_u32 = 0).
     * Content-addressed: same (label, canonical) -> same slot. */
    struct {
        double label;
        uint32_t canonical;
        uint32_t pad;
    } payload;
    payload.label = label;
    payload.canonical = canonical;
    payload.pad = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &payload, sizeof(payload),
                                  YON_TAG_USER1);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

/* Expose the canonical syndrome (debug / verification). */
double yon_rt_leech_syndrome(double signs_24bit) {
    uint32_t s = ((uint32_t)signs_24bit) & 0xFFFFFFu;
    return (double)mat24_syndrome(s, 0);
}

/* orbit_id label-invariant.
 *
 * Differenza da sign_canonical:
 *   sign_canonical(label, signs) -> slot depends on (label, canonical)
 *   orbit_id(signs)              -> slot depends ONLY on canonical
 *
 * All signs in the same G_24 orbit produce the same slot, regardless of the
 * label. Useful as a universal "orbit ID". */
double yon_rt_leech_orbit_id(double signs_24bit) {
    ds_ensure_init();
    uint32_t s = ((uint32_t)signs_24bit) & 0xFFFFFFu;
    uint32_t canonical = mat24_syndrome(s, 0);
    /* Minimal payload: only the canonical syndrome. */
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &canonical, sizeof(canonical),
                                  YON_TAG_USER1);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

/* M_24 Mathieu group orbit canonical.
 *
 * For G_24 codewords, M_24 has 5 distinct orbits distinguishable by the weight
 * of the codeword:
 *   weight 0   -> orbit {0}
 *   weight 8   -> 759 octads (1 M_24 orbit)
 *   weight 12  -> 2576 dodecads (1 M_24 orbit, but split into 2 under M_22 etc.)
 *   weight 16  -> 759 octad complements (1 orbit)
 *   weight 24  -> {all-ones}
 *
 * For vectors not in G_24 (non-zero syndrome), discriminate with (codeword
 * weight gcode_weight, cocode weight cocode_weight).
 *
 * The full Co_0 orbit would require iterating xi; this step is the M_24 base.
 *
 * Algorithm:
 *   1. syndrome = mat24_syndrome(v)
 *   2. gpart = v ^ syndrome  => is a G_24 codeword
 *   3. w_g = gcode_weight(gpart)
 *   4. w_c = cocode_weight(syndrome)
 *   5. canonical = (w_g << 8) | w_c
 *   6. hash the slot of canonical
 *
 * Returns the xheap slot of the orbit ID. */
extern uint32_t mat24_gcode_weight(uint32_t v1);
extern uint32_t mat24_cocode_weight(uint32_t c1);

double yon_rt_leech_m24_orbit(double v_24bit) {
    ds_ensure_init();
    uint32_t v = ((uint32_t)v_24bit) & 0xFFFFFFu;
    uint32_t synd = mat24_syndrome(v, 0);
    uint32_t gpart = v ^ synd;  /* codeword part */
    /* gcode_weight expects a gcode index (0..4095), NOT the vector. To get the
     * gcode from the vector: mat24_vect_to_gcode. But if gpart is a codeword,
     * the weight is simply popcount(gpart). */
    uint32_t w_g = __builtin_popcount(gpart);
    uint32_t w_c = __builtin_popcount(synd);
    uint32_t canonical = (w_g << 8) | w_c;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &canonical, sizeof(canonical),
                                  YON_TAG_USER1);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)slot;
}

/* Expose weight stats for debugging. */
double yon_rt_leech_gcode_weight(double v_24bit) {
    uint32_t v = ((uint32_t)v_24bit) & 0xFFFFFFu;
    uint32_t synd = mat24_syndrome(v, 0);
    uint32_t gpart = v ^ synd;
    return (double)__builtin_popcount(gpart);
}

double yon_rt_leech_cocode_weight(double v_24bit) {
    uint32_t v = ((uint32_t)v_24bit) & 0xFFFFFFu;
    uint32_t synd = mat24_syndrome(v, 0);
    return (double)__builtin_popcount(synd);
}

/* The Conway xi operator.
 *
 * xi has ORDER 3 in Co_0, it is NOT an involution. Conway 1968:
 * Co_0 = <N, xi> where N = (Z/2)^12 : M_24 and xi has order 3.
 *
 * Empirical check:
 *   xi^0(v) = v
 *   xi^1(v) = xi(v)
 *   xi^2(v) = xi(xi(v))  != v in general
 *   xi^3(v) = v          (= identity, order 3)
 *
 * gen_xi_op_xi(v, exp):
 *   v: Leech vector mod 2 in Leech2 format (bits 0-11 cocode, bits 12-23 gcode)
 *   exp: the exponent. exp=1 applies xi, exp=2 applies xi^2, exp=0/3 return v.
 *
 * Yon wrapper: applies xi once (exp=1). */
extern uint32_t gen_xi_op_xi(uint32_t v, uint32_t exp);

double yon_rt_leech_xi_apply(double v_24bit) {
    uint32_t v = ((uint32_t)v_24bit) & 0xFFFFFFu;
    uint32_t v_xi = gen_xi_op_xi(v, 1);
    return (double)v_xi;
}

/* Co_0 canonical step: combines the M_24 orbit + the xi orbit (order 3).
 *
 * Honest: the full Co_0 orbit hash requires closing the <N, xi> orbit
 * iteratively, which is costly (may require ~10^6 iterations in the worst
 * case).
 *
 * This version applies:
 *   1. Compute the M_24 orbit of v, xi(v), xi^2(v)  (three elements of the xi
 *      orbit)
 *   2. Canonical = min(M_24_orbit(v), M_24_orbit(xi v), M_24_orbit(xi^2 v))
 *
 * It captures the equivalence class under the subgroup <xi> . M_24, but not
 * the full Co_0 orbit (which requires iterative closure of N and xi).
 *
 * The full Co_0 orbit would require iteration to convergence with cycle
 * detection. */
double yon_rt_leech_co0_step(double v_24bit) {
    /* Exact Co_0: an alias of yon_rt_leech_co0_canonical_exact (defined in the
     * HSH module). Replaces the old partial version (<xi>.M_24, min-lex of 3
     * elements) that did NOT capture the full Co_0 orbit. Now a closed
     * algebraic reduction via reduce_type2: zero parameters, exact. */
    extern double yon_rt_leech_co0_canonical_exact(double);
    return yon_rt_leech_co0_canonical_exact(v_24bit);
}

/* NOTE (history): a bounded-BFS orbit closure with an open-addressing visited
 * HashSet used to live here. It was REMOVED (see the block below) because it
 * had two real defects: non-standard M_24 generators (#1, #1000, #100000 — in
 * M_24 but not guaranteed to generate it -> wrong, partial quotient) and a 65K
 * visited cap vs the 98,280 type-2 cosets -> truncated orbit, a free
 * parameter. Do not reintroduce: the exact closed-form reduction below
 * supersedes it. BFS enumeration remains the right tool for a DIFFERENT job
 * (enumerating an orbit, e.g. to build a perfect map), where the ground truth
 * is the orbit count theorem: type-2 must count exactly 98,280. */

/* ============================================================
 * Co_0 canonicalization: exact via reduce_type2 (HSH module).
 * The entire bounded-BFS infrastructure was removed:
 *   - co0_bfs_explore (max_iter, a free parameter)
 *   - co0_hash_table/used (the BFS visited set)
 *   - m24_gen1/2/3 (non-standard M_24 generators: # 1,1000,100000, not
 *     guaranteed to generate all of M_24 -> partial orbit)
 *   - co0_init_m24_gens / co0_hashset_clear / co0_hashset_add / co0_queue
 * No heuristic, no parameter: the reduction is closed algebraic.
 * ============================================================ */

double yon_rt_leech_co0_canonical(double v_24bit) {
    /* One-argument signature: the old max_iter parameter (a relic of the
     * removed bounded BFS) is gone everywhere. Exact closed reduction. */
    extern double yon_rt_leech_co0_canonical_exact(double);
    return yon_rt_leech_co0_canonical_exact(v_24bit);
}

double yon_rt_leech_co0_orbit_size(double v_24bit, double max_iter_d) {
    (void)v_24bit; (void)max_iter_d;  /* Deprecated: parametric bounded BFS removed */
    return 0.0;
}

/* same_orbit check.
 *
 * Returns 1.0 if s1 and s2 are in the same G_24 orbit (that is, s1 XOR s2 is a
 * G_24 codeword), 0.0 otherwise.
 *
 * Equivalent to: syndrome(s1) == syndrome(s2). */
double yon_rt_leech_same_orbit(double signs_a, double signs_b) {
    uint32_t a = ((uint32_t)signs_a) & 0xFFFFFFu;
    uint32_t b = ((uint32_t)signs_b) & 0xFFFFFFu;
    if (mat24_syndrome(a, 0) == mat24_syndrome(b, 0)) return 1.0;
    return 0.0;
}

/* ============================================================== */
/* Co_0 transport (Curtis method): explicit group-element certificate.
 *
 * Two type-2 Leech vectors are ALWAYS in the same Co_0 orbit (transitivity).
 * transport(v, w) builds the word sigma in Co_0 with v * sigma == w (mod 2),
 * via reduce_type2 on each (the certificate mmgroup computes) composed as
 * sigma = g_v * g_w^{-1}. The word is stored in a pool; the id is returned.
 * apply(x, id) applies the stored word to x.
 *
 * NOTE: sigma exists for ANY pair of type-2 vectors. It is a witness of a
 * *logical* equivalence only when the Co_0 action is meaningful on the domain
 * (M_24-structured); otherwise it is a (correct but empty) orbit transport. */
#define YON_TRANSPORT_MAX     256u
#define YON_TRANSPORT_WORDLEN  64u
typedef struct {
    uint32_t word[YON_TRANSPORT_WORDLEN];
    uint32_t len;
    uint32_t used;
} ds_transport_t;
static ds_transport_t g_transports[YON_TRANSPORT_MAX];
static uint32_t g_n_transports = 0;

double yon_rt_leech_transport(double v_f64, double w_f64) {
    extern int32_t gen_leech2_reduce_type2(uint32_t, uint32_t *);
    extern uint32_t mm_group_mul_words(uint32_t *, uint32_t, uint32_t *, uint32_t, int32_t);
    if (g_n_transports >= YON_TRANSPORT_MAX) {
        fprintf(stderr, "[YON-RT] leech_transport: pool exhausted\n");
        return 0.0;
    }
    uint32_t v = ((uint32_t)v_f64) & 0xFFFFFFu;
    uint32_t w = ((uint32_t)w_f64) & 0xFFFFFFu;
    uint32_t gv[32], gw[32];
    int32_t lv = gen_leech2_reduce_type2(v, gv);
    int32_t lw = gen_leech2_reduce_type2(w, gw);
    if (lv < 0 || lw < 0) return 0.0;   /* not type-2: no transport */
    uint32_t id = g_n_transports++;
    ds_transport_t *t = &g_transports[id];
    uint32_t ls = mm_group_mul_words(t->word, 0, gv, (uint32_t)lv, 1);   /* sigma = g_v */
    ls = mm_group_mul_words(t->word, ls, gw, (uint32_t)lw, -1);          /* sigma *= g_w^{-1} */
    t->len = ls;
    t->used = 1;
    return (double)(id + 1);
}

double yon_rt_leech_transport_apply(double x_f64, double transport_id_f64) {
    extern uint32_t gen_leech2_op_word_leech2(uint32_t, uint32_t *, uint32_t, uint32_t);
    if (transport_id_f64 < 0.5) return 0.0;
    uint32_t id = (uint32_t)transport_id_f64;
    if (id == 0 || id > g_n_transports) return 0.0;
    ds_transport_t *t = &g_transports[id - 1];
    if (!t->used) return 0.0;
    uint32_t x = ((uint32_t)x_f64) & 0xFFFFFFu;
    uint32_t res = gen_leech2_op_word_leech2(x, t->word, t->len, 0);
    return (double)(res & 0xFFFFFFu);
}

/* ============================================================== */
/* S5 — Phased memory: observe payload via geom_morphism           */
/* ============================================================== */

/* Allocation: a single double in the global xheap (the singleton ds_heap).
 * Content-addressed: the same value -> the same slot.
 *
 * Important: the real slot_index is shifted +1 in the return to distinguish
 * "physical slot 0" from "not allocated" (both would otherwise be 0).
 * observe() decrements -1 before the get. */
double yon_rt_observe_alloc(double value) {
    ds_ensure_init();
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &value, sizeof(double), YON_TAG_FACT);
    if (slot == YON_HEAP_SLOT_INVALID) return 0.0;
    return (double)(slot + 1);
}

/* Observe via geom_morphism: apply the pull (f^*) based on gm_kind.
 * Numeric convention:
 *   0 = identity (no transform)
 *   1 = scale10  (x10)
 *   2 = scale100 (x100)
 *   3 = cents    (/100)
 *   4 = negate (-x)
 *   5 = double (x2)
 *
 * Honest: this is a demo. Arbitrary pulls require function pointers registered
 * in the runtime (future). */
double yon_rt_observe(double slot_id_f64,
                       double gm_kind,
                       double default_val) {
    ds_ensure_init();
    uint32_t shifted = (uint32_t)slot_id_f64;
    if (shifted == 0) return default_val;  /* slot=0 reserved = "not allocated" */
    uint32_t slot = shifted - 1;  /* unshift */
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return default_val;
    const double *raw = (const double *)yon_xheap_slot_payload_any(s);
    if (!raw) return default_val;
    double v = *raw;
    int kind = (int)gm_kind;
    switch (kind) {
        case 1: return v * 10.0;
        case 2: return v * 100.0;
        case 3: return v / 100.0;
        case 4: return -v;
        case 5: return v * 2.0;
        case 0:
        default: return v;
    }
}

/* Diagnostic: occupancy of the global xheap (to show that the physical payload
 * is unique despite multiple observers). */
uint32_t yon_rt_xheap_used(void) {
    ds_ensure_init();
    /* Approximate count via a scan of the first 1000 slots. Slot indices start
     * from 0 (no shift like observe_alloc, which returns slot+1 for the
     * external API). */
    uint32_t count = 0;
    for (uint32_t i = 0; i < 1000 && i < YON_HEAP_N_SLOTS; i++) {
        if (yon_xheap_is_occupied(g_ds_heap, i)) count++;
    }
    return count;
}

/* ============================================================== */
/* spawn — multi-process via fork()                                */
/* ============================================================== */

#include <sys/wait.h>
#include <unistd.h>

double yon_rt_spawn_self(double n_replicas_f64) {
    int n = (int)n_replicas_f64;
    if (n <= 0) return 0.0;
    if (n > 256) {
        fprintf(stderr, "[YON-RT spawn] n=%d exceeds max 256, clamping\n", n);
        n = 256;
    }
    pid_t pids[256];
    int spawned = 0;
    for (int i = 0; i < n; i++) {
        /* Set spawn_index BEFORE fork so child inherits it */
        char idx_str[16];
        snprintf(idx_str, sizeof(idx_str), "%d", i);
        setenv("YON_SPAWN_INDEX", idx_str, 1);
        pid_t pid = fork();
        if (pid < 0) {
            perror("[YON-RT spawn] fork failed");
            break;
        } else if (pid == 0) {
            /* Child: return immediately, exit with 0 after Yon main finishes */
            /* The child re-runs everything from main() onwards via Yon? No.
             * In our pragmatic model: child returns 1.0 from spawn_self,
             * parent returns 0.0 (after wait). Caller in Yon dispatches. */
            return 1.0;  /* "I am a child" */
        } else {
            pids[spawned++] = pid;
        }
    }
    /* Parent: unset env var, wait for all children */
    unsetenv("YON_SPAWN_INDEX");
    int completed = 0;
    for (int i = 0; i < spawned; i++) {
        int status = 0;
        if (waitpid(pids[i], &status, 0) > 0) {
            if (WIFEXITED(status)) completed++;
        }
    }
    fprintf(stderr, "[YON-RT spawn] parent: %d/%d children completed\n",
            completed, spawned);
    return 0.0;  /* "I am the parent" */
}

double yon_rt_spawn_index(void) {
    const char *idx_str = getenv("YON_SPAWN_INDEX");
    if (!idx_str) return -1.0;
    return (double)atoi(idx_str);
}

/* ============================================================== */
/* S6 — Voyager Seal: Codice Golay (24,12,8)                       */
/* ============================================================== */

#include "mat24_functions.h"

double yon_rt_voyagerlist_seal(double data12_f64) {
    uint32_t data = (uint32_t)data12_f64;
    if (data >= 4096) {
        /* Clip to 12 bit */
        data &= 0xFFF;
    }
    uint32_t codeword = mat24_gcode_to_vect(data);
    return (double)codeword;
}

double yon_rt_voyagerlist_open(double codeword24_f64) {
    uint32_t codeword = (uint32_t)codeword24_f64;
    /* Syndrome decoding: find the error pattern */
    uint32_t syndrome = mat24_syndrome(codeword, 24);
    /* Apply syndrome to recover the original codeword */
    uint32_t corrected = codeword ^ syndrome;
    /* Now decode 24-bit corrected -> 12-bit gcode */
    uint32_t gcode = mat24_vect_to_gcode(corrected);
    return (double)gcode;
}

double yon_rt_voyagerlist_corrupt(double codeword24_f64, double n_bits_f64) {
    uint32_t codeword = (uint32_t)codeword24_f64;
    int n_bits = (int)n_bits_f64;
    if (n_bits < 0) n_bits = 0;
    if (n_bits > 24) n_bits = 24;
    /* Pseudo-random bit flips using the codeword itself as seed */
    uint32_t flip_mask = 0;
    uint32_t state = codeword * 2654435761u + 1u;  /* simple LCG */
    for (int i = 0; i < n_bits; i++) {
        int attempts = 0;
        while (attempts < 100) {
            state = state * 1103515245u + 12345u;
            int bit_pos = state % 24;
            uint32_t bit = 1u << bit_pos;
            if (!(flip_mask & bit)) {
                flip_mask |= bit;
                break;
            }
            attempts++;
        }
    }
    return (double)(codeword ^ flip_mask);
}

/* ============================================================== */
/* VoyagerList come COLLEZIONE               */
/* ============================================================== */
/* The earlier rename was only cosmetic (seal/open/corrupt stayed pure
 * functions, no collection). This makes VoyagerList an actual *list* of sealed
 * codewords.
 *
 * Design:
 * - Pool max 256 VoyagerList concorrenti
 * - Each VL = array of 24-bit codewords (uint32_t), fixed capacity 1024
 * - append(vl, data12): auto-seal (data12 -> codeword24) before the store
 * - get(vl, idx): auto-open (codeword24 -> data12 with error correction)
 * - to_stream(vl): yields data12 of all elements (open each)
 *
 * Le 3 builtin esistenti (yon_rt_voyagerlist_seal/open/corrupt) restano
 * come funzioni pure utility per backward-compat. */

/* 2026-06-04: DYNAMIC capacity, doubling via realloc, no cap
 * (limit = memory; guard on arithmetic overflow only). */
#define YON_VL_MAX_LISTS  256u
#define YON_VL_INIT       1024u

typedef struct {
    uint32_t *codewords;   /* 24-bit codeword in basso; cresce lazy */
    uint32_t cap;
    uint32_t n_entries;
    uint32_t is_used;
} ds_voyagerlist_t;

static ds_voyagerlist_t g_voyagerlists[YON_VL_MAX_LISTS];
static uint32_t g_n_voyagerlists = 0;

double yon_rt_voyagerlist_empty(void) {
    if (g_n_voyagerlists >= YON_VL_MAX_LISTS) {
        fprintf(stderr, "[YON-RT] voyagerlist_empty: pool exhausted\n");
        return 0.0;
    }
    uint32_t id = g_n_voyagerlists++;
    ds_voyagerlist_t *vl = &g_voyagerlists[id];
    vl->cap = YON_VL_INIT;
    vl->codewords = (uint32_t *)malloc(vl->cap * sizeof(uint32_t));
    if (!vl->codewords) {
        fprintf(stderr, "[YON-RT] voyagerlist_empty: out of memory\n");
        g_n_voyagerlists--;
        return 0.0;
    }
    vl->n_entries = 0;
    vl->is_used = 1;
    return (double)(id + 1);  /* shift +1 per evitare collisione con 0 */
}

static ds_voyagerlist_t *voyagerlist_lookup(double vl_id) {
    if (vl_id < 0.5) return NULL;
    uint32_t shifted = (uint32_t)vl_id;
    if (shifted == 0 || shifted > g_n_voyagerlists) return NULL;
    ds_voyagerlist_t *vl = &g_voyagerlists[shifted - 1];
    if (!vl->is_used) return NULL;
    return vl;
}

double yon_rt_voyagerlist_append(double vl_id, double data12_f64) {
    /* Lazy init: if vl_id == 0, allocate a new VL. */
    ds_voyagerlist_t *vl = (vl_id < 0.5) ? NULL : voyagerlist_lookup(vl_id);
    if (!vl) {
        double new_id = yon_rt_voyagerlist_empty();
        vl = voyagerlist_lookup(new_id);
        if (!vl) return 0.0;
        vl_id = new_id;
    }
    if (vl->n_entries >= vl->cap) {
        uint32_t new_cap = vl->cap * 2;
        if (new_cap <= vl->cap) {
            fprintf(stderr, "[YON-RT] voyagerlist_append: capacity overflow\n");
            return vl_id;
        }
        uint32_t *nc = (uint32_t *)realloc(vl->codewords,
                                           new_cap * sizeof(uint32_t));
        if (!nc) {
            fprintf(stderr, "[YON-RT] voyagerlist_append: out of memory\n");
            return vl_id;
        }
        vl->codewords = nc;
        vl->cap = new_cap;
    }
    /* Auto-seal: data12 -> codeword24 Golay */
    uint32_t data = (uint32_t)data12_f64;
    if (data >= 4096) data &= 0xFFF;
    uint32_t codeword = mat24_gcode_to_vect(data);
    vl->codewords[vl->n_entries++] = codeword;
    return vl_id;
}

double yon_rt_voyagerlist_get(double vl_id, double idx_f64) {
    ds_voyagerlist_t *vl = voyagerlist_lookup(vl_id);
    if (!vl) return 0.0;
    uint32_t idx = (uint32_t)idx_f64;
    if (idx >= vl->n_entries) {
        fprintf(stderr, "[YON-RT] voyagerlist_get: idx %u out of range (%u)\n",
                idx, vl->n_entries);
        return 0.0;
    }
    /* Auto-open: codeword24 -> data12 with error correction. */
    uint32_t codeword = vl->codewords[idx];
    uint32_t syndrome = mat24_syndrome(codeword, 24);
    uint32_t corrected = codeword ^ syndrome;
    uint32_t gcode = mat24_vect_to_gcode(corrected);
    return (double)gcode;
}

double yon_rt_voyagerlist_size(double vl_id) {
    ds_voyagerlist_t *vl = voyagerlist_lookup(vl_id);
    if (!vl) return 0.0;
    return (double)vl->n_entries;
}

/* corrupt al codeword di indice idx (test helper, in-place). */
double yon_rt_voyagerlist_corrupt_at(double vl_id, double idx_f64, double n_bits_f64) {
    ds_voyagerlist_t *vl = voyagerlist_lookup(vl_id);
    if (!vl) return vl_id;
    uint32_t idx = (uint32_t)idx_f64;
    if (idx >= vl->n_entries) return vl_id;
    /* Reuse yon_rt_voyagerlist_corrupt, which works on a single codeword. */
    double cw_f = (double)vl->codewords[idx];
    double corrupted = yon_rt_voyagerlist_corrupt(cw_f, n_bits_f64);
    vl->codewords[idx] = (uint32_t)corrupted;
    return vl_id;
}

/* to_stream: yields the original data12 of each codeword (open each). */
double yon_rt_voyagerlist_to_list(double vl_id) {
    ds_voyagerlist_t *vl = voyagerlist_lookup(vl_id);
    if (!vl) return yon_rt_list_empty(0.0);
    double list_id = yon_rt_list_empty(0.0);
    /* Iterate in reverse to get the list in chronological order (cons
     * accumulates head-first, so reverse iteration = append order). */
    for (int32_t i = (int32_t)vl->n_entries - 1; i >= 0; i--) {
        uint32_t codeword = vl->codewords[i];
        uint32_t syndrome = mat24_syndrome(codeword, 24);
        uint32_t corrected = codeword ^ syndrome;
        uint32_t gcode = mat24_vect_to_gcode(corrected);
        list_id = yon_rt_list_cons((double)gcode, list_id);
    }
    return list_id;
}

/* ============================================================== */
/* Immutable list (cons-list) over yon_xheap content-addressed       */
/* ============================================================== */

/* Cons cell payload: fixed 16 bytes.
 * - value:     the double value of the head (8 bytes)
 * - tail_slot: the slot_index of the tail (4 bytes). YON_HEAP_SLOT_INVALID
 *              indicates an empty list (the chain terminator).
 * - sentinel:  magic 0xC0NSCELL to disambiguate non-list slots that happen to
 *              have the same content layout. */
#define YON_LIST_SENTINEL 0xC0145CE1u

#pragma pack(push, 1)
typedef struct {
    double   value;
    uint32_t tail_slot;
    uint32_t sentinel;
} yon_list_cell_t;
#pragma pack(pop)

_Static_assert(sizeof(yon_list_cell_t) == 16,
               "yon_list_cell_t must be exactly 16 bytes");

double yon_rt_list_empty(double dummy) {
    (void)dummy;
    return YON_RT_LIST_EMPTY;
}

double yon_rt_list_cons(double value, double tail_id) {
    ensure_init();
    uint32_t tail_slot;
    if (tail_id == YON_RT_LIST_EMPTY ||
        (uint32_t)tail_id == YON_HEAP_SLOT_INVALID) {
        tail_slot = YON_HEAP_SLOT_INVALID;
    } else {
        tail_slot = (uint32_t)tail_id;
    }
    yon_list_cell_t cell;
    cell.value     = value;
    cell.tail_slot = tail_slot;
    cell.sentinel  = YON_LIST_SENTINEL;
    uint32_t slot = yon_xheap_put_chain(g_yon_heap, &cell, sizeof(cell),
                                   YON_TAG_USER1);
    if (slot == YON_HEAP_SLOT_INVALID) {
        fprintf(stderr, "[YON-RT] list_cons: xheap full\n");
        return YON_RT_LIST_EMPTY;
    }
    return (double)slot;
}

/* Internal read: given a list_id (slot_index), retrieves the cons cell.
 * Returns NULL if: id is empty, slot invalid, or sentinel does not match. */
static const yon_list_cell_t *list_cell_at(double list_id) {
    if (list_id == YON_RT_LIST_EMPTY) return NULL;
    uint32_t slot = (uint32_t)list_id;
    if (slot == YON_HEAP_SLOT_INVALID) return NULL;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s || s->payload_size != sizeof(yon_list_cell_t)) return NULL;
    const yon_list_cell_t *cell =
        (const yon_list_cell_t *)yon_xheap_slot_payload_any(s);
    if (!cell || cell->sentinel != YON_LIST_SENTINEL) return NULL;
    return cell;
}

double yon_rt_list_head(double list_id) {
    ensure_init();
    const yon_list_cell_t *cell = list_cell_at(list_id);
    if (!cell) return 0.0;
    return cell->value;
}

double yon_rt_list_tail(double list_id) {
    ensure_init();
    const yon_list_cell_t *cell = list_cell_at(list_id);
    if (!cell) return YON_RT_LIST_EMPTY;
    if (cell->tail_slot == YON_HEAP_SLOT_INVALID) return YON_RT_LIST_EMPTY;
    return (double)cell->tail_slot;
}

double yon_rt_list_length(double list_id) {
    ensure_init();
    double cur = list_id;
    uint32_t n = 0;
    /* Bound: max 196560 iterations (one cell per slot, no cycles possible
     * because content-addressing builds a DAG). */
    for (uint32_t safety = 0; safety < YON_HEAP_N_SLOTS; safety++) {
        const yon_list_cell_t *cell = list_cell_at(cur);
        if (!cell) break;
        n++;
        if (cell->tail_slot == YON_HEAP_SLOT_INVALID) break;
        cur = (double)cell->tail_slot;
    }
    return (double)n;
}

/* ============================================================== */
/* Space cell mutabile (array statico in BSS)                       */
/* ============================================================== */

static struct {
    double   value;
    uint32_t in_use;
} g_space_cells[YON_RT_MAX_SPACE_CELLS];

static uint32_t g_n_space_cells = 0;

double yon_rt_space_make(double initial) {
    if (g_n_space_cells >= YON_RT_MAX_SPACE_CELLS) {
        fprintf(stderr, "[YON-RT] space_make: registry pieno (max %u)\n",
                (unsigned)YON_RT_MAX_SPACE_CELLS);
        return -1.0;
    }
    uint32_t id = g_n_space_cells++;
    g_space_cells[id].value  = initial;
    g_space_cells[id].in_use = 1;
    return (double)id;
}

double yon_rt_space_set(double space_id, double new_value) {
    uint32_t id = (uint32_t)space_id;
    if (id >= g_n_space_cells || !g_space_cells[id].in_use) {
        fprintf(stderr, "[YON-RT] space_set: id=%u invalido (n=%u)\n",
                id, g_n_space_cells);
        return -1.0;
    }
    g_space_cells[id].value = new_value;
    return space_id;
}

double yon_rt_space_get(double space_id) {
    uint32_t id = (uint32_t)space_id;
    if (id >= g_n_space_cells || !g_space_cells[id].in_use) {
        fprintf(stderr, "[YON-RT] space_get: id=%u invalido (n=%u)\n",
                id, g_n_space_cells);
        return 0.0;
    }
    return g_space_cells[id].value;
}

/* ============================================================== */
/* S7 — LockedRing: capability tokens via the Co_0 group           */
/* ============================================================== */

/* Extern from the libmmgroup libraries (already linked via libmmgroup_mat24.so) */
extern uint32_t gen_leech2_op_word(uint32_t q0, uint32_t *g, uint32_t n);
extern uint32_t gen_leech2_op_word_leech2(uint32_t l, uint32_t *g,
                                           uint32_t n, uint32_t back);
extern uint32_t gen_leech2_subtype(uint64_t v2);
extern void mm_group_invert_word(uint32_t *w, uint32_t l);

/* Extern MPHF from our xleech2 library */
extern uint32_t yon_mphf_index(uint32_t v);
extern uint32_t yon_mphf_unindex(uint32_t idx);

/* Monster generator tags used for the Co_0 action on Leech.
 * Co_0 is generated by {d, p, x, y, l}. We exclude 't' (specific to the
 * Monster, outside Co_0). */
#define MMGRP_TAG_D 0x10000000UL  /* Parker loop diagonal */
#define MMGRP_TAG_P 0x20000000UL  /* M24 permutation     */
#define MMGRP_TAG_X 0x30000000UL  /* Leech* translation  */
#define MMGRP_TAG_Y 0x40000000UL  /* Y-generator         */
#define MMGRP_TAG_L 0x60000000UL  /* Conway's xi         */
#define MMGRP_SIGN_INV 0x80000000UL  /* inverse marker    */

/* Sentinel per "key invalida". */
#define YON_RT_LOCKEDRING_KEY_INVALID ((double)-1.0)

/* Deterministic LCG (Numerical Recipes) for expanding seed -> key atoms.
 * Same seed -> same sequence -> same key (content-addressed
 * dedup naturale nel xheap). */
static uint32_t lcg_next(uint32_t *state) {
    *state = (*state) * 1664525u + 1013904223u;
    return *state;
}

/* Generate a random but valid Co_0 atom. Tag weighted uniformly among
 * {d, p, x, y, l}, value adapted to the tag's range to avoid out-of-domain.
 * Bit 31 sign (forward/inverse) random. */
static uint32_t gen_random_co0_atom(uint32_t *lcg_state) {
    uint32_t r = lcg_next(lcg_state);
    uint32_t tag_choice = (r >> 24) % 5u;
    uint32_t sign = (r & 0x1u) ? MMGRP_SIGN_INV : 0u;
    uint32_t value = lcg_next(lcg_state);
    uint32_t tag, val;
    switch (tag_choice) {
        case 0:  /* d: Parker loop, value ∈ [0, 2^13) */
            tag = MMGRP_TAG_D;
            val = value & 0x1FFFu;
            break;
        case 1:  /* p: M24 permutation, value ∈ [0, 244823040) */
            tag = MMGRP_TAG_P;
            val = value % 244823040u;
            break;
        case 2:  /* x: Leech^* translation, value ∈ [0, 2^24) */
            tag = MMGRP_TAG_X;
            val = value & 0xFFFFFFu;
            break;
        case 3:  /* y: y-generator, value ∈ [0, 2^24) */
            tag = MMGRP_TAG_Y;
            val = value & 0xFFFFFFu;
            break;
        default: /* l: Conway's xi, value ∈ {0, 1, 2} */
            tag = MMGRP_TAG_L;
            val = value % 3u;
            break;
    }
    return sign | tag | val;
}

/* Layout payload di una key in xheap: array di N=8 atom (32 byte fissi). */
#pragma pack(push, 1)
typedef struct {
    uint32_t atoms[YON_RT_LOCKEDRING_KEY_ATOMS];
} yon_lockedring_key_t;
#pragma pack(pop)

_Static_assert(sizeof(yon_lockedring_key_t) ==
               YON_RT_LOCKEDRING_KEY_ATOMS * sizeof(uint32_t),
               "yon_lockedring_key_t must be exactly N*4 bytes");

double yon_rt_conway_gen_key(double seed) {
    ensure_init();
    uint32_t lcg = (uint32_t)seed;
    /* Initial mix to avoid small seeds that produce weak keys */
    lcg = lcg * 2654435769u + 0x9E3779B9u;
    yon_lockedring_key_t key;
    for (int i = 0; i < YON_RT_LOCKEDRING_KEY_ATOMS; i++) {
        key.atoms[i] = gen_random_co0_atom(&lcg);
    }
    uint32_t slot = yon_xheap_put_chain(g_yon_heap, &key, sizeof(key),
                                   YON_TAG_USER2);
    if (slot == YON_HEAP_SLOT_INVALID) {
        fprintf(stderr, "[YON-RT] conway_gen_key: xheap full\n");
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    return (double)slot;
}

/* Internal read: load the key from the xheap, return a pointer to the payload
 * (lifetime guaranteed by the content-addressed xheap, never compacted). */
static const yon_lockedring_key_t *load_key(double key_id) {
    if (key_id == YON_RT_LOCKEDRING_KEY_INVALID) return NULL;
    uint32_t slot = (uint32_t)key_id;
    if (slot == YON_HEAP_SLOT_INVALID) return NULL;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s || s->payload_size != sizeof(yon_lockedring_key_t)) return NULL;
    return (const yon_lockedring_key_t *)
        yon_xheap_slot_payload_any(s);
}

double yon_rt_conway_seal_slot(double slot_id_f64, double key_id) {
    ensure_init();
    const yon_lockedring_key_t *key = load_key(key_id);
    if (!key) {
        fprintf(stderr, "[YON-RT] conway_seal_slot: key invalida\n");
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    uint32_t slot_idx = (uint32_t)slot_id_f64;
    if (slot_idx >= 196560u) {
        fprintf(stderr, "[YON-RT] conway_seal_slot: slot_idx %u fuori range Leech type-2\n",
                slot_idx);
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    /* slot_idx -> type-2 xcoord via MPHF */
    uint32_t xcoord = yon_mphf_unindex(slot_idx);
    if (xcoord == 0xFFFFFFFFu) {
        fprintf(stderr, "[YON-RT] conway_seal_slot: MPHF unindex fallita\n");
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    /* Co_0 action: copy atoms into a mutable buffer (the function might modify
     * them, although in practice gen_leech2_op_word does not). */
    uint32_t atoms[YON_RT_LOCKEDRING_KEY_ATOMS];
    memcpy(atoms, key->atoms, sizeof(atoms));
    uint32_t sealed_xcoord = gen_leech2_op_word(xcoord, atoms,
                                                 YON_RT_LOCKEDRING_KEY_ATOMS);
    /* Verify that the sealed value stays type-2 (Co_0 preserves the type) */
    if (gen_leech2_subtype((uint64_t)sealed_xcoord) >> 4 != 2u) {
        fprintf(stderr, "[YON-RT] conway_seal_slot: sealed non-type-2 (subtype=%u)\n",
                gen_leech2_subtype((uint64_t)sealed_xcoord));
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    /* xcoord -> slot_idx via inverse MPHF */
    uint32_t sealed_idx = yon_mphf_index(sealed_xcoord);
    if (sealed_idx == 0xFFFFFFFFu) {
        fprintf(stderr, "[YON-RT] conway_seal_slot: MPHF index fallita\n");
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    return (double)sealed_idx;
}

double yon_rt_conway_unseal_slot(double sealed_id_f64, double key_id) {
    ensure_init();
    const yon_lockedring_key_t *key = load_key(key_id);
    if (!key) {
        fprintf(stderr, "[YON-RT] conway_unseal_slot: key invalida\n");
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    uint32_t sealed_idx = (uint32_t)sealed_id_f64;
    if (sealed_idx >= 196560u) {
        fprintf(stderr, "[YON-RT] conway_unseal_slot: sealed_idx %u fuori range\n",
                sealed_idx);
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    uint32_t sealed_xcoord = yon_mphf_unindex(sealed_idx);
    if (sealed_xcoord == 0xFFFFFFFFu) {
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    /* Apply the inverse Co_0 action: back=1 in gen_leech2_op_word_leech2.
     * NB: in libmmgroup, "back=1" inverts the word. Safe alternative path:
     * manual invert + forward. We use the manual invert for clarity. */
    uint32_t atoms[YON_RT_LOCKEDRING_KEY_ATOMS];
    memcpy(atoms, key->atoms, sizeof(atoms));
    mm_group_invert_word(atoms, YON_RT_LOCKEDRING_KEY_ATOMS);
    uint32_t unsealed_xcoord = gen_leech2_op_word(sealed_xcoord, atoms,
                                                    YON_RT_LOCKEDRING_KEY_ATOMS);
    if (gen_leech2_subtype((uint64_t)unsealed_xcoord) >> 4 != 2u) {
        fprintf(stderr, "[YON-RT] conway_unseal_slot: unsealed non-type-2\n");
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    uint32_t unsealed_idx = yon_mphf_index(unsealed_xcoord);
    if (unsealed_idx == 0xFFFFFFFFu) {
        return YON_RT_LOCKEDRING_KEY_INVALID;
    }
    return (double)unsealed_idx;
}

double yon_rt_conway_key_equal(double key_a, double key_b) {
    /* The xheap content-addressing guarantees: keys with the same atoms
     * collapse to the same slot. So equality = identity of the slot_index. */
    if (key_a == YON_RT_LOCKEDRING_KEY_INVALID ||
        key_b == YON_RT_LOCKEDRING_KEY_INVALID) {
        return 0.0;
    }
    return (key_a == key_b) ? 1.0 : 0.0;
}

/* ============================================================== */
/* Capability registry */
/* ============================================================== */

/* Runtime registry of capability tokens.
 * Honest: does NOT enforce compile-time flow analysis. Runtime check only.
 * Production would have: a type system extension + flow inference.
 *
 * API:
 *   yon_rt_cap_grant(name_hash) -> token_id (registers in the registry)
 *   yon_rt_cap_check(name_hash) -> 1.0 if present, 0.0 otherwise
 *   yon_rt_cap_revoke(name_hash) -> 0.0 success
 *
 * Implementation: a fixed array of 256 entries. Hash via the string.
 * Cap: 256 distinct runtime capabilities. */

#define YON_CAP_REGISTRY_CAP 256
static uint32_t cap_registry_hashes[YON_CAP_REGISTRY_CAP];
static uint8_t  cap_registry_used[YON_CAP_REGISTRY_CAP];

double yon_rt_cap_grant(double name_hash_d) {
    uint32_t h = (uint32_t)name_hash_d;
    for (uint32_t i = 0; i < YON_CAP_REGISTRY_CAP; i++) {
        if (!cap_registry_used[i]) {
            cap_registry_hashes[i] = h;
            cap_registry_used[i] = 1;
            return (double)i;
        }
        if (cap_registry_hashes[i] == h) return (double)i;
    }
    return -1.0; /* registry full */
}

double yon_rt_cap_check(double name_hash_d) {
    uint32_t h = (uint32_t)name_hash_d;
    for (uint32_t i = 0; i < YON_CAP_REGISTRY_CAP; i++) {
        if (cap_registry_used[i] && cap_registry_hashes[i] == h) return 1.0;
    }
    return 0.0;
}

double yon_rt_cap_revoke(double name_hash_d) {
    uint32_t h = (uint32_t)name_hash_d;
    for (uint32_t i = 0; i < YON_CAP_REGISTRY_CAP; i++) {
        if (cap_registry_used[i] && cap_registry_hashes[i] == h) {
            cap_registry_used[i] = 0;
            return 0.0;
        }
    }
    return -1.0;
}

/* ============================================================== */
/* Online schema evolution */
/* ============================================================== */

/* Runtime registry of versioned move declarations.
 * Honest: no dynamic re-tycheck, only version storage.
 * Production would have: a runtime loader + re-tycheck + migration.
 *
 * API:
 *   yon_rt_move_register_version(name_hash, version) -> 0 success
 *   yon_rt_move_current_version(name_hash) -> the current version or -1
 *
 * Use case: clients declare "move m1 version 2" at runtime; the runtime keeps
 * track of the most recent version. */

#define YON_MOVE_REGISTRY_CAP 128
static uint32_t move_registry_hashes[YON_MOVE_REGISTRY_CAP];
static uint32_t move_registry_versions[YON_MOVE_REGISTRY_CAP];
static uint8_t  move_registry_used[YON_MOVE_REGISTRY_CAP];

double yon_rt_move_register_version(double name_hash_d, double version_d) {
    uint32_t h = (uint32_t)name_hash_d;
    uint32_t v = (uint32_t)version_d;
    for (uint32_t i = 0; i < YON_MOVE_REGISTRY_CAP; i++) {
        if (move_registry_used[i] && move_registry_hashes[i] == h) {
            /* Update version (last-wins) */
            move_registry_versions[i] = v;
            return 0.0;
        }
    }
    for (uint32_t i = 0; i < YON_MOVE_REGISTRY_CAP; i++) {
        if (!move_registry_used[i]) {
            move_registry_hashes[i] = h;
            move_registry_versions[i] = v;
            move_registry_used[i] = 1;
            return 0.0;
        }
    }
    return -1.0; /* registry full */
}

double yon_rt_move_current_version(double name_hash_d) {
    uint32_t h = (uint32_t)name_hash_d;
    for (uint32_t i = 0; i < YON_MOVE_REGISTRY_CAP; i++) {
        if (move_registry_used[i] && move_registry_hashes[i] == h) {
            return (double)move_registry_versions[i];
        }
    }
    return -1.0;
}

/* ============================================================== */
/* Stdlib base                       */
/* ============================================================== */

#include <math.h>
#include <string.h>
#include <stdio.h>

/* Math */
double yon_rt_math_sqrt(double x)  { return sqrt(x); }
double yon_rt_math_abs(double x)   { return fabs(x); }
double yon_rt_math_floor(double x) { return floor(x); }
double yon_rt_math_ceil(double x)  { return ceil(x); }
double yon_rt_math_round(double x) { return round(x); }
double yon_rt_math_min(double a, double b) { return a < b ? a : b; }
double yon_rt_math_max(double a, double b) { return a > b ? a : b; }
double yon_rt_math_pow(double a, double b) { return pow(a, b); }
double yon_rt_math_log(double x)   { return log(x); }
double yon_rt_math_exp(double x)   { return exp(x); }
double yon_rt_math_sin(double x)   { return sin(x); }
double yon_rt_math_cos(double x)   { return cos(x); }
double yon_rt_math_pi(void)        { return 3.14159265358979323846; }
double yon_rt_math_e(void)         { return 2.71828182845904523536; }
/* Math.modulo (a mod b) e Math.gcd (Euclidean). */
double yon_rt_math_modulo(double a, double b) {
    if (b == 0.0) return 0.0;
    double q = floor(a / b);
    return a - q * b;
}
double yon_rt_math_gcd(double a_d, double b_d) {
    /* GCD su interi positivi via Euclidean (lavora su int64 per range) */
    int64_t a = (int64_t)fabs(a_d);
    int64_t b = (int64_t)fabs(b_d);
    while (b != 0) {
        int64_t t = b;
        b = a % b;
        a = t;
    }
    return (double)a;
}

/* Bits (24-bit context typical for Co_0) */
double yon_rt_bits_and(double a, double b) {
    return (double)((uint32_t)a & (uint32_t)b);
}
double yon_rt_bits_or(double a, double b) {
    return (double)((uint32_t)a | (uint32_t)b);
}
double yon_rt_bits_xor(double a, double b) {
    return (double)((uint32_t)a ^ (uint32_t)b);
}
double yon_rt_bits_not(double a) {
    /* mask a 24-bit (Co_0 context) */
    return (double)((~(uint32_t)a) & 0xFFFFFFu);
}
double yon_rt_bits_shl(double a, double n) {
    return (double)(((uint32_t)a) << ((uint32_t)n & 0x1Fu));
}
double yon_rt_bits_shr(double a, double n) {
    return (double)(((uint32_t)a) >> ((uint32_t)n & 0x1Fu));
}
double yon_rt_bits_popcount(double a) {
    return (double)__builtin_popcount((uint32_t)a);
}

/* IO (debug) */
double yon_rt_io_print_num(double x) {
    printf("%g\n", x);
    return 0.0;
}

/* ============================================================== */
/* SCT integration in the HashMap / HashSet data structures        */
/* ============================================================== */

/* HashMap.orbital_set / orbital_get:
 * Canonicalize the key via the G_24 syndrome BEFORE the lookup/insert.
 * Effect: two keys differing by a G_24 codeword -> the same entry.
 * Use case: SAT clause dedup, Ising config index, etc.
 *
 * Honest: hardcoded G_24 syndrome. Other canonicalizers would need an API with
 * a function pointer (future scope).
 *
 * Note: the key in the xheap entry is the canonical syndrome, not the original
 * key. Both get/set must canonicalize -> consistency guaranteed. */

double yon_rt_hashmap_orbital_set(double map_id, double key, double value) {
    uint32_t k = ((uint32_t)key) & 0xFFFFFFu;
    uint32_t canonical = mat24_syndrome(k, 0);
    return yon_rt_map_put(map_id, (double)canonical, value);
}

double yon_rt_hashmap_orbital_get(double map_id, double key) {
    uint32_t k = ((uint32_t)key) & 0xFFFFFFu;
    uint32_t canonical = mat24_syndrome(k, 0);
    return yon_rt_map_get(map_id, (double)canonical);
}

/* HashSet.orbital_add:
 * Canonicalize elem via the G_24 syndrome before add.
 * Effect: two elems in the same G_24 orbit -> 1 HashSet entry. */

double yon_rt_hashset_orbital_add(double set_id, double elem) {
    uint32_t e = ((uint32_t)elem) & 0xFFFFFFu;
    uint32_t canonical = mat24_syndrome(e, 0);
    return yon_rt_hashset_add(set_id, (double)canonical);
}

double yon_rt_hashset_orbital_contains(double set_id, double elem) {
    uint32_t e = ((uint32_t)elem) & 0xFFFFFFu;
    uint32_t canonical = mat24_syndrome(e, 0);
    return yon_rt_hashset_contains(set_id, (double)canonical);
}

/* ============================================================== */
/* Cluster A esteso:                 */
/* HashMap.orbital pluggable canonicalizer + XSet/Space/Merkle orbital */
/* ============================================================== */

/* Canonicalizer ID:
 *   0 = identity (no canonicalize, equivale a yon_rt_map_put)
 *   1 = G_24 syndrome (default)
 *   2 = M_24 orbit weight (gcode_weight di mat24)
 *   3 = Co_0 step canonical (one-shot ξ application)
 *   4 = Co_0 BFS canonical (transitivo, max 32 iter for speed)
 *   5 = popcount (orbit by Hamming weight)
 *   6 = mod_8 (mod-8 representative)
 *
 * Use case: scegliere canonicalizer in base al type di equivalenza desiderata. */

static uint32_t apply_canonicalizer(uint32_t value, uint32_t canon_id) {
    uint32_t v = value & 0xFFFFFFu;
    switch (canon_id) {
        case 0: return v;
        case 1: return mat24_syndrome(v, 0);
        case 2: return (uint32_t)mat24_gcode_weight(v);
        case 3:
        case 4:
        case 7: {
            /* Exact Co_0 (the only Co_0 canonicalizer allowed): full canonical
             * reduction via gen_leech2_reduce_type2. No free parameter, no
             * truncated BFS — a closed algebraic reduction. Two vectors in the
             * same Co_0 orbit give the same canonical form. The old id 3
             * (<xi> partial one-shot) and id 4 (bounded BFS max_iter — a free
             * parameter) are redirected here: the "no heuristics, no
             * parameters" principle forbids partial or parametric
             * canonicalizations alongside the exact one. If v is not type-2,
             * reduce returns <0 and we keep v (correct under-merge). */
            extern int32_t gen_leech2_reduce_type2(uint32_t, uint32_t *);
            extern uint32_t gen_leech2_op_word_leech2(uint32_t, uint32_t *, uint32_t, uint32_t);
            uint32_t g[8];
            int32_t len = gen_leech2_reduce_type2(v, g);
            if (len < 0) return v;
            return gen_leech2_op_word_leech2(v, g, (uint32_t)len, 0);
        }
        case 5: return (uint32_t)__builtin_popcount(v);
        case 6: return v % 8;
        default: return v;
    }
}

double yon_rt_hashmap_orbital_set_with(double map_id, double key, double value, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)key, (uint32_t)canon_id_d);
    return yon_rt_map_put(map_id, (double)canonical, value);
}

double yon_rt_hashmap_orbital_get_with(double map_id, double key, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)key, (uint32_t)canon_id_d);
    return yon_rt_map_get(map_id, (double)canonical);
}

double yon_rt_hashset_orbital_add_with(double set_id, double elem, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)elem, (uint32_t)canon_id_d);
    return yon_rt_hashset_add(set_id, (double)canonical);
}

double yon_rt_hashset_orbital_contains_with(double set_id, double elem, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)elem, (uint32_t)canon_id_d);
    return yon_rt_hashset_contains(set_id, (double)canonical);
}

/* Merkle.leaf orbital: canonicalize label */
double yon_rt_merkle_leaf_orbital(double label, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)label, (uint32_t)canon_id_d);
    return yon_rt_merkle_leaf((double)canonical);
}

/* Space.orbital_get/set: canonicalize indice (analogo a HashMap pattern) */
double yon_rt_space_orbital_set(double space_id, double idx, double value, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)idx, (uint32_t)canon_id_d);
    /* Space.set as ds_hashmap update — reuses yon_rt_map_put */
    return yon_rt_map_put(space_id, (double)canonical, value);
}

double yon_rt_space_orbital_get(double space_id, double idx, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)idx, (uint32_t)canon_id_d);
    return yon_rt_map_get(space_id, (double)canonical);
}

/* XSet orbital: canonicalize before the MPHF lookup.
 * XSet uses MPHF over the 24D type-2 Leech. Already intrinsically orbit-aware
 * for Co_0, but only for elements that are already Leech vectors. For generic
 * numeric elements, we canonicalize first. */
double yon_rt_xset_orbital_add(double set_id, double elem, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)elem, (uint32_t)canon_id_d);
    return yon_rt_xset_add(set_id, (double)canonical);
}

double yon_rt_xset_orbital_contains(double set_id, double elem, double canon_id_d) {
    uint32_t canonical = apply_canonicalizer((uint32_t)elem, (uint32_t)canon_id_d);
    return yon_rt_xset_contains(set_id, (double)canonical);
}

/* ============================================================== */
/* Stdlib estesa:                    */
/* String, Time, Random                                            */
/* ============================================================== */

#include <time.h>

/* String pool: each "string" is an xheap slot with bytes. */
/* Strings represented as xheap IDs, content-addressed. */

#define YON_STR_MAX_LEN 1024

double yon_rt_string_from_int(double n_d) {
    ds_ensure_init();
    /* Convert an int to a decimal string (e.g. 42 -> "42"). Save in the xheap. */
    char buf[32];
    int n = (int)n_d;
    snprintf(buf, sizeof(buf), "%d", n);
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, buf, strlen(buf) + 1, YON_TAG_USER1);
    return (double)slot;
}

double yon_rt_string_length(double str_id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return 0.0;
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    if (!p) return 0.0;
    return (double)strlen(p);
}

double yon_rt_string_concat(double a_id_d, double b_id_d) {
    ds_ensure_init();
    uint32_t sa = (uint32_t)a_id_d, sb = (uint32_t)b_id_d;
    const yon_xheap_slot_t *xa = yon_xheap_get_chain(sa);
    const yon_xheap_slot_t *xb = yon_xheap_get_chain(sb);
    if (!xa || !xb) return 0.0;
    const char *pa = (const char *)yon_xheap_slot_payload_any(xa);
    const char *pb = (const char *)yon_xheap_slot_payload_any(xb);
    if (!pa || !pb) return 0.0;
    size_t la = strlen(pa), lb = strlen(pb);
    /* 2026-06-04: no length cap. Stack buffer for the common case, heap
     * for large results; the limit is memory (and the heap arena, which
     * the chain extends by itself). */
    char stack_buf[1024];
    char *buf = (la + lb + 1 <= sizeof(stack_buf))
                ? stack_buf
                : (char *)malloc(la + lb + 1);
    if (!buf) return 0.0;
    memcpy(buf, pa, la);
    memcpy(buf + la, pb, lb);
    buf[la + lb] = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, buf, (uint32_t)(la + lb + 1), YON_TAG_USER1);
    if (buf != stack_buf) free(buf);
    return (double)slot;
}

double yon_rt_string_equal(double a_id_d, double b_id_d) {
    uint32_t sa = (uint32_t)a_id_d, sb = (uint32_t)b_id_d;
    /* Content-addressed: same slot ⟺ same bytes. */
    return (sa == sb) ? 1.0 : 0.0;
}

double yon_rt_string_char_at(double str_id_d, double idx_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    int idx = (int)idx_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return -1.0;
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    if (!p || idx < 0 || idx >= (int)strlen(p)) return -1.0;
    return (double)((unsigned char)p[idx]);
}

double yon_rt_string_print(double str_id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) { printf("(invalid string id)\n"); return 0.0; }
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    printf("%s\n", p ? p : "");
    return 0.0;
}

/* ============================================================== */
/* String extensions per parsing DIMACS     */
/* ============================================================== */

/* String.parse_number(s) -> number. Expression: int or float, tolerates spaces. */
double yon_rt_string_parse_number(double str_id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return 0.0;
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    if (!p) return 0.0;
    while (*p == ' ' || *p == '\t') p++;
    return strtod(p, NULL);
}

/* String.substring(s, start, len) -> String slot */
double yon_rt_string_substring(double str_id_d, double start_d, double len_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    int start = (int)start_d;
    int len = (int)len_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return 0.0;
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    if (!p) return 0.0;
    int total_len = (int)strlen(p);
    if (start < 0 || start > total_len) return 0.0;
    if (len < 0) len = 0;
    if (start + len > total_len) len = total_len - start;
    char stack_buf[1024];
    char *buf = ((size_t)len + 1 <= sizeof(stack_buf))
                ? stack_buf
                : (char *)malloc((size_t)len + 1);
    if (!buf) return 0.0;
    memcpy(buf, p + start, len);
    buf[len] = 0;
    uint32_t new_slot = yon_xheap_put_chain(g_ds_heap, buf, (uint32_t)(len + 1), YON_TAG_USER1);
    if (buf != stack_buf) free(buf);
    return (double)new_slot;
}

/* String.find_char(s, char_code, from_idx) -> idx (-1 if not found) */
double yon_rt_string_find_char(double str_id_d, double char_code_d, double from_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    int c = (int)char_code_d;
    int from = (int)from_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return -1.0;
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    if (!p) return -1.0;
    int len = (int)strlen(p);
    if (from < 0) from = 0;
    for (int i = from; i < len; i++) {
        if ((unsigned char)p[i] == (unsigned char)c) return (double)i;
    }
    return -1.0;
}

/* String.from_literal(<inline payload>) — for now use from_int and concat.
 * Aggiungo char_to_string per costruire stringhe inline. */
double yon_rt_string_from_char(double char_code_d) {
    ds_ensure_init();
    char buf[2];
    buf[0] = (char)((int)char_code_d & 0xFF);
    buf[1] = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, buf, 2, YON_TAG_USER1);
    return (double)slot;
}

/* ============================================================== */
/* File stdlib — File.read_text(path: String) -> String   */
/* ============================================================== */

double yon_rt_file_read_text(double path_id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)path_id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return 0.0;
    const char *path = (const char *)yon_xheap_slot_payload_any(s);
    if (!path) return 0.0;
    FILE *f = fopen(path, "r");
    if (!f) return 0.0;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz >= 16*1024*1024) { fclose(f); return 0.0; }
    char *buf = (char *)malloc(sz + 1);
    if (!buf) { fclose(f); return 0.0; }
    size_t r = fread(buf, 1, sz, f);
    buf[r] = 0;
    fclose(f);
    /* Truncate to YON_STR_MAX_LEN if needed for xheap */
    if ((long)r >= YON_STR_MAX_LEN) {
        buf[YON_STR_MAX_LEN - 1] = 0;
        r = YON_STR_MAX_LEN - 1;
    }
    uint32_t out_slot = yon_xheap_put_chain(g_ds_heap, buf, r + 1, YON_TAG_USER1);
    free(buf);
    return (double)out_slot;
}

double yon_rt_file_exists(double path_id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)path_id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return 0.0;
    const char *path = (const char *)yon_xheap_slot_payload_any(s);
    if (!path) return 0.0;
    FILE *f = fopen(path, "r");
    if (f) { fclose(f); return 1.0; }
    return 0.0;
}

/* ============================================================== */
/* v1.0 perimeter — File write, Env, Args (decision 2026-06-03)    */
/* ============================================================== */

/* Shared idiom: a String is an xheap slot on g_ds_heap whose payload is a
 * NUL-terminated C string; the handle travels as f64. 0.0 = failure, the
 * same sentinel convention as yon_rt_file_read_text. */
static const char *yon_ds_cstr(double id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return NULL;
    return (const char *)yon_xheap_slot_payload_any(s);
}

static double yon_ds_string(const char *str) {
    if (!str) return 0.0;
    ds_ensure_init();
    size_t len = strlen(str);
    if (len >= YON_STR_MAX_LEN) len = YON_STR_MAX_LEN - 1;
    char *buf = (char *)malloc(len + 1);
    if (!buf) return 0.0;
    memcpy(buf, str, len);
    buf[len] = 0;
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, buf, len + 1, YON_TAG_USER1);
    free(buf);
    return (double)slot;
}

static double yon_rt_file_put_text(double path_id_d, double content_id_d,
                                   const char *mode) {
    const char *path = yon_ds_cstr(path_id_d);
    const char *content = yon_ds_cstr(content_id_d);
    if (!path || !content) return 0.0;
    FILE *f = fopen(path, mode);
    if (!f) return 0.0;
    size_t len = strlen(content);
    size_t w = fwrite(content, 1, len, f);
    int rc = fclose(f);
    return (w == len && rc == 0) ? 1.0 : 0.0;
}

/* File.write_text(path, content) -> 1.0 ok / 0.0 fail (truncating write) */
double yon_rt_file_write_text(double path_id_d, double content_id_d) {
    return yon_rt_file_put_text(path_id_d, content_id_d, "w");
}

/* File.append_text(path, content) -> 1.0 ok / 0.0 fail */
double yon_rt_file_append_text(double path_id_d, double content_id_d) {
    return yon_rt_file_put_text(path_id_d, content_id_d, "a");
}

/* String literal interning: called once per literal occurrence with the
 * address of the module's global bytes. The heap is content-addressed, so
 * the intern is idempotent: same literal, same slot, zero duplication. */
double yon_rt_string_lit(const char *bytes) {
    ds_ensure_init();
    return yon_ds_string(bytes);
}

/* Forwarding shim for yon_rt_text_to_prop (defined earlier in the file,
 * before yon_ds_cstr exists). */
const char *yon_ds_cstr_fwd(double h) { return yon_ds_cstr(h); }

/* Env.get(name) -> String handle, or 0.0 if the variable is not set */
double yon_rt_env_get(double name_id_d) {
    const char *name = yon_ds_cstr(name_id_d);
    if (!name) return 0.0;
    const char *val = getenv(name);
    if (!val) return 0.0;
    return yon_ds_string(val);
}

/* Env.has(name) -> 1.0 / 0.0 */
double yon_rt_env_has(double name_id_d) {
    const char *name = yon_ds_cstr(name_id_d);
    if (!name) return 0.0;
    return getenv(name) ? 1.0 : 0.0;
}

/* Args.count() -> number of process arguments (argv[0] included).
 * Args.get(i) -> argv[i] as a String handle, 0.0 if out of range.
 * The raw argv stashed by yon_rt_set_args is exposed as-is: a served
 * process (`--serve2 <Name>`) sees its serve flags like any other arg. */
double yon_rt_args_count(void) {
    return (double)g_argc;
}

double yon_rt_args_get(double i_d) {
    int i = (int)i_d;
    if (i < 0 || i >= g_argc || !g_argv) return 0.0;
    return yon_ds_string(g_argv[i]);
}

/* ============================================================== */
/* Bits.fold — apply op to each set bit of a value                 */
/* ============================================================== */

/* Bits.fold(value, op_id, init) -> apply op to init for each set bit.
 * op_id: 0=ADD (count bits), 1=OR, 2=MAX index, 3=running sum of indices */
double yon_rt_bits_fold(double value_d, double op_id_d, double init_d) {
    uint64_t v = (uint64_t)value_d;
    int op_id = (int)op_id_d;
    double acc = init_d;
    int max_idx = 0;
    for (int i = 0; i < 64; i++) {
        if (v & (1ull << i)) {
            switch (op_id) {
                case 0: acc += 1.0; break;
                case 1: acc = (double)((uint64_t)acc | (1ull << i)); break;
                case 2: max_idx = i; break;
                case 3: acc += (double)i; break;
                default: break;
            }
        }
    }
    if (op_id == 2) return (double)max_idx;
    return acc;
}

/* Time */
double yon_rt_time_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)(ts.tv_sec * 1000) + (double)(ts.tv_nsec / 1000000);
}

double yon_rt_time_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)(ts.tv_sec * 1000000000ull + ts.tv_nsec);
}

/* Random: LCG seeded. */
static uint32_t rng_state = 0x12345678u;

double yon_rt_random_seed(double seed_d) {
    rng_state = (uint32_t)seed_d;
    return 0.0;
}

double yon_rt_random_int(void) {
    /* LCG: Numerical Recipes constants */
    rng_state = rng_state * 1664525u + 1013904223u;
    return (double)rng_state;
}

double yon_rt_random_range(double lo_d, double hi_d) {
    rng_state = rng_state * 1664525u + 1013904223u;
    int lo = (int)lo_d, hi = (int)hi_d;
    if (hi <= lo) return (double)lo;
    int range = hi - lo;
    return (double)(lo + (int)(rng_state % (uint32_t)range));
}

/* Crypto: minimal SHA-256. Simple implementation. */
/* For the MVP, use a fast non-cryptographic hash (FNV-1a) as a placeholder.
 * Real SHA-256 would require an OpenSSL dependency or a heavy in-house impl. */
double yon_rt_crypto_fnv1a(double str_id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return 0.0;
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    if (!p) return 0.0;
    uint32_t h = 0x811c9dc5u;
    for (; *p; p++) {
        h ^= (uint8_t)*p;
        h *= 0x01000193u;
    }
    return (double)h;
}

double yon_rt_crypto_hash_int(double n_d) {
    uint32_t v = (uint32_t)n_d;
    /* xxHash-like avalanche */
    v ^= v >> 16;
    v *= 0x85ebca6bu;
    v ^= v >> 13;
    v *= 0xc2b2ae35u;
    v ^= v >> 16;
    return (double)v;
}

/* ============================================================== */
/* SAT 3-clause OR-wavefront prover                               */
/* Empirical OR/SAT exploration                                   */
/* ============================================================== */

/* Generate m = floor(4.27 * n) random 3-SAT clauses at the phase transition.
 * Each clause = an n-bit bitmask with exactly 3 set bits (3 positive variables
 * — NOT is ignored for simplicity, focus on OR-saturation).
 *
 * Runs the full wavefront: R_0 = {0}, R_i = R_{i-1} U {s|a_i : s in R_{i-1}}.
 *
 * Measures:
 *   - final |R|
 *   - k_active = #{i : o_i > epsilon}
 *   - max_o, avg_o
 *   - sum o_i
 *
 * Returns combined, encoded as a double:
 *   metric_id 1 -> |R|
 *   metric_id 2 -> k_active
 *   metric_id 3 -> max_o (* 1000)
 *   metric_id 4 -> avg_o (* 1000)
 *   metric_id 5 -> sum_o (* 1000)
 *   metric_id 6 -> G (number of clauses)
 *   metric_id 7 -> R/G^5 ratio (* 1000000, poly bound fit)
 */

#include <stdlib.h>
#include <unistd.h>

#define SAT_MAX_VARS 24
#define SAT_MAX_R   16777216u   /* 2^24 */
#define SAT_BMP_WORDS (SAT_MAX_R / 64u + 1u)

static double sat_metric_R = 0.0;
static double sat_metric_k = 0.0;
static double sat_metric_max_o = 0.0;
static double sat_metric_avg_o = 0.0;
static double sat_metric_sum_o = 0.0;
static double sat_metric_G = 0.0;
static double sat_metric_R_over_Gpow5 = 0.0;
static double sat_metric_last_n = -1.0;
static double sat_metric_last_seed = -1.0;

/* LCG locale per non interferire con random_state globale. */
static uint32_t sat_rng_state_local = 0;
static uint32_t sat_next(uint32_t mod) {
    sat_rng_state_local = sat_rng_state_local * 1664525u + 1013904223u;
    return mod ? (sat_rng_state_local % mod) : sat_rng_state_local;
}

static void sat_run_and_cache(uint32_t n_vars, uint32_t seed) {
    if (n_vars > SAT_MAX_VARS) n_vars = SAT_MAX_VARS;
    sat_rng_state_local = seed ? seed : 0xCAFEBABEu;

    /* G = floor(4.27 * n) */
    uint32_t G = (uint32_t)((double)n_vars * 4.27);
    if (G < 1) G = 1;

    /* Genera G clauses */
    static uint32_t clauses[SAT_MAX_VARS * 5];
    for (uint32_t i = 0; i < G; i++) {
        uint32_t mask = 0;
        uint32_t bits_set = 0;
        while (bits_set < 3) {
            uint32_t b = sat_next(n_vars);
            uint32_t bit = 1u << b;
            if (!(mask & bit)) {
                mask |= bit;
                bits_set++;
            }
        }
        clauses[i] = mask;
    }

    /* Full wavefront via bitmap |R| <= 2^n_vars */
    uint64_t bmp_size = (1ull << n_vars);
    static uint64_t *bmp = NULL;
    static uint64_t bmp_alloc = 0;
    if (bmp_alloc < bmp_size / 64ull + 1) {
        free(bmp);
        bmp_alloc = bmp_size / 64ull + 1ull;
        bmp = (uint64_t*)calloc(bmp_alloc, sizeof(uint64_t));
    } else {
        memset(bmp, 0, bmp_alloc * sizeof(uint64_t));
    }
    /* R_0 = {0} */
    bmp[0] |= 1ull;
    uint64_t R_size_prev = 1;

    /* For the measure: track |R_i| after each clause */
/* o_per_round eliminated: we track only the aggregate. */
    double max_o = 0.0;
    double sum_o = 0.0;
    uint32_t k_active = 0;

    for (uint32_t i = 0; i < G; i++) {
        uint32_t a = clauses[i];
        /* Apply: for each state s in R, add s|a to R */
        /* Iterate bitmap; for each set s, set s|a */
        uint64_t R_size_now = R_size_prev;
        for (uint64_t s = 0; s < bmp_size; s++) {
            if (bmp[s >> 6] & (1ull << (s & 63))) {
                uint64_t s_or = s | a;
                if (!(bmp[s_or >> 6] & (1ull << (s_or & 63)))) {
                    bmp[s_or >> 6] |= (1ull << (s_or & 63));
                    R_size_now++;
                }
            }
        }
        double delta = (double)(R_size_now - R_size_prev);
        double o_i = delta / (1.0 + (double)R_size_prev);
/* o_per_round[i] = o_i; (eliminated) */
        if (o_i > 0.1) k_active++;
        if (o_i > max_o) max_o = o_i;
        sum_o += o_i;
        R_size_prev = R_size_now;
    }

    sat_metric_R = (double)R_size_prev;
    sat_metric_k = (double)k_active;
    sat_metric_max_o = max_o;
    sat_metric_avg_o = (G > 0) ? sum_o / (double)G : 0.0;
    sat_metric_sum_o = sum_o;
    sat_metric_G = (double)G;
    double Gpow5 = (double)G * (double)G * (double)G * (double)G * (double)G;
    sat_metric_R_over_Gpow5 = (Gpow5 > 0.0) ? sat_metric_R / Gpow5 : 0.0;
    sat_metric_last_n = (double)n_vars;
    sat_metric_last_seed = (double)seed;
}

double yon_rt_sat_3sat_run(double n_vars_d, double seed_d, double metric_id_d) {
    uint32_t n = (uint32_t)n_vars_d;
    uint32_t s = (uint32_t)seed_d;
    uint32_t m = (uint32_t)metric_id_d;
    /* Cache: ri-eseguo solo se cambia (n, seed) */
    if (sat_metric_last_n != (double)n || sat_metric_last_seed != (double)s) {
        sat_run_and_cache(n, s);
    }
    switch (m) {
        case 1: return sat_metric_R;
        case 2: return sat_metric_k;
        case 3: return sat_metric_max_o * 1000.0;
        case 4: return sat_metric_avg_o * 1000.0;
        case 5: return sat_metric_sum_o * 1000.0;
        case 6: return sat_metric_G;
        case 7: return sat_metric_R_over_Gpow5 * 1000000.0;
        default: return -1.0;
    }
}

/* ============================================================== */
/* SAT 3-clause with NOT literals + filter satisfiable           */
/* ============================================================== */

/* A clause encoded as 2*n bits: positive literal i = bit 2i, negative = bit
 * 2i+1. So for an assignment a={a_0,a_1,...,a_{n-1}}, a clause is satisfied if
 * for at least one of its literals the corresponding bit is "true":
 *   positive literal i: a_i = 1
 *   negative literal i: a_i = 0
 *
 * For the OR-wavefront prover we cannot model NOT directly in an OR-bitmask:
 * OR always saturates toward 1. So an alternative model: encode each clause as
 * a 2-tuple (pos_mask, neg_mask), and define the clause "violation" as
 * (a & pos_mask) == 0 && (~a & neg_mask) == 0.
 *
 * For the OR-saturation analysis we use the encoding:
 *   clause c = pos_mask | (neg_mask << n)
 * Example: clause (x_0 OR not x_1 OR x_2) with n=4:
 *   pos_mask = 0b0101 = 5
 *   neg_mask = 0b0010 = 2 -> shifted = 0b00100000 = 32
 *   c = 5 | 32 = 37
 *
 * Wavefront in 2n-bit space, analogous absorbing behavior. */

#define SAT2_MAX_VARS 12   /* 2n = 24 bits of space, 2^24=16M bitmap = 2MB */

static double sat2_metric_R = 0.0;
static double sat2_metric_k = 0.0;
static double sat2_metric_max_o = 0.0;
static double sat2_metric_sum_o = 0.0;
static double sat2_metric_G = 0.0;
static double sat2_metric_sat = 0.0;
static double sat2_metric_last_n = -1.0;
static double sat2_metric_last_seed = -1.0;
static double sat2_metric_last_filter = -1.0;

static uint32_t sat2_rng = 0;
static uint32_t sat2_next(uint32_t mod) {
    sat2_rng = sat2_rng * 1664525u + 1013904223u;
    return mod ? (sat2_rng % mod) : sat2_rng;
}

/* DPLL backtracking check satisfiability (brute force n <= 24). */
static int dpll_check(const uint32_t *clauses, uint32_t n_clauses, uint32_t n_vars) {
    uint32_t n_assignments = 1u << n_vars;
    for (uint32_t a = 0; a < n_assignments; a++) {
        int all_sat = 1;
        for (uint32_t c = 0; c < n_clauses; c++) {
            uint32_t pos_mask = clauses[c] & ((1u << n_vars) - 1u);
            uint32_t neg_mask = (clauses[c] >> n_vars) & ((1u << n_vars) - 1u);
            /* clause satisfied if: (a & pos_mask) || (~a & neg_mask) */
            if (!(((a) & pos_mask) | ((~a) & neg_mask & ((1u << n_vars) - 1u)))) {
                all_sat = 0;
                break;
            }
        }
        if (all_sat) return 1;
    }
    return 0;
}

static void sat2_run_and_cache(uint32_t n_vars, uint32_t seed, int filter_sat) {
    if (n_vars > SAT2_MAX_VARS) n_vars = SAT2_MAX_VARS;
    sat2_rng = seed ? seed : 0xDEADBEEFu;

    uint32_t G = (uint32_t)((double)n_vars * 4.27);
    if (G < 1) G = 1;

    static uint32_t clauses[200];
    int max_retries = filter_sat ? 100 : 1;
    int is_sat = 0;

    for (int retry = 0; retry < max_retries; retry++) {
        /* Generate G random clauses with a random sign for each literal */
        for (uint32_t i = 0; i < G; i++) {
            uint32_t pos_mask = 0, neg_mask = 0;
            uint32_t literals_set = 0;
            while (literals_set < 3) {
                uint32_t v = sat2_next(n_vars);
                uint32_t bit = 1u << v;
                if (!(pos_mask & bit) && !(neg_mask & bit)) {
                    if (sat2_next(2)) pos_mask |= bit;
                    else neg_mask |= bit;
                    literals_set++;
                }
            }
            clauses[i] = pos_mask | (neg_mask << n_vars);
        }
        if (!filter_sat) { is_sat = 1; break; }
        /* Check SAT via DPLL brute */
        if (dpll_check(clauses, G, n_vars)) { is_sat = 1; break; }
    }

    /* Wavefront 2n-bit OR-space */
    uint32_t bits_2n = 2u * n_vars;
    uint64_t bmp_size = (1ull << bits_2n);
    static uint64_t *bmp = NULL;
    static uint64_t bmp_alloc = 0;
    if (bmp_alloc < bmp_size / 64ull + 1) {
        free(bmp);
        bmp_alloc = bmp_size / 64ull + 1ull;
        bmp = (uint64_t*)calloc(bmp_alloc, sizeof(uint64_t));
    } else {
        memset(bmp, 0, bmp_alloc * sizeof(uint64_t));
    }
    bmp[0] |= 1ull;
    uint64_t R_size_prev = 1;
    double max_o = 0.0, sum_o = 0.0;
    uint32_t k_active = 0;

    for (uint32_t i = 0; i < G; i++) {
        uint64_t a = clauses[i];
        uint64_t R_size_now = R_size_prev;
        for (uint64_t s = 0; s < bmp_size; s++) {
            if (bmp[s >> 6] & (1ull << (s & 63))) {
                uint64_t s_or = s | a;
                if (s_or < bmp_size && !(bmp[s_or >> 6] & (1ull << (s_or & 63)))) {
                    bmp[s_or >> 6] |= (1ull << (s_or & 63));
                    R_size_now++;
                }
            }
        }
        double delta = (double)(R_size_now - R_size_prev);
        double o_i = delta / (1.0 + (double)R_size_prev);
        if (o_i > 0.1) k_active++;
        if (o_i > max_o) max_o = o_i;
        sum_o += o_i;
        R_size_prev = R_size_now;
    }

    sat2_metric_R = (double)R_size_prev;
    sat2_metric_k = (double)k_active;
    sat2_metric_max_o = max_o;
    sat2_metric_sum_o = sum_o;
    sat2_metric_G = (double)G;
    sat2_metric_sat = (double)is_sat;
    sat2_metric_last_n = (double)n_vars;
    sat2_metric_last_seed = (double)seed;
    sat2_metric_last_filter = (double)filter_sat;
}

double yon_rt_sat_3sat_filtered(double n_vars_d, double seed_d, double filter_d, double metric_id_d) {
    uint32_t n = (uint32_t)n_vars_d;
    uint32_t s = (uint32_t)seed_d;
    int filter = (filter_d > 0.5) ? 1 : 0;
    uint32_t m = (uint32_t)metric_id_d;
    if (sat2_metric_last_n != (double)n
        || sat2_metric_last_seed != (double)s
        || sat2_metric_last_filter != (double)filter) {
        sat2_run_and_cache(n, s, filter);
    }
    switch (m) {
        case 1: return sat2_metric_R;
        case 2: return sat2_metric_k;
        case 3: return sat2_metric_max_o * 1000.0;
        case 4: return sat2_metric_sum_o * 1000.0;
        case 5: return sat2_metric_G;
        case 6: return sat2_metric_sat;
        default: return -1.0;
    }
}

/* ============================================================== */
/* Sparse state-space SAT solver for DIMACS UF20/UF50              */
/* ============================================================== */

/* Sparse state-space strategy:
 *
 * Encoding: each state = a pair (pos_bits, neg_bits) of n bits each.
 *   pos_bits[i] = 1 iff the positive literal +x_i has been derived/covered
 *   neg_bits[i] = 1 iff the negative literal -x_i has been derived/covered
 *
 * A clause (l_1 OR l_2 OR l_3) is "satisfied by the state" iff at least one of
 * its literals is covered. When we apply clause c to the wavefront, we
 * generate all states that cover c (OR with at least one of the 3 literals):
 *
 *   for each state s in R, for each literal L_i in c:
 *     s' = s | L_i_mask (a single bit set)
 *     R := R U {s'}
 *
 * Note this is the simple covering wavefront, not the full monoid-closure
 * wavefront. The true wavefront has monoid axioms and computes the closure
 * {a_1 o a_2 o ... o a_k : k <= ...}. For OR/SAT:
 *
 *   a_i = the i-th clause as a 2n-bit bitvector
 *         (pos_mask_i << n) | neg_mask_i (= the union of its literals)
 *   s o a = s OR a
 *
 * Wavefront: R_0 = {0}, R_i = R_{i-1} U {s | a_j : s in R_{i-1}, j <= i}
 *
 * Sparse implementation via a HashSet (linear-probing 2^k buckets).
 * Memory cost: O(|R|), not 2^(2n) like a bitmap.
 * Time cost: O(|R| x G) per total iteration. */

/* === Leech xheap migration: naive wavefront ===
 * sparse_set (128 MB malloc) and frontier (malloc) eliminated. Dedup via the
 * g_sat_heap content_index. The naive version does not canonicalize: dedup is
 * direct on the raw uint64 values. */

/* SAT scratchpad heap: declared above, defined here. Separate from g_yon_heap
 * (Space + list_cons) to allow a reset between runs without destroying
 * persistent state. */
extern yon_xheap_t *g_yon_heap;
static yon_xheap_t *g_sat_heap = NULL;

static void sat_heap_ensure(void) {
    if (!g_sat_heap) {
        g_sat_heap = yon_xheap_create();
        if (!g_sat_heap) {
            fprintf(stderr, "[YON-RT] FATAL: g_sat_heap create failed\n");
            abort();
        }
    }
}

static uint32_t sparse_count = 0;
static uint32_t sparse_slots[YON_HEAP_N_SLOTS];   /* slot_id per snapshot iter */
static uint32_t sparse_slots_n = 0;

static void sparse_init(void) {
    sat_heap_ensure();
}

static void sparse_clear(void) {
    sat_heap_ensure();
    yon_xheap_reset(g_sat_heap);
    sparse_count = 0;
    sparse_slots_n = 0;
}

/* Returns 1 if newly inserted (e push slot), 0 if already present */
static int sparse_insert(uint64_t v) {
    bool was_new = false;
    uint32_t slot = yon_xheap_put_or_get(g_sat_heap, &v, sizeof(v),
                                          YON_TAG_USER1, &was_new);
    if (slot == YON_HEAP_SLOT_INVALID) return 0;
    if (!was_new) return 0;
    sparse_count++;
    if (sparse_slots_n < YON_HEAP_N_SLOTS)
        sparse_slots[sparse_slots_n++] = slot;
    return 1;
}

static inline uint64_t sparse_at(uint32_t slot_id) {
    const yon_xheap_slot_t *s = yon_xheap_get(g_sat_heap, slot_id);
    if (!s) return 0;
    const void *p = yon_xheap_slot_payload(g_sat_heap, s);
    return p ? *(const uint64_t*)p : 0;
}

/* Iterate snapshot: now iterates directly over sparse_slots[] (insertion
 * order). No more scanning 128M buckets. */
__attribute__((unused)) static uint32_t sparse_snapshot(uint64_t *out, uint32_t max_out) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < sparse_slots_n && n < max_out; i++) {
        out[n++] = sparse_at(sparse_slots[i]);
    }
    return n;
}

/* DIMACS parser + sparse wavefront prover.
 *
 * Salva clauses come array di 2n-bit values (pos_mask | neg_mask << n).
 * Misura |R|, k_active, max_o, sum_o, G, n_vars.
 *
 * filepath_id: index in tabella global (parser carica file una volta,
 * caches per nome).
 *
 * metric_id: 1=|R|, 2=k_active, 3=max_o*1000, 4=sum_o*1000, 5=G, 6=n_vars */

#define MAX_DIMACS_CLAUSES 1024
static uint64_t dimacs_clauses[MAX_DIMACS_CLAUSES];
static uint32_t dimacs_G = 0;
static uint32_t dimacs_n_vars = 0;


/* Re-implementing the parser more carefully: */
static int dimacs_load(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char buf[8192];
    dimacs_G = 0;
    dimacs_n_vars = 0;
    uint32_t clause_idx = 0;
    uint64_t cur_pos = 0, cur_neg = 0;
    while (fgets(buf, sizeof(buf), f)) {
        if (buf[0] == 'c' || buf[0] == '\n' || buf[0] == '%') continue;
        if (buf[0] == 'p') {
            sscanf(buf, "p cnf %u %u", &dimacs_n_vars, &dimacs_G);
            continue;
        }
        char *p = buf;
        while (*p) {
            while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
            if (!*p) break;
            int sign = 1;
            if (*p == '-') { sign = -1; p++; }
            else if (*p == '+') { p++; }
            if (!(*p >= '0' && *p <= '9')) { p++; continue; }
            int lit = 0;
            while (*p >= '0' && *p <= '9') { lit = lit * 10 + (*p - '0'); p++; }
            if (lit == 0) {
                if (clause_idx < MAX_DIMACS_CLAUSES) {
                    dimacs_clauses[clause_idx++] = cur_pos | (cur_neg << dimacs_n_vars);
                }
                cur_pos = cur_neg = 0;
                continue;
            }
            uint64_t bit = 1ull << (lit - 1);
            if (sign > 0) cur_pos |= bit;
            else cur_neg |= bit;
        }
    }
    fclose(f);
    return 1;
}

/* Wavefront sparse su clauses caricate. */
static double dimacs_metric_R = 0.0;
static double dimacs_metric_k = 0.0;
static double dimacs_metric_max_o = 0.0;
static double dimacs_metric_sum_o = 0.0;
static double dimacs_o_trace[1024];     /* per-round o_i (max 1024 round) */
static uint32_t dimacs_o_trace_len = 0;
static uint32_t dimacs_rounds_completed = 0;  /* round before cap */

__attribute__((unused)) static uint64_t snapshot_buf[8000000ull]; /* 64MB buffer per snapshot */

/* Maximum R cap for the naive version: limited by the capacity of a single
 * xheap. YON_HEAP_N_SLOTS = 196560. Naive on UF20 saturates at ~1717, UF50 at
 * ~5000. Larger instances would need a heap chain (TODO). */

/* frontier_add: dedup via xheap, push slot a sparse_slots[] (insertion order). */
static int frontier_add(uint64_t v) {
    return sparse_insert(v);
}

static void frontier_init(void) {
    sparse_clear();  /* reset g_sat_heap + counters */
}

static void dimacs_run_sparse_wavefront(void) {
    sparse_init();
    frontier_init();
    frontier_add(0ull); /* R_0 = {0} */
    uint64_t R_size_prev = 1;
    double max_o = 0.0, sum_o = 0.0;
    uint32_t k_active = 0;
    dimacs_o_trace_len = 0;
    dimacs_rounds_completed = 0;

    for (uint32_t i = 0; i < dimacs_G; i++) {
        uint64_t a = dimacs_clauses[i];
        if (sparse_count >= YON_HEAP_N_SLOTS) break;
        /* Snapshot current frontier size: apply a only to the facts already in R. */
        uint32_t n_now = sparse_slots_n;
        for (uint32_t j = 0; j < n_now && sparse_count < YON_HEAP_N_SLOTS; j++) {
            uint64_t s = sparse_at(sparse_slots[j]);
            uint64_t s_or = s | a;
            if (s_or != s) frontier_add(s_or);
        }
        uint64_t R_size_now = sparse_count;
        double delta = (double)(R_size_now - R_size_prev);
        double o_i = delta / (1.0 + (double)R_size_prev);
        if (o_i > 0.1) k_active++;
        if (o_i > max_o) max_o = o_i;
        sum_o += o_i;
        if (dimacs_o_trace_len < 1024) {
            dimacs_o_trace[dimacs_o_trace_len++] = o_i;
        }
        dimacs_rounds_completed = i + 1;
        R_size_prev = R_size_now;
    }

    dimacs_metric_R = (double)R_size_prev;
    dimacs_metric_k = (double)k_active;
    dimacs_metric_max_o = max_o;
    dimacs_metric_sum_o = sum_o;
}

/* File ID strings -> path resolution.
 * Yon passa string_id (slot xheap). Estraggo C string, chiamo parser. */
double yon_rt_sat_dimacs_run(double str_id_d, double metric_id_d) {
    ds_ensure_init();
    uint32_t slot = (uint32_t)str_id_d;
    const yon_xheap_slot_t *s = yon_xheap_get_chain(slot);
    if (!s) return -1.0;
    const char *path = (const char *)yon_xheap_slot_payload_any(s);
    if (!path) return -1.0;
    /* Cache: ri-run solo se path cambia */
    static char cached_path[1024] = "";
    if (strcmp(cached_path, path) != 0) {
        if (!dimacs_load(path)) return -1.0;
        dimacs_run_sparse_wavefront();
        strncpy(cached_path, path, sizeof(cached_path) - 1);
        cached_path[sizeof(cached_path) - 1] = 0;
    }
    uint32_t m = (uint32_t)metric_id_d;
    switch (m) {
        case 1: return dimacs_metric_R;
        case 2: return dimacs_metric_k;
        case 3: return dimacs_metric_max_o * 1000.0;
        case 4: return dimacs_metric_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        default: return -1.0;
    }
}

/* Helper SATLIB UF20/UF50: load by index.
 * Instance dir: $YON_SATLIB_DIR, default ./satlib, layout {uf20,uf50}/uf20-NNNN.cnf
 * Index 1..1000.
 *
 * metric_id come yon_rt_sat_dimacs_run. */

#define SATLIB_BASE (getenv("YON_SATLIB_DIR") ? getenv("YON_SATLIB_DIR") : "./satlib")

static double satlib_run_cached(const char *path, uint32_t metric_id) {
    static char cached_path[1024] = "";
    if (strcmp(cached_path, path) != 0) {
        if (!dimacs_load(path)) return -1.0;
        dimacs_run_sparse_wavefront();
        strncpy(cached_path, path, sizeof(cached_path) - 1);
        cached_path[sizeof(cached_path) - 1] = 0;
    }
    switch (metric_id) {
        case 1: return dimacs_metric_R;
        case 2: return dimacs_metric_k;
        case 3: return dimacs_metric_max_o * 1000.0;
        case 4: return dimacs_metric_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        case 7: return (double)dimacs_rounds_completed;
        default: return -1.0;
    }
}

/* Accesso al trace o_i per round specifico (1-indexed).
 * metric_id=8 -> o_i*1000 at round (idx % 256), idx >> 8 = ?  Too convoluted.
 * Faccio API dedicata: */
double yon_rt_sat_dimacs_o_at(double round_d) {
    uint32_t r = (uint32_t)round_d;
    if (r < 1 || r > dimacs_o_trace_len) return -1.0;
    return dimacs_o_trace[r - 1] * 1000.0;
}

double yon_rt_sat_dimacs_uf20(double idx_d, double metric_id_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return -1.0;
    snprintf(path, sizeof(path), "%s/uf20/uf20-0%d.cnf", SATLIB_BASE, idx);
    return satlib_run_cached(path, (uint32_t)metric_id_d);
}

double yon_rt_sat_dimacs_uf50(double idx_d, double metric_id_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return -1.0;
    snprintf(path, sizeof(path), "%s/uf50/uf50-0%d.cnf", SATLIB_BASE, idx);
    return satlib_run_cached(path, (uint32_t)metric_id_d);
}

/* ============================================================== */
/* Random 3-SAT with arbitrary alpha + sparse wavefront            */
/* ============================================================== */

static uint32_t alpha_rng = 0;
static uint32_t alpha_next(uint32_t mod) {
    alpha_rng = alpha_rng * 1664525u + 1013904223u;
    return mod ? (alpha_rng % mod) : alpha_rng;
}

/* Gen random clauses with given alpha (clauses/vars ratio). */
static void alpha_3sat_gen(uint32_t n_vars, double alpha, uint32_t seed) {
    /* Mix seed with alpha to ensure independent clauses across different alpha */
    uint32_t mix = (uint32_t)(alpha * 1000.0);
    alpha_rng = (seed ? seed : 0xBEEFCAFEu) ^ (mix * 0x9E3779B9u);
    dimacs_n_vars = n_vars;
    dimacs_G = (uint32_t)((double)n_vars * alpha);
    if (dimacs_G > MAX_DIMACS_CLAUSES) dimacs_G = MAX_DIMACS_CLAUSES;
    for (uint32_t i = 0; i < dimacs_G; i++) {
        uint64_t pos = 0, neg = 0;
        uint32_t set = 0;
        while (set < 3) {
            uint32_t v = alpha_next(n_vars);
            uint64_t bit = 1ull << v;
            if (!(pos & bit) && !(neg & bit)) {
                if (alpha_next(2)) pos |= bit;
                else neg |= bit;
                set++;
            }
        }
        dimacs_clauses[i] = pos | (neg << n_vars);
    }
}

/* Caching by (n, alpha*1000, seed) tuple */
static uint32_t last_alpha_n = 0;
static uint32_t last_alpha_a = 0;
static uint32_t last_alpha_s = 0;

double yon_rt_sat_3sat_alpha(double n_d, double alpha_d, double seed_d, double metric_id_d) {
    uint32_t n = (uint32_t)n_d;
    uint32_t a = (uint32_t)(alpha_d * 1000.0);
    uint32_t s = (uint32_t)seed_d;
    uint32_t m = (uint32_t)metric_id_d;
    if (n != last_alpha_n || a != last_alpha_a || s != last_alpha_s) {
        alpha_3sat_gen(n, (double)a / 1000.0, s);
        dimacs_run_sparse_wavefront();
        last_alpha_n = n; last_alpha_a = a; last_alpha_s = s;
    }
    switch (m) {
        case 1: return dimacs_metric_R;
        case 2: return dimacs_metric_k;
        case 3: return dimacs_metric_max_o * 1000.0;
        case 4: return dimacs_metric_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        case 7: return (double)dimacs_rounds_completed;
        default: return -1.0;
    }
}

/* ============================================================== */
/* Orbital wavefront: canonicalization under S_n                  */
/* ============================================================== */

/* Canonical form of a state (pos_mask | neg_mask << n) under S_n: permuting the
 * variables gives an orbit. Canonical = the representative with set bits in the
 * lowest positions.
 *
 * For an OR-state, each variable is a positive OR negative literal covered. A
 * variable has a "local state" in {00, 01, 10, 11}:
 *   00 = no literal covered
 *   01 = only neg covered
 *   10 = only pos covered
 *   11 = both covered (a "saturated" variable)
 *
 * Under S_n, the state is a {bag of variable states}. Canonical = sort.
 * Equivalently: the invariant = (count_00, count_01, count_10, count_11).
 *
 * This is a true orbital under S_n, strongly collapsing. */

static uint64_t orbital_canonicalize(uint64_t state, uint32_t n_vars) {
    /* Extract pos_mask and neg_mask */
    uint64_t pos_mask = state & ((1ull << n_vars) - 1ull);
    uint64_t neg_mask = (state >> n_vars) & ((1ull << n_vars) - 1ull);
    
    /* For each variable i, local state = 2*(pos bit i) + (neg bit i) */
    uint32_t count[4] = {0, 0, 0, 0};
    for (uint32_t i = 0; i < n_vars; i++) {
        uint32_t p = (pos_mask >> i) & 1u;
        uint32_t neg_b = (neg_mask >> i) & 1u;
        count[p * 2 + neg_b]++;
    }
    /* Canonical state: first count_11 variables "11", then count_10, count_01,
     * count_00. We could compose a bit mask: the i-th var has
     * (state_i_pos << i) | (state_i_neg << (i+n)). But the value is just the
     * invariant (count_00, count_01, count_10, count_11). */
    
    /* Pack as 4 * 16-bit fields: max n=50 -> count <= 50 < 2^16. */
    uint64_t canon = ((uint64_t)count[3] << 48)
                   | ((uint64_t)count[2] << 32)
                   | ((uint64_t)count[1] << 16)
                   | ((uint64_t)count[0]);
    return canon;
}

static double dimacs_orbital_metric_R = 0.0;
static double dimacs_orbital_metric_k = 0.0;
static double dimacs_orbital_metric_max_o = 0.0;
static double dimacs_orbital_metric_sum_o = 0.0;
static double dimacs_orbital_o_trace[1024];
static uint32_t dimacs_orbital_o_trace_len = 0;
static uint32_t dimacs_orbital_rounds = 0;

/* === Leech xheap migration ============
 * orb_set[ORB_BUCKETS] (32MB static) and orbital_raw_frontier (80MB static)
 * eliminated. Canon dedup via the g_yon_heap content_index (exact memcmp: zero
 * false positives). orbital_raw_slots[] holds the slot_ids of the raw states
 * in discovery order (for snapshot semantics). */

static uint32_t orbital_raw_slots[YON_HEAP_N_SLOTS];   /* slot_id for ordered iteration */
static uint32_t orbital_raw_slots_n = 0;
static uint32_t orb_count = 0;

/* (g_sat_heap and sat_heap_ensure are now defined higher up, near the naive
 * wavefront, to avoid forward decls.) */

/* Legacy compat: empty declarations so as not to break declared calls
 * (orb_insert and orb_clear were __attribute__((unused))). */
__attribute__((unused)) static int orb_insert(uint64_t v) {
    (void)v;
    return 0;
}

__attribute__((unused)) static void orb_clear(void) {
    orbital_raw_slots_n = 0;
    orb_count = 0;
}

/* True ORBITAL wavefront: keeps the raw frontier for OR, canon for dedup.
 *
 * Insert: canon = canonicalize(raw). yon_xheap_put_or_get(canon) returns a slot
 * with was_new. If new: push raw_slot (also raw canonicalized in the xheap) to
 * orbital_raw_slots[].
 *
 * Wavefront step: s = payload of raw_slot; s_or = s | clause; try_insert. */

static int orb_try_insert(uint64_t raw, uint32_t n_vars) {
    uint64_t canon = orbital_canonicalize(raw, n_vars);
    bool was_new = false;
    uint32_t canon_slot = yon_xheap_put_or_get(g_sat_heap, &canon, sizeof(canon),
                                                YON_TAG_USER1, &was_new);
    if (canon_slot == YON_HEAP_SLOT_INVALID) return 0;
    if (!was_new) return 0;  /* canon dup, no push */
    /* New canon: store the raw in the xheap too and save its slot_id in the
     * ordered array (keeps insertion order for the snapshot). */
    uint32_t raw_slot = yon_xheap_put(g_sat_heap, &raw, sizeof(raw), YON_TAG_USER2);
    if (raw_slot == YON_HEAP_SLOT_INVALID) return 0;
    orb_count++;
    if (orbital_raw_slots_n < YON_HEAP_N_SLOTS)
        orbital_raw_slots[orbital_raw_slots_n++] = raw_slot;
    return 1;
}

static void orb_clear_dual(void) {
    sat_heap_ensure();
    yon_xheap_reset(g_sat_heap);
    orb_count = 0;
    orbital_raw_slots_n = 0;
}

/* Helper: read the raw uint64 from the xheap slot. */
static inline uint64_t orb_raw_at(uint32_t slot_id) {
    const yon_xheap_slot_t *s = yon_xheap_get(g_sat_heap, slot_id);
    if (!s) return 0;
    const void *p = yon_xheap_slot_payload(g_sat_heap, s);
    return p ? *(const uint64_t*)p : 0;
}

static void dimacs_run_orbital_wavefront(void) {
    ensure_init();
    orb_clear_dual();
    orb_try_insert(0ull, dimacs_n_vars);
    uint64_t R_size_prev = 1;
    double max_o = 0.0, sum_o = 0.0;
    uint32_t k_active = 0;
    dimacs_orbital_o_trace_len = 0;
    dimacs_orbital_rounds = 0;

    for (uint32_t i = 0; i < dimacs_G; i++) {
        if (orb_count >= 1000000u) break;
        uint64_t a = dimacs_clauses[i];
        uint32_t n_now = orbital_raw_slots_n;
        for (uint32_t j = 0; j < n_now && orb_count < 1000000u; j++) {
            uint64_t s = orb_raw_at(orbital_raw_slots[j]);
            uint64_t s_or = s | a;
            if (s_or != s) orb_try_insert(s_or, dimacs_n_vars);
        }
        uint64_t R_size_now = orb_count;
        double delta = (double)(R_size_now - R_size_prev);
        double o_i = delta / (1.0 + (double)R_size_prev);
        if (o_i > 0.1) k_active++;
        if (o_i > max_o) max_o = o_i;
        sum_o += o_i;
        if (dimacs_orbital_o_trace_len < 1024)
            dimacs_orbital_o_trace[dimacs_orbital_o_trace_len++] = o_i;
        dimacs_orbital_rounds = i + 1;
        R_size_prev = R_size_now;
    }

    dimacs_orbital_metric_R = (double)R_size_prev;
    dimacs_orbital_metric_k = (double)k_active;
    dimacs_orbital_metric_max_o = max_o;
    dimacs_orbital_metric_sum_o = sum_o;
}

double yon_rt_sat_dimacs_uf20_orbital(double idx_d, double metric_id_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return -1.0;
    snprintf(path, sizeof(path), "%s/uf20/uf20-0%d.cnf", SATLIB_BASE, idx);
    static char cached[1024] = "";
    if (strcmp(cached, path) != 0) {
        if (!dimacs_load(path)) return -1.0;
        dimacs_run_orbital_wavefront();
        strncpy(cached, path, sizeof(cached)-1);
        cached[sizeof(cached)-1] = 0;
    }
    uint32_t m = (uint32_t)metric_id_d;
    switch (m) {
        case 1: return dimacs_orbital_metric_R;
        case 2: return dimacs_orbital_metric_k;
        case 3: return dimacs_orbital_metric_max_o * 1000.0;
        case 4: return dimacs_orbital_metric_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        case 7: return (double)dimacs_orbital_rounds;
        default: return -1.0;
    }
}

double yon_rt_sat_dimacs_orbital_o_at(double round_d) {
    uint32_t r = (uint32_t)round_d;
    if (r < 1 || r > dimacs_orbital_o_trace_len) return -1.0;
    return dimacs_orbital_o_trace[r-1] * 1000.0;
}

double yon_rt_sat_dimacs_uf50_orbital(double idx_d, double metric_id_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return -1.0;
    snprintf(path, sizeof(path), "%s/uf50/uf50-0%d.cnf", SATLIB_BASE, idx);
    static char cached[1024] = "";
    if (strcmp(cached, path) != 0) {
        if (!dimacs_load(path)) return -1.0;
        dimacs_run_orbital_wavefront();
        strncpy(cached, path, sizeof(cached)-1);
        cached[sizeof(cached)-1] = 0;
    }
    uint32_t m = (uint32_t)metric_id_d;
    switch (m) {
        case 1: return dimacs_orbital_metric_R;
        case 2: return dimacs_orbital_metric_k;
        case 3: return dimacs_orbital_metric_max_o * 1000.0;
        case 4: return dimacs_orbital_metric_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        case 7: return (double)dimacs_orbital_rounds;
        default: return -1.0;
    }
}

/* ============================================================== */
/* Leech wavefront: embedding 2n->24 + G_24 canon                 */
/* ============================================================== */

/* Embedding 2n_bit -> 24 bits via XOR-fold.
 * For 2n <= 24: pad with zeros.
 * For 2n > 24: XOR-fold blocks onto 24 bits.
 *
 * Linear (= preserves the OR-monoid structure modulo the fold).
 *
 * Note: the XOR fold breaks OR-distributivity (OR and XOR differ). So the
 * wavefront in 24-bit space is NOT a correct projection of the 2n-bit
 * wavefront, it is an approximation.
 *
 * To be precise, one should use an OR-fold: bit i (out) = OR of all bits
 * i, i+24, i+48, ... (in). But the OR-fold collapses a lot (each bit becomes 1
 * with high probability).
 *
 * Better solution: 2n-fold via OR but the remainder in the 24-bit
 * canonicalization. Trade-off accepted. */

static uint32_t embed_2n_to_24(uint64_t state, uint32_t n_vars) {
    uint32_t bits_2n = 2u * n_vars;
    if (bits_2n <= 24u) {
        return (uint32_t)(state & 0xFFFFFFu);
    }
    /* OR-fold: bit i (out) = OR bit i, i+24, i+48 in input */
    uint32_t out = 0;
    for (uint32_t i = 0; i < 24u; i++) {
        uint32_t bit_set = 0;
        for (uint32_t k = 0; k * 24u + i < bits_2n; k++) {
            if (state & (1ull << (k * 24u + i))) {
                bit_set = 1;
                break;
            }
        }
        if (bit_set) out |= (1u << i);
    }
    return out;
}

/* Canonical state = (embed_2n_to_24(state) under G_24 syndrome) */
extern uint32_t mat24_syndrome(uint32_t v, uint32_t u);

static uint32_t leech_canonicalize_2n(uint64_t state, uint32_t n_vars) {
    uint32_t v24 = embed_2n_to_24(state, n_vars);
    return mat24_syndrome(v24, 0);
}

static double dimacs_leech_R = 0.0;
static double dimacs_leech_k = 0.0;
static double dimacs_leech_max_o = 0.0;
static double dimacs_leech_sum_o = 0.0;
static double dimacs_leech_o_trace[1024];
static uint32_t dimacs_leech_o_trace_len = 0;
static uint32_t dimacs_leech_rounds = 0;

/* === Leech xheap migration: leech_set[1M] + leech_raw_frontier[2M] removed.
 * Dedup via g_sat_heap content_index (memcmp). The slot-ID array keeps
 * insertion order for snapshot semantics. */
static uint32_t leech_raw_slots[YON_HEAP_N_SLOTS];
static uint32_t leech_raw_slots_n = 0;
static uint32_t leech_count = 0;

static int leech_try_insert(uint64_t raw, uint32_t n_vars) {
    uint32_t canon = leech_canonicalize_2n(raw, n_vars);
    bool was_new = false;
    /* canon is 32-bit, stored as 4 bytes distinct from the 8-byte raw so that
     * canon and raw do not collide even if the values are equal. */
    uint32_t canon_slot = yon_xheap_put_or_get(g_sat_heap, &canon, sizeof(canon),
                                                YON_TAG_USER1, &was_new);
    if (canon_slot == YON_HEAP_SLOT_INVALID) return 0;
    if (!was_new) return 0;
    uint32_t raw_slot = yon_xheap_put(g_sat_heap, &raw, sizeof(raw), YON_TAG_USER2);
    if (raw_slot == YON_HEAP_SLOT_INVALID) return 0;
    leech_count++;
    if (leech_raw_slots_n < YON_HEAP_N_SLOTS)
        leech_raw_slots[leech_raw_slots_n++] = raw_slot;
    return 1;
}

static void leech_clear(void) {
    sat_heap_ensure();
    yon_xheap_reset(g_sat_heap);
    leech_count = 0;
    leech_raw_slots_n = 0;
}

static inline uint64_t leech_raw_at(uint32_t slot_id) {
    const yon_xheap_slot_t *s = yon_xheap_get(g_sat_heap, slot_id);
    if (!s) return 0;
    const void *p = yon_xheap_slot_payload(g_sat_heap, s);
    return p ? *(const uint64_t*)p : 0;
}

static void dimacs_run_leech_wavefront(void) {
    ds_ensure_init();  /* needed for mat24 init */
    leech_clear();
    leech_try_insert(0ull, dimacs_n_vars);
    uint64_t R_size_prev = 1;
    double max_o = 0.0, sum_o = 0.0;
    uint32_t k_active = 0;
    dimacs_leech_o_trace_len = 0;
    dimacs_leech_rounds = 0;

    for (uint32_t i = 0; i < dimacs_G; i++) {
        if (leech_count >= 500000u) break;
        uint64_t a = dimacs_clauses[i];
        uint32_t n_now = leech_raw_slots_n;
        for (uint32_t j = 0; j < n_now && leech_count < 500000u; j++) {
            uint64_t s = leech_raw_at(leech_raw_slots[j]);
            uint64_t s_or = s | a;
            if (s_or != s) leech_try_insert(s_or, dimacs_n_vars);
        }
        uint64_t R_size_now = leech_count;
        double delta = (double)(R_size_now - R_size_prev);
        double o_i = delta / (1.0 + (double)R_size_prev);
        if (o_i > 0.1) k_active++;
        if (o_i > max_o) max_o = o_i;
        sum_o += o_i;
        if (dimacs_leech_o_trace_len < 1024)
            dimacs_leech_o_trace[dimacs_leech_o_trace_len++] = o_i;
        dimacs_leech_rounds = i + 1;
        R_size_prev = R_size_now;
    }

    dimacs_leech_R = (double)R_size_prev;
    dimacs_leech_k = (double)k_active;
    dimacs_leech_max_o = max_o;
    dimacs_leech_sum_o = sum_o;
}

double yon_rt_sat_dimacs_uf20_leech(double idx_d, double metric_id_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return -1.0;
    snprintf(path, sizeof(path), "%s/uf20/uf20-0%d.cnf", SATLIB_BASE, idx);
    static char cached[1024] = "";
    if (strcmp(cached, path) != 0) {
        if (!dimacs_load(path)) return -1.0;
        dimacs_run_leech_wavefront();
        strncpy(cached, path, sizeof(cached)-1);
        cached[sizeof(cached)-1] = 0;
    }
    uint32_t m = (uint32_t)metric_id_d;
    switch (m) {
        case 1: return dimacs_leech_R;
        case 2: return dimacs_leech_k;
        case 3: return dimacs_leech_max_o * 1000.0;
        case 4: return dimacs_leech_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        case 7: return (double)dimacs_leech_rounds;
        default: return -1.0;
    }
}

double yon_rt_sat_dimacs_uf50_leech(double idx_d, double metric_id_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return -1.0;
    snprintf(path, sizeof(path), "%s/uf50/uf50-0%d.cnf", SATLIB_BASE, idx);
    static char cached[1024] = "";
    if (strcmp(cached, path) != 0) {
        if (!dimacs_load(path)) return -1.0;
        dimacs_run_leech_wavefront();
        strncpy(cached, path, sizeof(cached)-1);
        cached[sizeof(cached)-1] = 0;
    }
    uint32_t m = (uint32_t)metric_id_d;
    switch (m) {
        case 1: return dimacs_leech_R;
        case 2: return dimacs_leech_k;
        case 3: return dimacs_leech_max_o * 1000.0;
        case 4: return dimacs_leech_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        case 7: return (double)dimacs_leech_rounds;
        default: return -1.0;
    }
}

double yon_rt_sat_dimacs_leech_o_at(double round_d) {
    uint32_t r = (uint32_t)round_d;
    if (r < 1 || r > dimacs_leech_o_trace_len) return -1.0;
    return dimacs_leech_o_trace[r-1] * 1000.0;
}

/* ============================================================== */
/* Co_0 wavefront: canon via Conway Co_0 reduction               */
/* ============================================================== */

static double dimacs_co0_R = 0.0;
static double dimacs_co0_k = 0.0;
static double dimacs_co0_max_o = 0.0;
static double dimacs_co0_sum_o = 0.0;
static double dimacs_co0_o_trace[1024];
static uint32_t dimacs_co0_o_trace_len = 0;
static uint32_t dimacs_co0_rounds = 0;

/* === Leech xheap migration: co0_set[1M] + co0_raw_frontier[2M] removed.
 * Dedup via g_sat_heap content_index. */
static uint32_t co0_raw_slots[YON_HEAP_N_SLOTS];
static uint32_t co0_raw_slots_n = 0;
static uint32_t co0_count = 0;

static uint32_t co0_canonicalize_2n(uint64_t state, uint32_t n_vars) {
    uint32_t v24 = embed_2n_to_24(state, n_vars);
    /* Exact Co_0: full canonical reduction via reduce_type2 (zero parameters,
     * no truncated BFS). Replaces the old co0_bfs_explore(v24, 50) that had an
     * arbitrary cap and gave silent under-merge in the prover. If v24 is not
     * type-2, we keep v24 (correct under-merge, never spurious). */
    extern int32_t gen_leech2_reduce_type2(uint32_t, uint32_t *);
    extern uint32_t gen_leech2_op_word_leech2(uint32_t, uint32_t *, uint32_t, uint32_t);
    uint32_t g[8];
    int32_t len = gen_leech2_reduce_type2(v24, g);
    if (len < 0) return v24;
    return gen_leech2_op_word_leech2(v24, g, (uint32_t)len, 0);
}

static int co0_try_insert(uint64_t raw, uint32_t n_vars) {
    uint32_t canon = co0_canonicalize_2n(raw, n_vars);
    bool was_new = false;
    uint32_t canon_slot = yon_xheap_put_or_get(g_sat_heap, &canon, sizeof(canon),
                                                YON_TAG_USER1, &was_new);
    if (canon_slot == YON_HEAP_SLOT_INVALID) return 0;
    if (!was_new) return 0;
    uint32_t raw_slot = yon_xheap_put(g_sat_heap, &raw, sizeof(raw), YON_TAG_USER2);
    if (raw_slot == YON_HEAP_SLOT_INVALID) return 0;
    co0_count++;
    if (co0_raw_slots_n < YON_HEAP_N_SLOTS)
        co0_raw_slots[co0_raw_slots_n++] = raw_slot;
    return 1;
}

static void co0_clear(void) {
    sat_heap_ensure();
    yon_xheap_reset(g_sat_heap);
    co0_count = 0;
    co0_raw_slots_n = 0;
}

static inline uint64_t co0_raw_at(uint32_t slot_id) {
    const yon_xheap_slot_t *s = yon_xheap_get(g_sat_heap, slot_id);
    if (!s) return 0;
    const void *p = yon_xheap_slot_payload(g_sat_heap, s);
    return p ? *(const uint64_t*)p : 0;
}

static void dimacs_run_co0_wavefront(void) {
    ds_ensure_init();
    co0_clear();
    co0_try_insert(0ull, dimacs_n_vars);
    uint64_t R_size_prev = 1;
    double max_o = 0.0, sum_o = 0.0;
    uint32_t k_active = 0;
    dimacs_co0_o_trace_len = 0;
    dimacs_co0_rounds = 0;

    for (uint32_t i = 0; i < dimacs_G; i++) {
        if (co0_count >= 200000u) break;
        uint64_t a = dimacs_clauses[i];
        uint32_t n_now = co0_raw_slots_n;
        for (uint32_t j = 0; j < n_now && co0_count < 200000u; j++) {
            uint64_t s = co0_raw_at(co0_raw_slots[j]);
            uint64_t s_or = s | a;
            if (s_or != s) co0_try_insert(s_or, dimacs_n_vars);
        }
        uint64_t R_size_now = co0_count;
        double delta = (double)(R_size_now - R_size_prev);
        double o_i = delta / (1.0 + (double)R_size_prev);
        if (o_i > 0.1) k_active++;
        if (o_i > max_o) max_o = o_i;
        sum_o += o_i;
        if (dimacs_co0_o_trace_len < 1024)
            dimacs_co0_o_trace[dimacs_co0_o_trace_len++] = o_i;
        dimacs_co0_rounds = i + 1;
        R_size_prev = R_size_now;
    }

    dimacs_co0_R = (double)R_size_prev;
    dimacs_co0_k = (double)k_active;
    dimacs_co0_max_o = max_o;
    dimacs_co0_sum_o = sum_o;
}

double yon_rt_sat_dimacs_uf20_co0(double idx_d, double metric_id_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return -1.0;
    snprintf(path, sizeof(path), "%s/uf20/uf20-0%d.cnf", SATLIB_BASE, idx);
    static char cached[1024] = "";
    if (strcmp(cached, path) != 0) {
        if (!dimacs_load(path)) return -1.0;
        dimacs_run_co0_wavefront();
        strncpy(cached, path, sizeof(cached)-1);
        cached[sizeof(cached)-1] = 0;
    }
    uint32_t m = (uint32_t)metric_id_d;
    switch (m) {
        case 1: return dimacs_co0_R;
        case 2: return dimacs_co0_k;
        case 3: return dimacs_co0_max_o * 1000.0;
        case 4: return dimacs_co0_sum_o * 1000.0;
        case 5: return (double)dimacs_G;
        case 6: return (double)dimacs_n_vars;
        case 7: return (double)dimacs_co0_rounds;
        default: return -1.0;
    }
}

/* ============================================================== */
/* DIMACS primitives accessibili da Yon     */
/* nativo. Carica + espone clausole come number 64-bit packed.    */
/* ============================================================== */

double yon_rt_dimacs_uf20_load(double idx_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return 0.0;
    snprintf(path, sizeof(path), "%s/uf20/uf20-0%d.cnf", SATLIB_BASE, idx);
    if (!dimacs_load(path)) return 0.0;
    return 1.0;  /* loaded */
}

double yon_rt_dimacs_uf50_load(double idx_d) {
    char path[1024];
    int idx = (int)idx_d;
    if (idx < 1 || idx > 1000) return 0.0;
    snprintf(path, sizeof(path), "%s/uf50/uf50-0%d.cnf", SATLIB_BASE, idx);
    if (!dimacs_load(path)) return 0.0;
    return 1.0;
}

double yon_rt_dimacs_n_vars(void) { return (double)dimacs_n_vars; }
double yon_rt_dimacs_G(void) { return (double)dimacs_G; }

double yon_rt_dimacs_clause(double idx_d) {
    int i = (int)idx_d;
    if (i < 0 || i >= (int)dimacs_G) return 0.0;
    /* Return clause as 64-bit packed double */
    return (double)dimacs_clauses[i];
}

/* Seq.range(n) -> List [0, 1, ..., n-1] */
double yon_rt_seq_range(double n_d) {
    int n = (int)n_d;
    if (n <= 0) return yon_rt_list_empty(0.0);
    double lst = yon_rt_list_empty(0.0);
    /* Build the list in reverse so iteration is 0..n-1 */
    for (int i = n - 1; i >= 0; i--) {
        lst = yon_rt_list_cons((double)i, lst);
    }
    return lst;
}

/* ============================================================== */
/* HashSet.add_canon_sn — 64-bit state  */
/* canonicalization via S_n 4-tuple count, using the current      */
/* dimacs_n_vars. For a native SAT wavefront compatible with C.   */
/* ============================================================== */

extern uint32_t mat24_syndrome(uint32_t v, uint32_t u);

double yon_rt_hashset_add_canon_sn(double set_id, double value_d) {
    extern uint32_t dimacs_n_vars;
    if (dimacs_n_vars == 0) {
        /* Fallback: identity canon */
        return yon_rt_hashset_orbital_add_with(set_id, value_d, 0.0);
    }
    /* value_d can represent up to 2^53 — enough for UF20 (40-bit) */
    uint64_t v = (uint64_t)value_d;
    uint64_t canon = orbital_canonicalize(v, dimacs_n_vars);
    /* canon is a 64-bit unique. Use content-addressed xheap_put: same canon -> same slot. */
    ds_ensure_init();
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &canon, sizeof(canon), YON_TAG_USER1);
    return yon_rt_hashset_orbital_add_with(set_id, (double)slot, 0.0);
}

/* Bits.bor_64 - OR su 64 bit per SAT 2n>32. */
double yon_rt_bits_or_64(double a, double b) {
    return (double)((uint64_t)a | (uint64_t)b);
}
double yon_rt_bits_and_64(double a, double b) {
    return (double)((uint64_t)a & (uint64_t)b);
}
double yon_rt_bits_xor_64(double a, double b) {
    return (double)((uint64_t)a ^ (uint64_t)b);
}

/* HashSet.try_add — returns 1.0 if new, 0.0 if already present.
 * Needed for the orbital wavefront pattern with a dual structure (raw + canon)
 * all in Yon native using the Leech allocator (xheap). */
double yon_rt_hashset_try_add(double set_id, double elem) {
    ds_ensure_init();
    ds_hashset_t *hs = (set_id < 0.5) ? NULL : hashset_lookup(set_id);
    if (!hs) return -1.0;  /* error: invalid set_id */
    if ((uint64_t)hs->n_entries * 10u >= (uint64_t)hs->dir_slots * 7u) {
        (void)hashset_grow(hs);
    }
    uint32_t h = hash_f64(elem);
    for (uint32_t i = 0; i < hs->dir_slots; i++) {
        uint32_t idx = (h + i) % hs->dir_slots;
        if (!hs_bit_get(hs->occupied, idx)) {
            hs->keys[idx] = elem;
            hs_bit_set(hs->occupied, idx);
            hs->n_entries++;
            return 1.0;  /* new */
        }
        if (hs->keys[idx] == elem) return 0.0;  /* already present */
    }
    return -1.0;  /* directory full */
}

/* HashSet.try_add_canon_sn: try_add with S_n canonicalization applied.
 * Returns 1.0 if canon was new, 0.0 if already present. */
double yon_rt_hashset_try_add_canon_sn(double set_id, double raw_value_d) {
    extern uint32_t dimacs_n_vars;
    if (dimacs_n_vars == 0) {
        return yon_rt_hashset_try_add(set_id, raw_value_d);
    }
    uint64_t v = (uint64_t)raw_value_d;
    uint64_t canon = orbital_canonicalize(v, dimacs_n_vars);
    ds_ensure_init();
    uint32_t slot = yon_xheap_put_chain(g_ds_heap, &canon, sizeof(canon), YON_TAG_USER1);
    return yon_rt_hashset_try_add(set_id, (double)slot);
}

/* HashSet.at_bucket / dir_capacity.
 * Enable ZERO-ALLOC iteration over the HashSet keys[] via
 * outer loop (while in Yon). No to_list, niente cons cells.
 * Critico per multi-run: lo xheap non si esaurisce. */
double yon_rt_hashset_at_bucket(double set_id, double idx_d) {
    ds_hashset_t *hs = hashset_lookup(set_id);
    if (!hs) return -1.0;
    uint32_t idx = (uint32_t)idx_d;
    if (idx >= hs->dir_slots) return -1.0;
    if (!hs_bit_get(hs->occupied, idx)) return -1.0;
    return hs->keys[idx];
}

/* Directory capacity of the given set (dynamic, per-set). */
double yon_rt_hashset_dir_capacity(double set_id) {
    ds_hashset_t *hs = hashset_lookup(set_id);
    if (!hs) return 0.0;
    return (double)hs->dir_slots;
}

/* ============================================================== */
/* Wire DTO transport, seal 2: recursive length-prefixed frames    */
/* ============================================================== */
/* The frame is [u32 schema_id][u32 payload_len][payload]. The payload
 * concatenates the fields in declaration order, positional, untagged: a
 * scalar is its 8 raw bytes, a string is [u32 len][len bytes]. The schema_id
 * (stamped on the instance by yon_rt_new_v, carried at the frame head) finds
 * the descriptor and is the one cross-process type guard. Length prefixes are
 * u32 native-endian: the shm wire is one machine, one build, so no swap, and a
 * fixed width keeps every read trivially bounded. Both halves of the wormhole
 * are generic runtime, so both recover the descriptor here at runtime. */

#define YON_WIRE_MAX_SCHEMAS 256u
#define YON_WIRE_MAX_FIELDS  64u

typedef struct {
    uint32_t       schema_id;
    uint32_t       n_fields;
    const uint8_t *tags;   /* n_fields bytes, static in the binary */
    int            used;
} yon_wire_schema_t;

static yon_wire_schema_t g_wire_schemas[YON_WIRE_MAX_SCHEMAS];
static uint32_t g_wire_n_schemas = 0;

void yon_rt_register_schema(uint32_t schema_id, uint32_t n_fields,
                            const uint8_t *tags) {
    for (uint32_t i = 0; i < g_wire_n_schemas; i++) {
        if (g_wire_schemas[i].used && g_wire_schemas[i].schema_id == schema_id) {
            g_wire_schemas[i].n_fields = n_fields;  /* idempotent update */
            g_wire_schemas[i].tags = tags;
            return;
        }
    }
    if (g_wire_n_schemas >= YON_WIRE_MAX_SCHEMAS) {
        fprintf(stderr, "[YON-RT] register_schema: table full (id=%u)\n", schema_id);
        return;
    }
    yon_wire_schema_t *e = &g_wire_schemas[g_wire_n_schemas++];
    e->schema_id = schema_id;
    e->n_fields  = n_fields;
    e->tags      = tags;
    e->used      = 1;
}

static const yon_wire_schema_t *yon_wire_lookup(uint32_t schema_id) {
    for (uint32_t i = 0; i < g_wire_n_schemas; i++)
        if (g_wire_schemas[i].used && g_wire_schemas[i].schema_id == schema_id)
            return &g_wire_schemas[i];
    return NULL;
}

int32_t yon_rt_serialize(yon_section_t sec, void *out_buf, uint32_t cap) {
    ensure_init();
    uint32_t heap_id  = yon_section_heap(sec);
    uint32_t slot_idx = yon_section_slot(sec);
    yon_xheap_t *h = heap_for(heap_id);
    const yon_xheap_slot_t *slot = yon_xheap_get(h, slot_idx);
    if (!slot || slot->payload_offset == 0) return -1;
    uint32_t schema_id = slot->schema_version;
    const yon_wire_schema_t *sc = yon_wire_lookup(schema_id);
    if (!sc) {
        fprintf(stderr, "[YON-RT] serialize: unregistered schema id=%u\n", schema_id);
        return -1;
    }
    if (sc->n_fields > YON_WIRE_MAX_FIELDS) return -1;

    /* The instance payload is n_fields * 8 bytes, one f64 slot per field. */
    uint8_t inst[YON_WIRE_MAX_FIELDS * 8];
    int32_t pn = yon_rt_flatten(sec, inst, sizeof(inst));
    if (pn < 0 || (uint32_t)pn != sc->n_fields * 8u) return -1;

    uint8_t *out = (uint8_t *)out_buf;
    const uint32_t hdr = 8u;     /* schema_id + payload_len */
    if (cap < hdr) return -1;
    uint32_t w = hdr;            /* payload starts after the header */
    for (uint32_t i = 0; i < sc->n_fields; i++) {
        uint32_t off = i * 8u;
        if (sc->tags[i] == YON_WIRE_TAG_SCALAR) {
            if (w + 8u > cap) return -1;
            memcpy(out + w, inst + off, 8u);
            w += 8u;
        } else if (sc->tags[i] == YON_WIRE_TAG_STRING) {
            double sid;
            memcpy(&sid, inst + off, 8u);
            const char *p = yon_ds_cstr(sid);
            uint32_t slen = p ? (uint32_t)strlen(p) : 0u;
            if (w + 4u + slen > cap) return -1;
            memcpy(out + w, &slen, 4u); w += 4u;
            if (slen) memcpy(out + w, p, slen);
            w += slen;
        } else if (sc->tags[i] == YON_WIRE_TAG_NESTED) {
            /* nested place: the field slot holds the sub-section's coordinate
             * (heap is the default in-process heap). Recurse, inlining the
             * sub-frame ([sub_schema_id][sub_payload_len][sub_payload]); the
             * sub-instance carries its own schema id, so the registry resolves
             * the sub-descriptor on the way back. */
            int64_t raw;
            memcpy(&raw, inst + off, 8u);
            yon_section_t sub = yon_section_pack(YON_HEAP_ID_DEFAULT, (uint32_t)raw);
            int32_t sn = yon_rt_serialize(sub, out + w, cap - w);
            if (sn < 0) return -1;
            w += (uint32_t)sn;
        } else {
            fprintf(stderr, "[YON-RT] serialize: tag %u unsupported at this seal\n",
                    (unsigned)sc->tags[i]);
            return -1;
        }
    }
    uint32_t payload_len = w - hdr;
    memcpy(out + 0, &schema_id,   4u);
    memcpy(out + 4, &payload_len, 4u);
    return (int32_t)w;
}

yon_section_t yon_rt_deserialize(const void *in_buf, uint32_t len,
                                 uint32_t heap_id) {
    ensure_init();
    if (len < 8u) return YON_SECTION_INVALID;
    const uint8_t *in = (const uint8_t *)in_buf;
    uint32_t schema_id, payload_len;
    memcpy(&schema_id,   in + 0, 4u);
    memcpy(&payload_len, in + 4, 4u);
    if ((uint64_t)8u + payload_len > (uint64_t)len) return YON_SECTION_INVALID;
    const yon_wire_schema_t *sc = yon_wire_lookup(schema_id);
    if (!sc) {
        fprintf(stderr, "[YON-RT] deserialize: unregistered schema id=%u\n", schema_id);
        return YON_SECTION_INVALID;
    }
    if (sc->n_fields > YON_WIRE_MAX_FIELDS) return YON_SECTION_INVALID;

    uint8_t inst[YON_WIRE_MAX_FIELDS * 8];
    const uint8_t *p = in + 8u;
    uint32_t cur = 0u;
    for (uint32_t i = 0; i < sc->n_fields; i++) {
        uint32_t off = i * 8u;
        if (sc->tags[i] == YON_WIRE_TAG_SCALAR) {
            if (cur + 8u > payload_len) return YON_SECTION_INVALID;
            memcpy(inst + off, p + cur, 8u);
            cur += 8u;
        } else if (sc->tags[i] == YON_WIRE_TAG_STRING) {
            if (cur + 4u > payload_len) return YON_SECTION_INVALID;
            uint32_t slen;
            memcpy(&slen, p + cur, 4u); cur += 4u;
            if ((uint64_t)cur + slen > (uint64_t)payload_len) return YON_SECTION_INVALID;
            char *tmp = (char *)malloc((size_t)slen + 1u);
            if (!tmp) return YON_SECTION_INVALID;
            if (slen) memcpy(tmp, p + cur, slen);
            tmp[slen] = 0;
            double sid = yon_ds_string(tmp);  /* rebuilt in this process's ds */
            free(tmp);
            memcpy(inst + off, &sid, 8u);
            cur += slen;
        } else if (sc->tags[i] == YON_WIRE_TAG_NESTED) {
            /* nested place: the inlined sub-frame begins at p+cur. Read its
             * header to size it, recursively rebuild the sub-place in this
             * heap, and store the sub-handle in the parent slot. */
            if (cur + 8u > payload_len) return YON_SECTION_INVALID;
            uint32_t sub_pl;
            memcpy(&sub_pl, p + cur + 4u, 4u);
            uint32_t sub_frame_len = 8u + sub_pl;
            if ((uint64_t)cur + sub_frame_len > (uint64_t)payload_len)
                return YON_SECTION_INVALID;
            yon_section_t sub = yon_rt_deserialize(p + cur, sub_frame_len, heap_id);
            if (sub == YON_SECTION_INVALID) return YON_SECTION_INVALID;
            memcpy(inst + off, &sub, 8u);
            cur += sub_frame_len;
        } else {
            return YON_SECTION_INVALID;
        }
    }
    if (cur != payload_len) {   /* loud on structural drift, never silent */
        fprintf(stderr,
                "[YON-RT] deserialize: walk consumed %u of %u payload bytes (schema drift)\n",
                cur, payload_len);
        return YON_SECTION_INVALID;
    }
    return yon_rt_new_v(heap_id, inst, sc->n_fields * 8u, NULL, schema_id);
}

/* ============================================================================
 * HSH module + extensions (extended Math, collections, Decidable, exact Co_0).
 * Included in the same translation unit: shares the runtime statics and
 * definitions. Integrated in the canonical tree (it was concatenated at build
 * time). No manual concatenation: the Makefile compiles yon_rt.c.
 * ============================================================================ */
#include "yon_rt_hsh.c"
