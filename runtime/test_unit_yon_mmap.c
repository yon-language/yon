/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_yon_mmap.c — oracle for the runtime's sole allocation primitive
 * (yon_mmap.c).
 *
 * PUBLIC API UNDER TEST (yon_mmap.h):
 *   void *yon_map(size_t size)
 *       private, anonymous, kernel-zeroed. ABORTS on failure (a runtime that
 *       cannot map its core structures cannot continue).
 *   void  yon_unmap(void *p, size_t size)
 *       release a region; NULL pointer is a guarded no-op.
 *   void *yon_map_shared(const char *shm_name, size_t size, int create)
 *       named MAP_SHARED region (shm_open + optional ftruncate). Returns NULL on
 *       failure so the caller can fall back.
 *
 * WHAT THIS ASSERTS
 *   - map returns a non-NULL, page-aligned, kernel-zeroed region.
 *   - write-then-read round-trips at the first / middle / last byte.
 *   - several sizes (1 byte, 1 page, 10 pages, 64 MiB) all map, are aligned,
 *     start zeroed, and round-trip data at their boundaries.
 *   - independent maps do not alias (a write to one leaves the other's contents
 *     intact, and their bases differ).
 *   - a large mapping is writable across many demand-paged pages.
 *   - yon_unmap(NULL, n) is a safe no-op.
 *   - EDGE: yon_map(0) — mmap(len=0) fails with EINVAL, so the documented
 *     "abort on failure" contract fires. Verified in a forked child: the child
 *     must terminate abnormally (SIGABRT), never exit(0). This documents that a
 *     zero-size request is NOT silently satisfied.
 *   - yon_map_shared: create -> write -> reopen (create=0) -> the second mapping
 *     observes the first mapping's writes (proves a genuinely shared object);
 *     writes are bidirectional; opening a non-existent name (create=0) -> NULL.
 *     (If the sandbox forbids POSIX shm entirely, the create returns NULL and the
 *     shared sub-tests are skipped with a WARN rather than failing the module.)
 *
 * Marker on success: "YON_MMAP: PASS".
 */

#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE   /* expose shm_open/shm_unlink under strict -std=c11 (macOS) */
#endif
#ifndef _GNU_SOURCE
#define _GNU_SOURCE        /* same on glibc */
#endif

#include "yon_mmap.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/mman.h>   /* shm_unlink */

static int fails = 0;
static void check(int ok, const char *what) {
    printf("  %-58s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

static int is_page_aligned(const void *p) {
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;
    return ((uintptr_t)p & ((uintptr_t)pg - 1)) == 0;
}

int main(void) {
    printf("=== yon_mmap oracle ===\n");
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) pg = 4096;

    /* Basic: one page, aligned, zeroed, round-trip. */
    {
        size_t sz = (size_t)pg;
        unsigned char *p = (unsigned char *)yon_map(sz);
        check(p != NULL, "map(page) -> non-NULL");
        check(is_page_aligned(p), "map(page) -> page-aligned");
        int zeroed = (p[0] == 0 && p[sz / 2] == 0 && p[sz - 1] == 0);
        check(zeroed, "map(page) region is kernel-zeroed");
        p[0] = 0x11; p[sz / 2] = 0x22; p[sz - 1] = 0x33;
        check(p[0] == 0x11 && p[sz / 2] == 0x22 && p[sz - 1] == 0x33,
              "write-then-read round-trips at first/mid/last byte");
        yon_unmap(p, sz);
    }

    /* Several sizes: each maps, is aligned, starts zeroed, round-trips at bounds. */
    {
        size_t sizes[] = { 1, (size_t)pg, (size_t)pg * 10, (size_t)64 * 1024 * 1024 };
        const char *labels[] = { "1 byte", "1 page", "10 pages", "64 MiB" };
        int all_ok = 1;
        for (int i = 0; i < 4; i++) {
            size_t sz = sizes[i];
            unsigned char *p = (unsigned char *)yon_map(sz);
            int ok = (p != NULL) && is_page_aligned(p);
            if (ok) {
                size_t lo = 0, mid = sz / 2, hi = sz - 1;
                if (p[lo] != 0 || p[mid] != 0 || p[hi] != 0) ok = 0;   /* zeroed */
                /* write-then-read each boundary immediately: when sz == 1 the
                 * three offsets alias byte 0, so a single distinct-value check
                 * would be defeated by the last write winning. */
                p[lo]  = 0xA1; if (p[lo]  != 0xA1) ok = 0;
                p[mid] = 0xB2; if (p[mid] != 0xB2) ok = 0;
                p[hi]  = 0xC3; if (p[hi]  != 0xC3) ok = 0;
            }
            if (p) yon_unmap(p, sz);
            if (!ok) all_ok = 0;
            printf("    (%-8s : %s)\n", labels[i],
                   ok ? "map/align/zero/round-trip ok" : "FAILED");
        }
        check(all_ok, "map/round-trip across sizes {1B, 1pg, 10pg, 64MiB}");
    }

    /* Independent maps do not alias. */
    {
        size_t sz = (size_t)pg;
        unsigned char *a = (unsigned char *)yon_map(sz);
        unsigned char *b = (unsigned char *)yon_map(sz);
        check(a && b && a != b, "two maps have distinct base pointers");
        memset(a, 0xAA, sz);
        memset(b, 0xBB, sz);
        int a_intact = 1, b_intact = 1;
        for (size_t k = 0; k < sz; k++) { if (a[k] != 0xAA) a_intact = 0; if (b[k] != 0xBB) b_intact = 0; }
        check(a_intact && b_intact, "writing one map does not disturb the other");
        yon_unmap(a, sz);
        yon_unmap(b, sz);
    }

    /* Large mapping is writable across many demand-paged pages. */
    {
        size_t sz = (size_t)64 * 1024 * 1024;
        unsigned char *p = (unsigned char *)yon_map(sz);
        int ok = (p != NULL);
        if (ok) {
            size_t offs[] = { 0, (size_t)pg * 100, (size_t)pg * 1000,
                              (size_t)pg * 4000, sz - 1 };
            for (int i = 0; i < 5; i++) p[offs[i]] = (unsigned char)(0x40 + i);
            for (int i = 0; i < 5; i++) if (p[offs[i]] != (unsigned char)(0x40 + i)) ok = 0;
            yon_unmap(p, sz);
        }
        check(ok, "64 MiB mapping writable across spread demand-paged pages");
    }

    /* yon_unmap(NULL, n) is a guarded no-op. */
    {
        yon_unmap(NULL, (size_t)pg);      /* must not crash */
        check(1, "unmap(NULL, n) is a safe no-op");
    }

    /* EDGE: yon_map(0) hits the abort-on-failure contract. Verify in a child so
     * the parent survives; the child must NOT exit(0). */
    {
        fflush(NULL);                     /* don't let the child duplicate buffers */
        pid_t pid = fork();
        if (pid == 0) {
            /* child: expected to abort inside yon_map(0). */
            volatile void *q = yon_map(0);
            (void)q;
            _exit(0);                     /* only reached if map(0) unexpectedly succeeds */
        }
        int status = 0;
        (void)waitpid(pid, &status, 0);
        int aborted = WIFSIGNALED(status);
        int sig = aborted ? WTERMSIG(status) : 0;
        int clean_exit0 = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        check(!clean_exit0, "map(0) does NOT silently succeed (child aborts)");
        check(aborted && sig == SIGABRT, "map(0) triggers abort() -> child killed by SIGABRT");
        if (aborted) printf("    (child terminated by signal %d)\n", sig);
    }

    /* Shared mapping: create -> write -> reopen -> observe; plus missing-name. */
    {
        const char *name = "/yon_mm_ut1";
        size_t sz = (size_t)pg;
        shm_unlink(name);                 /* clear any stale object */

        unsigned char *p1 = (unsigned char *)yon_map_shared(name, sz, 1 /*create*/);
        if (p1 == NULL) {
            printf("    (WARN: POSIX shm unavailable in this environment; "
                   "skipping shared-mapping sub-tests)\n");
        } else {
            check(is_page_aligned(p1), "map_shared(create) -> page-aligned");
            p1[0] = 0x5A; p1[sz - 1] = 0xA5;

            unsigned char *p2 = (unsigned char *)yon_map_shared(name, sz, 0 /*open*/);
            check(p2 != NULL, "map_shared(open existing) -> non-NULL");
            if (p2) {
                check(p2 != p1, "second mapping has a distinct virtual address");
                check(p2[0] == 0x5A && p2[sz - 1] == 0xA5,
                      "second mapping observes the first's writes (shared object)");
                p2[1] = 0x77;                      /* write via p2 ... */
                check(p1[1] == 0x77, "write via p2 is visible via p1 (bidirectional)");
                yon_unmap(p2, sz);
            }
            yon_unmap(p1, sz);
            shm_unlink(name);

            /* Opening a now-removed name without create must fail cleanly. */
            unsigned char *p3 = (unsigned char *)yon_map_shared(name, sz, 0 /*open*/);
            check(p3 == NULL, "map_shared(open missing name) -> NULL (no crash)");
            if (p3) { yon_unmap(p3, sz); shm_unlink(name); }
        }
    }

    if (fails == 0) { printf("YON_MMAP: PASS\n"); return 0; }
    printf("YON_MMAP: FAIL (%d)\n", fails);
    return 1;
}
