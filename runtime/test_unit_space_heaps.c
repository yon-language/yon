/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_space_heaps.c — every Space has its own two heaps.
 *
 * A value is made in the heaps of the current Space: a HashMap's nodes in its
 * FNV chain (a heap of its own, so its heapref names another heap than the
 * entry Space's), an XRelMap's nodes in its Leech store, under a handle that
 * carries the Space: (Space << 37 | name) + 1, an exact integer in the f64. A
 * handle read in another Space is a declared error (exit 3), never a node of
 * that Space read by mistake; a forged name with the wrong Space is refused
 * the same way. A value crosses to another Space by copy (yon_rt_cross_value)
 * and the copy answers like the original, in the heaps of the Space it
 * reached. */
#include "yon_rt.h"
#include "xleech2_heap.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

double yon_rt_map_empty(void);
double yon_rt_map_put(double, double, double);
double yon_rt_map_size(double);
double yon_rt_map_value(double, double);
double yon_rt_xrelmap_empty(void);
double yon_rt_xrelmap_set(double, double, double);
double yon_rt_xrelmap_size(double);
double yon_rt_xrelmap_value(double, double);

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { printf("FAIL %s\n", msg); fails++; } } while (0)

/* run f in a child; its exit status */
static int in_child(void (*f)(double), double arg) {
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) { f(arg); _exit(0); }
    int st = 0;
    waitpid(p, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
static void read_xrel(double h) { (void)yon_rt_xrelmap_size(h); }

#define R_NUM  0x1111u
#define R_XMAP 0x2222u
#define R_MAP  0x3333u

int main(void) {
    yon_rt_init();
    double a = (double)yon_rt_register_space("a");
    static const uint64_t kids[2] = { R_NUM, R_NUM };
    yon_rt_register_type(R_NUM, YON_WIRE_KIND_SCALAR, 0, NULL);
    yon_rt_register_type(R_XMAP, YON_WIRE_KIND_XMAP, 2, kids);
    yon_rt_register_type(R_MAP, YON_WIRE_KIND_MAP, 2, kids);

    /* a map made in the entry Space, one made in Space a */
    double m0 = yon_rt_map_put(yon_rt_map_empty(), 1, 10);
    double here = yon_rt_space_enter(a);
    CHECK(here == 0.0, "the entry Space is Space 0");
    CHECK(yon_rt_space_current() == (int32_t)a, "space_enter makes a current");
    double ma = yon_rt_map_put(yon_rt_map_empty(), 1, 10);
    double xa = yon_rt_xrelmap_set(yon_rt_xrelmap_empty(), 5, 50);
    CHECK(YON_HEAPREF_HEAP_ID((uint32_t)ma) != YON_HEAPREF_HEAP_ID((uint32_t)m0),
          "the same map made in two Spaces lives in two heaps");
    CHECK(((uint64_t)xa - 1u) >> 37 == (uint64_t)a, "an XRelMap handle carries its Space");
    CHECK(xa == (double)(uint64_t)xa && xa < 9007199254740992.0,
          "the handle is an exact integer below 2^53");
    CHECK(yon_rt_xrelmap_value(xa, 5) == 50.0, "read in its own Space it answers");

    /* the copy into the entry Space: made there, it answers there */
    double x0 = yon_rt_cross_value(xa, 0, R_XMAP, 0.0);
    double c0 = yon_rt_cross_value(ma, 0, R_MAP, 0.0);
    yon_rt_space_enter(here);
    CHECK(((uint64_t)x0 - 1u) >> 37 == 0, "the copy carries the entry Space");
    CHECK(yon_rt_xrelmap_size(x0) == 1.0 && yon_rt_xrelmap_value(x0, 5) == 50.0,
          "the XRelMap copy answers like the original");
    CHECK(yon_rt_map_size(c0) == 1.0 && yon_rt_map_value(c0, 1) == 10.0,
          "the HashMap copy answers like the original");

    /* a handle of Space a read in the entry Space: declared error */
    CHECK(in_child(read_xrel, xa) == 3, "a handle of another Space is refused");
    /* a forged name: the right node, the wrong Space */
    double forged = (double)((((uint64_t)a + 1u) << 37) | ((uint64_t)x0 - 1u)) + 1.0;
    CHECK(in_child(read_xrel, forged) == 3, "a name forged with another Space is refused");

    if (fails) { printf("SPACE_HEAPS: FAIL (%d)\n", fails); return 1; }
    printf("SPACE_HEAPS: PASS\n");
    return 0;
}
