/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_rpc_rings.c — the rings of the sessions of a server of typed calls.
 *
 * (1) A server serves any number of sessions in its life. Each session of a
 * caller has its own two rings (the argument ring and the result ring); the
 * server attaches them for a call and must let them go after it, or every
 * session it ever served keeps two entries of its map of channels, and the
 * map, of a fixed size, is full after a number of sessions. The sessions here
 * pass through yon_rt_rpc2_with_rings, the server's own handling of the rings,
 * one after the other: each must open its rings. */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

extern void  *yon_rt_stream_shm_open(const char *name, uint32_t slot_size, uint32_t capacity, int create);
extern void   yon_rt_stream_shm_close(void *s);
extern int    yon_rt_stream_shm_unlink(const char *name);
extern int    yon_rt_rpc2_with_rings(uint32_t ring_a, uint32_t ring_r, int framed,
                                     void (*body)(void *ctx, int cha, int chr), void *ctx);
extern const char *yon_rt_world_tag(void);

#define SESSIONS 200
#define RING_BYTES 65536u

static void ring_name(char *out, size_t n, uint32_t id) { snprintf(out, n, "id_%u", id); }

/* the callers make the rings of every session first, in a process of their
   own, before the server serves any: the handles counted are the server's alone */
static int make_rings(uint32_t first, uint32_t count) {
    pid_t pid = fork();
    if (pid == 0) {
        for (uint32_t id = first; id < first + count; id++) {
            char nm[32];
            ring_name(nm, sizeof nm, id);
            void *s = yon_rt_stream_shm_open(nm, 0u, RING_BYTES, 1);
            if (!s) _exit(1);
            yon_rt_stream_shm_close(s);
        }
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) && WEXITSTATUS(st) == 0 ? 0 : -1;
}

static void remove_ring(uint32_t id) {
    char nm[32];
    ring_name(nm, sizeof nm, id);
    yon_rt_stream_shm_unlink(nm);
}

static void body_ran(void *ctx, int cha, int chr) { *(int *)ctx = (cha >= 0 && chr >= 0) ? 1 : -1; }

/* (1): SESSIONS sessions, one call each, through the server's handling */
#define RING0 0x80003000u
static int sessions(void) {
    if (make_rings(RING0, 2u * SESSIONS)) { printf("RPC_RINGS: FAIL (the rings could not be made)\n"); return 1; }
    int bad = 0;
    for (int k = 1; k <= SESSIONS && !bad; k++) {
        uint32_t a = RING0 + 2u * (uint32_t)(k - 1), r = a + 1u;
        int ran = 0;
        int err = yon_rt_rpc2_with_rings(a, r, 1, body_ran, &ran);
        if (err || ran != 1) {
            printf("RPC_RINGS: FAIL (session %d of one server cannot open its rings: %s)\n", k,
                   err ? strerror(err) : "no handle");
            bad = 1;
        }
    }
    for (uint32_t id = RING0; id < RING0 + 2u * SESSIONS; id++) remove_ring(id);
    return bad;
}

int main(void) {
    yon_rt_world_tag();                       /* one world for every process of the test */
    if (sessions()) return 1;
    printf("RPC_RINGS: PASS (%d sessions of one server)\n", SESSIONS);
    return 0;
}
