/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_map.c — oracle for the yon_rt_map_* family: a HashMap is a value,
 * a persistent hash trie of immutable nodes in the content-addressed heap.
 * Keys and values are both f64; a key is identified by its bits.
 *
 * Signatures grounded on the header / impl:
 *   yon_rt.h  double yon_rt_map_empty(void);
 *                 -> the handle of the empty map (0.0 is the empty map too).
 *   yon_rt.h  double yon_rt_map_put(double map_id, double key, double value);
 *                 -> a NEW map; the one given is unchanged. Same key: the new
 *                    map has the new value, the size unchanged.
 *   yon_rt.h  double yon_rt_map_value(double map_id, double key);
 *                 -> the value at a key the map holds. There is no value at an
 *                    absent key: asked of one, it stops the program (the
 *                    place's `get` asks `has` first and answers Absent).
 *   yon_rt.h  double yon_rt_map_contains(double map_id, double key);
 *                 -> 1.0 if present, 0.0 otherwise.
 *   yon_rt.h  double yon_rt_map_size(double map_id);
 *                 -> the number of entries.
 * Anything that is not a map, given as one, stops the program.
 *
 * Marker on success: "MAP: PASS".
 */

#include "yon_rt.h"
#include <stdio.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

/* 1 iff a call on something that is not a map stops the program. */
static int stops_on_a_bogus_map(void) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "w", stderr);
        (void)yon_rt_map_value(1e9, 10.0);
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT;
}

/* 1 iff asking a map for the value at a key it does not hold stops the
 * program: an absent key has no value, not a 0.0 that would read as one. */
static int stops_on_an_absent_key(double map, double key) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "w", stderr);
        (void)yon_rt_map_value(map, key);
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT;
}

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-48s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

int main(void) {
    printf("=== yon_rt_map_* oracle ===\n");

    /* empty -> valid id, size 0. */
    double m = yon_rt_map_empty();
    check(m != 0.0, "empty() -> valid id (!= 0.0 sentinel)");
    check(yon_rt_map_size(m) == 0.0, "fresh map size == 0");

    /* put then value returns the value. */
    m = yon_rt_map_put(m, 10.0, 111.0);
    m = yon_rt_map_put(m, 20.0, 222.0);
    m = yon_rt_map_put(m, 30.0, 333.0);
    check(yon_rt_map_value(m, 10.0) == 111.0, "value(10) == 111 (put then value)");
    check(yon_rt_map_value(m, 20.0) == 222.0, "value(20) == 222");
    check(yon_rt_map_value(m, 30.0) == 333.0, "value(30) == 333");
    check(yon_rt_map_size(m) == 3.0, "size after 3 distinct puts == 3");

    /* contains: true for a present key, false for an absent one. */
    check(yon_rt_map_contains(m, 20.0) == 1.0, "contains(20) -> 1.0 (present)");
    check(yon_rt_map_contains(m, 99.0) == 0.0, "contains(99) -> 0.0 (absent)");

    /* an absent key has no value. */
    check(stops_on_an_absent_key(m, 99.0), "value(absent) stops the program");

    /* re-put an existing key: a new map with the new value, size unchanged;
     * the map it came from still has the old value. */
    {
        double before = yon_rt_map_size(m);
        double m_old = m;
        m = yon_rt_map_put(m, 20.0, 999.0);
        check(yon_rt_map_size(m) == before, "re-put existing key: size unchanged");
        check(yon_rt_map_value(m, 20.0) == 999.0, "re-put existing key: value updated");
        check(yon_rt_map_value(m_old, 20.0) == 222.0, "the map it came from keeps 222");
    }

    /* a map is a value: put leaves the map it was given, and two maps with
     * the same entries are the same handle, whatever the insertion order. */
    {
        double a = yon_rt_map_put(yon_rt_map_empty(), 1.0, 10.0);
        double b = yon_rt_map_put(a, 2.0, 20.0);
        check(yon_rt_map_size(a) == 1.0 && yon_rt_map_size(b) == 2.0,
              "put leaves the map it was given");
        double c = yon_rt_map_put(yon_rt_map_put(yon_rt_map_empty(), 2.0, 20.0), 1.0, 10.0);
        check(b == c, "same entries, any order -> same handle");
    }

    /* a key is its bits: -0.0 and 0.0 are two keys. */
    {
        double z = yon_rt_map_put(yon_rt_map_put(yon_rt_map_empty(), 0.0, 1.0), -0.0, 2.0);
        check(yon_rt_map_size(z) == 2.0 && yon_rt_map_value(z, -0.0) == 2.0,
              "-0.0 and 0.0 are two keys");
    }

    /* a stored 0.0 is a value like any other: present, and read back. */
    {
        m = yon_rt_map_put(m, 40.0, 0.0);
        check(yon_rt_map_contains(m, 40.0) == 1.0, "contains(key -> 0.0) -> 1.0");
        check(yon_rt_map_value(m, 40.0) == 0.0, "value(key -> 0.0) == 0.0");
    }

    /* negative-key handling: f64 keys are hashed by bit pattern, so distinct
     * doubles are distinct keys including negatives and fractions. */
    {
        m = yon_rt_map_put(m, -7.5, 55.0);
        check(yon_rt_map_value(m, -7.5) == 55.0, "value(-7.5) == 55 (f64 key)");
        check(yon_rt_map_contains(m, -7.5) == 1.0, "contains(-7.5) -> 1.0");
    }

    /* 0.0 is the empty map; anything else that is not a map stops. */
    check(stops_on_an_absent_key(0.0, 10.0), "value on the empty map 0.0 stops");
    check(yon_rt_map_contains(0.0, 10.0) == 0.0, "contains on the empty map -> 0.0");
    check(yon_rt_map_size(0.0) == 0.0, "size of the empty map -> 0.0");
    check(stops_on_a_bogus_map(), "value on something that is not a map stops");

    /* many keys, many versions: every value retrievable, size exact. */
    {
        double g = yon_rt_map_empty();
        int N = 5000;
        for (int i = 0; i < N; i++)
            g = yon_rt_map_put(g, (double)(1000 + i), (double)(i + 1));
        int ok = (yon_rt_map_size(g) == (double)N);
        for (int i = 0; i < N; i++)
            if (yon_rt_map_value(g, (double)(1000 + i)) != (double)(i + 1)) ok = 0;
        check(ok, "5000 distinct keys (each value read back, size == 5000)");
    }

    if (fails == 0) {
        printf("MAP: PASS\n");
        return 0;
    }
    printf("MAP: FAIL (%d)\n", fails);
    return 1;
}
