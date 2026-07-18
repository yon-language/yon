/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_fold.c — oracle for the reduction/CRDT fold operators (yon_rt.c:487+).
 * These are the per-element combiners the collect path applies when folding a
 * stream of partials. All are pure and side-effect-free on plain memory (no
 * compiled-program context), so they are exact known-answer targets, including the
 * size-guard branches (a mismatched size is a no-op, not a crash).
 *
 * Signatures grounded on the impl (yon_rt.c):
 *   void yon_fold_sum_f64/max_f64/min_f64(acc, new, size)  size must be 8, else no-op
 *   void yon_fold_sum_i64/max_i64/min_i64(acc, new, size)  size must be 8, else no-op
 *   void yon_fold_sum_vec_f64/max_vec_f64(acc, new, size)  size % 8 == 0, element-wise
 *   void yon_fold_or_bitset(acc, new, size)                bitwise OR, u64 bulk + tail
 *
 * Marker on success: "FOLD: PASS".
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

extern void yon_fold_sum_f64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_max_f64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_min_f64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_sum_i64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_max_i64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_min_i64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_sum_vec_f64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_max_vec_f64(void *acc, const void *new_val, uint32_t size);
extern void yon_fold_or_bitset(void *acc, const void *new_val, uint32_t size);

static int fails = 0;
static void check(int ok, const char *what) {
    printf("  %-48s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

int main(void) {
    printf("=== yon_rt fold operators oracle ===\n");
    const uint32_t D = (uint32_t)sizeof(double);
    const uint32_t I = (uint32_t)sizeof(int64_t);

    /* ---- f64 scalar ---- */
    { double a = 1.0, v = 2.0; yon_fold_sum_f64(&a, &v, D); check(a == 3.0, "sum_f64(1,2) == 3"); }
    { double a = 1.0, v = 2.0; yon_fold_max_f64(&a, &v, D); check(a == 2.0, "max_f64(1,2) == 2"); }
    { double a = 5.0, v = 2.0; yon_fold_max_f64(&a, &v, D); check(a == 5.0, "max_f64(5,2) == 5 (keep)"); }
    { double a = 5.0, v = 2.0; yon_fold_min_f64(&a, &v, D); check(a == 2.0, "min_f64(5,2) == 2"); }
    { double a = 1.0, v = 2.0; yon_fold_min_f64(&a, &v, D); check(a == 1.0, "min_f64(1,2) == 1 (keep)"); }
    /* size guard: wrong size is a no-op, not a corruption/crash */
    { double a = 1.0, v = 2.0; yon_fold_sum_f64(&a, &v, 4); check(a == 1.0, "sum_f64 wrong size -> no-op"); }

    /* ---- i64 scalar ---- */
    { int64_t a = 10, v = 5; yon_fold_sum_i64(&a, &v, I); check(a == 15, "sum_i64(10,5) == 15"); }
    { int64_t a = 3, v = 7;  yon_fold_max_i64(&a, &v, I); check(a == 7,  "max_i64(3,7) == 7"); }
    { int64_t a = 7, v = 3;  yon_fold_min_i64(&a, &v, I); check(a == 3,  "min_i64(7,3) == 3"); }
    { int64_t a = 10, v = 5; yon_fold_sum_i64(&a, &v, 3); check(a == 10, "sum_i64 wrong size -> no-op"); }

    /* ---- element-wise f64 vectors ---- */
    { double a[3] = {1,2,3}, v[3] = {10,20,30};
      yon_fold_sum_vec_f64(a, v, 3 * D);
      check(a[0] == 11 && a[1] == 22 && a[2] == 33, "sum_vec_f64 element-wise"); }
    { double a[3] = {1,5,3}, v[3] = {4,2,6};
      yon_fold_max_vec_f64(a, v, 3 * D);
      check(a[0] == 4 && a[1] == 5 && a[2] == 6, "max_vec_f64 element-wise"); }
    /* size guard: not a multiple of 8 -> no-op */
    { double a[2] = {1,2}, v[2] = {9,9};
      yon_fold_sum_vec_f64(a, v, 2 * D - 1);
      check(a[0] == 1 && a[1] == 2, "sum_vec_f64 non-multiple size -> no-op"); }

    /* ---- OR-set bitset CRDT (u64 bulk loop + byte tail loop) ---- */
    { uint8_t a[10], v[10];
      memset(a, 0x0F, 10); memset(v, 0xF0, 10);
      yon_fold_or_bitset(a, v, 10);   /* 1 u64 (0..7) bulk, bytes 8..9 tail */
      int all = 1; for (int i = 0; i < 10; i++) if (a[i] != 0xFF) all = 0;
      check(all, "or_bitset(0x0F, 0xF0)*10 == 0xFF (bulk+tail)"); }
    { uint8_t a[8] = {1,2,4,8,16,32,64,128}, v[8] = {0};
      yon_fold_or_bitset(a, v, 8);
      int same = 1; uint8_t e[8] = {1,2,4,8,16,32,64,128};
      for (int i = 0; i < 8; i++) if (a[i] != e[i]) same = 0;
      check(same, "or_bitset(x, 0) == x (identity)"); }

    if (fails == 0) { printf("FOLD: PASS\n"); return 0; }
    printf("FOLD: FAIL (%d)\n", fails);
    return 1;
}
