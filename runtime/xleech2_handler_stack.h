/*
 * xleech2_handler_stack.h — Yon effect handler dispatch table runtime
 *
 * Model (runtime dispatch table):
 *
 *   handler_stack: Vec<(hash, fn_ptr)>
 *   op_apply: handler = lookup(hash); handler(arena, inst_xc, args...)
 *
 * The stack is thread-local (each thread has its own stack of active
 * handlers). LIFO: push installs a handler on top, pop removes it. Lookup
 * scans from the top down (the most recent handler wins).
 *
 * Key: the i64 hash of the trampoline name (e.g. llvm::hash_value of
 * "Account__deposit__trampoline"). The MLIR lowering already emits constant
 * hashes, not strings; dispatch via hash is O(1) for the computation and O(N)
 * for the scan over N active handlers (typically 1-5).
 *
 * Capacity: MAX_DEPTH handlers per thread. Pushing beyond the capacity is a
 * fatal error ([YON-RT-HS-01]); deep recursive handlers indicate a logic bug.
 *
 * Not thread-safe by nature: each thread has its own stack. No mutex is
 * needed. The stacks of different threads are isolated.
 */

#ifndef YON_XLEECH2_HANDLER_STACK_H
#define YON_XLEECH2_HANDLER_STACK_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Maximum capacity of the per-thread handler stack. */
#define YON_HANDLER_STACK_MAX_DEPTH 256

/* Sentinel for a lookup miss. */
#define YON_HANDLER_NOT_FOUND ((void *)0)

/* Install a handler on top of the current thread's stack.
 *
 * - hash: the key (usually llvm::hash_value(trampoline_name))
 * - fn_ptr: an opaque pointer to the trampoline
 *
 * Returns 0 on success, -1 if the stack is full (a fatal error).
 */
int yon_handler_push(uint64_t hash, void *fn_ptr);

/* Remove the most recent handler with key `hash` (usually the one just pushed
 * — the LIFO pattern with with_handler).
 *
 * Returns 0 on success, -1 if the hash is not present.
 *
 * Note: searches from the top down, removing the first occurrence (the most
 * recent). Nested pushes with the same hash are unpushed in reverse order,
 * consistent with the lexical semantics of topos.with_handler.
 */
int yon_handler_pop(uint64_t hash);

/* Look up the active handler for `hash`. Returns fn_ptr or
 * YON_HANDLER_NOT_FOUND. Scans from the top down; the first match wins (the
 * most recent handler shadows the earlier ones).
 */
void *yon_handler_lookup(uint64_t hash);

/* Current depth of the thread's stack (for debugging). */
size_t yon_handler_stack_depth(void);

/* Full reset of the thread's stack. Used in tests and teardown. */
void yon_handler_stack_clear(void);

#ifdef __cplusplus
}
#endif

#endif /* YON_XLEECH2_HANDLER_STACK_H */
