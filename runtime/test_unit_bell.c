/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_bell.c — the doorbell of the wire, between two processes.
 *
 * Two processes share two bells in one shared mapping and play ping-pong on
 * them: each waits for its bell to change, then rings the other's. ROUNDS
 * rounds end only if no ring is lost (a lost wake is a sleeper that never
 * wakes, which the bound of the wait turns into a failure). The game runs on
 * the wait on a word of this system and again on the condition shared between
 * processes, the path of the systems without a wait on a word; one round in
 * eight the ring comes late, after the spin, so the sleep is played as well as
 * the spin. Then: a ring
 * that comes before the wait is not missed, and a wait that nobody rings ends
 * at its deadline.
 *
 *   test_unit_bell               the checks
 *   test_unit_bell --mechanism   the wait this machine uses */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>

extern size_t      yon_bell_size(void);
extern int         yon_bell_init(void *b);
extern uint32_t    yon_bell_count(void *b);
extern int         yon_bell_wait(void *b, uint32_t seen, int64_t deadline_ns);
extern void        yon_bell_ring(void *b);
extern int64_t     yon_bell_deadline_ms(uint32_t ms);
extern int         yon_bell_force_condition;
extern const char *yon_rt_wait_mechanism(void);

#define ROUNDS 20000u

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

/* one side of the game: wait for `mine` to change ROUNDS times from the count
   it had before the game, ringing `theirs` after each (the first side rings
   first) */
static int play(void *mine, void *theirs, int first, uint32_t seen) {
    if (first) yon_bell_ring(theirs);
    for (uint32_t k = 0; k < ROUNDS; k++) {
        int64_t dl = yon_bell_deadline_ms(10000);
        while (yon_bell_count(mine) == seen)
            if (yon_bell_wait(mine, seen, dl) == 2) return 1;   /* a lost ring */
        seen = yon_bell_count(mine);
        /* one round in eight the ring comes after the spin of the waiter, so
           the waiter is asleep when it comes */
        if ((k & 7u) == 7u) usleep(100);
        if (!first || k + 1 < ROUNDS) yon_bell_ring(theirs);
    }
    return 0;
}

static int game(const char *what) {
    size_t sz = yon_bell_size();
    uint8_t *m = mmap(NULL, 2 * sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) { printf("BELL: FAIL (mmap)\n"); return 1; }
    void *a = m, *b = m + sz;
    if (yon_bell_init(a) || yon_bell_init(b)) { printf("BELL: FAIL (init)\n"); return 1; }
    uint32_t seen_a = yon_bell_count(a), seen_b = yon_bell_count(b);
    pid_t pid = fork();
    if (pid == 0) _exit(play(b, a, 0, seen_b));
    int bad = play(a, b, 1, seen_a);
    int st = 0;
    waitpid(pid, &st, 0);
    munmap(m, 2 * sz);
    if (bad || !WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        printf("BELL: FAIL (%s: a ring was lost in %u rounds between two processes)\n", what, ROUNDS);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--mechanism") == 0) {
        printf("%s\n", yon_rt_wait_mechanism());
        return 0;
    }
    const char *mech = yon_rt_wait_mechanism();
    if (game(mech)) return 1;
    yon_bell_force_condition = 1;
    if (game("the condition shared between processes")) return 1;
    for (int c = 0; c < 2; c++) {
        yon_bell_force_condition = c;
        size_t sz = yon_bell_size();
        void *b = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
        yon_bell_init(b);
        uint32_t seen = yon_bell_count(b);
        yon_bell_ring(b);                                    /* before the wait */
        if (yon_bell_wait(b, seen, yon_bell_deadline_ms(10000)) != 0) {
            printf("BELL: FAIL (a ring before the wait was missed)\n");
            return 1;
        }
        seen = yon_bell_count(b);
        int64_t t0 = now_ns();
        int rc = yon_bell_wait(b, seen, yon_bell_deadline_ms(50));   /* nobody rings */
        int64_t dt = now_ns() - t0;
        munmap(b, sz);
        if (rc != 2 || dt < 45000000 || dt > 2000000000) {
            printf("BELL: FAIL (a wait nobody rings answered %d after %lld ns, not 2 after 50 ms)\n",
                   rc, (long long)dt);
            return 1;
        }
    }
    printf("BELL: PASS (%s, and the condition shared between processes)\n", mech);
    return 0;
}
