/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_shm_reopen.c — a channel opened again by its id keeps one mapping.
 *
 * The server of a typed call attaches the two rings of a session (the argument
 * ring and the result ring) at every call that carries a frame, the way
 * rpc2_serve_typed does: yon_rt_stream_shm_open_sized_f64(id, 0, 0) on ids it
 * already holds. Each attach must replace the mapping it had for that id, not
 * add one: the handles of a process are a pool of a fixed size, so a mapping
 * left behind at every call fills the pool after a number of calls, and then a
 * new session finds no handle for its own rings.
 *
 * The test makes the two rings of one session, serves CALLS calls on them, and
 * after each call checks that a new session could still open its two rings. It
 * names the first call after which it could not. */
#include <stdio.h>
#include <stdint.h>

extern void  *yon_rt_stream_shm_open(const char *name, uint32_t slot_size,
                                     uint32_t capacity, int create);
extern void   yon_rt_stream_shm_close(void *s);
extern int    yon_rt_stream_shm_unlink(const char *name);
extern double yon_rt_stream_shm_open_sized_f64(double id, double create, double slot_size);

#define CALLS 200
#define RING_BYTES 65536u

/* a byte ring under the name the id-based open gives it, made the way the
 * caller makes the rings of its session, then let go by this process */
static int make_ring(uint32_t id) {
    char name[32];
    snprintf(name, sizeof name, "id_%u", id);
    void *s = yon_rt_stream_shm_open(name, 0u, RING_BYTES, 1);
    if (!s) return -1;
    yon_rt_stream_shm_close(s);
    return 0;
}

static void remove_ring(uint32_t id) {
    char name[32];
    snprintf(name, sizeof name, "id_%u", id);
    yon_rt_stream_shm_unlink(name);
}

int main(void) {
    const uint32_t ring_a = 0x80000010u, ring_r = 0x80000011u;   /* the session */
    const uint32_t new_a = 0x80000020u, new_r = 0x80000021u;     /* a new session */
    if (make_ring(ring_a) || make_ring(ring_r) || make_ring(new_a) || make_ring(new_r)) {
        printf("SHM_REOPEN: FAIL (the rings could not be made)\n");
        return 1;
    }
    int fell_after = 0;
    for (int call = 1; call <= CALLS && !fell_after; call++) {
        /* the server's half of one call that carries a frame */
        if (yon_rt_stream_shm_open_sized_f64((double)ring_a, 0.0, 0.0) < 0.0
            || yon_rt_stream_shm_open_sized_f64((double)ring_r, 0.0, 0.0) < 0.0) {
            fell_after = call - 1;
            break;
        }
        /* a new session, now: its two rings must still find a handle */
        char na[32], nr[32];
        snprintf(na, sizeof na, "id_%u", new_a);
        snprintf(nr, sizeof nr, "id_%u", new_r);
        void *a = yon_rt_stream_shm_open(na, 0u, RING_BYTES, 0);
        void *r = yon_rt_stream_shm_open(nr, 0u, RING_BYTES, 0);
        if (!a || !r) fell_after = call;
        if (a) yon_rt_stream_shm_close(a);
        if (r) yon_rt_stream_shm_close(r);
    }
    remove_ring(ring_a); remove_ring(ring_r); remove_ring(new_a); remove_ring(new_r);
    if (fell_after) {
        printf("SHM_REOPEN: FAIL (after %d calls a new session cannot open its rings)\n", fell_after);
        return 1;
    }
    printf("SHM_REOPEN: PASS (%d calls, a new session opens its rings after each)\n", CALLS);
    return 0;
}
