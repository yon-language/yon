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
 * one after the other: each must open its rings.
 *
 * (2) When the rings cannot be opened the caller hears the true reason. A real
 * call between two processes: the server (yon_rt_rpc2_serve_loop, in a child)
 * has every entry of its map taken, so it cannot open the rings of the call;
 * the caller (yon_rt_rpc2_invoke_typed, in another child) must be refused with
 * the sentence of CallRingsNotOpened and the reason of the kernel, exit code 3,
 * and not with the refusal of a call of another signature. A ring that does
 * not exist gives its own reason too. */
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

extern void  *yon_rt_stream_shm_open(const char *name, uint32_t slot_size, uint32_t capacity, int create);
extern void   yon_rt_stream_shm_close(void *s);
extern int    yon_rt_stream_shm_unlink(const char *name);
extern double yon_rt_stream_shm_open_f64(double id, double create);
extern int    yon_rt_rpc2_with_rings(uint32_t ring_a, uint32_t ring_r, int framed,
                                     void (*body)(void *ctx, int cha, int chr), void *ctx);
extern double yon_rt_rpc2_serve_loop(const char *space_name);
extern double yon_rt_rpc2_invoke_typed(const char *space, double sel, const uint64_t *sig,
                                       double a1, double a2, double a3, double a4);
extern void   yon_rt_register_op_word(double sel, double i, double hi, double lo);
extern int    yon_rt_rpc2_queue_unlink(const char *space_name);
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

/* (2a): a ring nobody made: the reason is the kernel's, and the call does not run */
static int missing_ring(void) {
    int ran = 0;
    int err = yon_rt_rpc2_with_rings(0x80004000u, 0x80004001u, 1, body_ran, &ran);
    if (err != ENOENT || ran != 0) {
        printf("RPC_RINGS: FAIL (a ring nobody made answered %d (%s), ran %d)\n", err, strerror(err), ran);
        return 1;
    }
    return 0;
}

/* (2b): a real call to a server that cannot open the rings */
#define SPACE "RingProbe"
#define SEL 7.0

static void register_op(void) {
    /* [0] the signature root, [1] one argument, [2] the result's root, [3] a number,
       [4] the argument's root, [5] a frame */
    uint64_t sig[6] = { 0x5157000000000001ull, 1, 0x5157000000000002ull, 0, 0x5157000000000003ull, 1 };
    for (int i = 0; i < 6; i++)
        yon_rt_register_op_word(SEL, (double)i, (double)(uint32_t)(sig[i] >> 32), (double)(uint32_t)sig[i]);
}

static int call_refused_with_the_reason(void) {
    int fds[2];
    if (pipe(fds) != 0) return 1;
    pid_t server = fork();
    if (server == 0) {
        dup2(fds[1], 2);
        close(fds[0]);
        for (uint32_t i = 0; i < 64; i++)     /* every entry of its map taken */
            yon_rt_stream_shm_open_f64((double)(0x80005000u + i), 1.0);
        register_op();
        yon_rt_rpc2_serve_loop(SPACE);
        _exit(0);
    }
    pid_t caller = fork();
    if (caller == 0) {
        dup2(fds[1], 2);
        close(fds[0]);
        uint64_t sig[6] = { 0x5157000000000001ull, 1, 0x5157000000000002ull, 0, 0x5157000000000003ull, 1 };
        yon_rt_rpc2_invoke_typed(SPACE, SEL, sig, 1.0, 0.0, 0.0, 0.0);
        _exit(0);                              /* not refused: wrong */
    }
    close(fds[1]);
    int st = 0;
    waitpid(caller, &st, 0);
    kill(server, SIGKILL);
    waitpid(server, NULL, 0);
    char out[4096];
    size_t n = 0;
    ssize_t got;
    while (n < sizeof out - 1 && (got = read(fds[0], out + n, sizeof out - 1 - n)) > 0) n += (size_t)got;
    out[n] = 0;
    close(fds[0]);
    yon_rt_rpc2_queue_unlink(SPACE);
    for (uint32_t i = 0; i < 64; i++) {
        char nm[32];
        ring_name(nm, sizeof nm, 0x80005000u + i);
        yon_rt_stream_shm_unlink(nm);
    }
    char want[256];
    snprintf(want, sizeof want, "cross-Space call refused: Space '%s' could not open the rings of the "
             "session of operation 7: %s", SPACE, strerror(EMFILE));
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 3 || !strstr(out, want) || strstr(out, "signature")) {
        printf("RPC_RINGS: FAIL (the caller exited %d, and said:\n%s)\n", WIFEXITED(st) ? WEXITSTATUS(st) : -1, out);
        return 1;
    }
    return 0;
}

int main(void) {
    yon_rt_world_tag();                       /* one world for every process of the test */
    if (sessions() || missing_ring() || call_refused_with_the_reason()) return 1;
    printf("RPC_RINGS: PASS (%d sessions of one server; a call whose rings cannot be opened is refused "
           "with the reason)\n", SESSIONS);
    return 0;
}
