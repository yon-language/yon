/*
 * xleech2_handler_stack.c — thread-local dispatch table implementation.
 *
 * Storage: a static thread-local array. No malloc, no lock. One struct per
 * slot with (hash, fn_ptr). An int cursor for the top.
 */

#include "xleech2_handler_stack.h"
#include <stdio.h>
#include <string.h>

typedef struct {
    uint64_t hash;
    void    *fn_ptr;
} yon_handler_entry_t;

/* Thread-local storage: each thread has its own stack. */
static _Thread_local yon_handler_entry_t
    g_stack[YON_HANDLER_STACK_MAX_DEPTH];

/* Index of the next free slot (== current depth). */
static _Thread_local size_t g_top = 0;

int yon_handler_push(uint64_t hash, void *fn_ptr)
{
    if (g_top >= YON_HANDLER_STACK_MAX_DEPTH) {
        fprintf(stderr,
                "[YON-RT-HS-01] yon_handler_push: stack full "
                "(depth=%zu, max=%d). Possible non-terminating handler "
                "recursion.\n",
                g_top, YON_HANDLER_STACK_MAX_DEPTH);
        return -1;
    }
    g_stack[g_top].hash   = hash;
    g_stack[g_top].fn_ptr = fn_ptr;
    g_top++;
    return 0;
}

int yon_handler_pop(uint64_t hash)
{
    /* Scan from the top down to find the first occurrence of `hash`. Remove it
     * by shifting the elements above it down (usually 0 elements: pop is
     * typically of the top).
     */
    if (g_top == 0) {
        fprintf(stderr,
                "[YON-RT-HS-02] yon_handler_pop(%lu): empty stack.\n",
                (unsigned long)hash);
        return -1;
    }
    for (size_t i = g_top; i > 0; --i) {
        size_t idx = i - 1;
        if (g_stack[idx].hash == hash) {
            /* Shift the elements above down. */
            size_t n_above = g_top - i;
            if (n_above > 0) {
                memmove(&g_stack[idx], &g_stack[idx + 1],
                        n_above * sizeof(yon_handler_entry_t));
            }
            g_top--;
            return 0;
        }
    }
    fprintf(stderr,
            "[YON-RT-HS-03] yon_handler_pop(%lu): hash not present "
            "in the stack (depth=%zu).\n",
            (unsigned long)hash, g_top);
    return -1;
}

void *yon_handler_lookup(uint64_t hash)
{
    /* Linear scan from the top down; the most recent handler wins
     * (shadowing). On a typical stack (1-5 handlers) this is as fast as a
     * cache hit.
     */
    for (size_t i = g_top; i > 0; --i) {
        size_t idx = i - 1;
        if (g_stack[idx].hash == hash) {
            return g_stack[idx].fn_ptr;
        }
    }
    return YON_HANDLER_NOT_FOUND;
}

size_t yon_handler_stack_depth(void)
{
    return g_top;
}

void yon_handler_stack_clear(void)
{
    g_top = 0;
}
