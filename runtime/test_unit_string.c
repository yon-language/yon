/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_string.c — oracle for the yon_rt_string_* family (yon_rt.c:6867+).
 *
 * A "String" is an xheap slot on g_ds_heap whose payload is a NUL-terminated C
 * string; the handle travels as an f64 (the slot id). 0.0 is the failure
 * sentinel (invalid id / alloc fail). The only way to mint a String from pure C
 * is yon_rt_string_lit(const char *), which interns the bytes and returns the
 * handle (yon_rt.c:7117). It is content-addressed, so equal bytes share a slot.
 *
 * Signatures grounded on the header / impl:
 *   yon_rt.h:948  double yon_rt_string_concat(double a_id, double b_id);
 *                 -> new slot; 0.0 if either id is invalid (yon_rt.c:6887).
 *   yon_rt.h:947  double yon_rt_string_length(double str_id);
 *                 -> strlen(payload); 0.0 on invalid id (yon_rt.c:6877).
 *   yon_rt.h:950  double yon_rt_string_char_at(double str_id, double idx);
 *                 -> (unsigned char) byte; -1.0 if idx<0 or idx>=len or bad id
 *                    (yon_rt.c:6926, defined sentinel, no OOB read).
 *   yon_rt.h:966  double yon_rt_string_find_char(double s, double cc, double from);
 *                 -> first index >= max(from,0) with that byte; -1.0 if none
 *                    (yon_rt.c:6997).
 *   yon_rt.h:964  double yon_rt_string_parse_number(double str_id);
 *                 -> strtod after skipping leading spaces/tabs; 0.0 on invalid
 *                    id or non-numeric prefix (strtod returns 0.0) (yon_rt.c:6952).
 *   yon_rt.h:965  double yon_rt_string_substring(double s, double start, double len);
 *                 -> new slot. start<0 or start>total -> 0.0; len<0 -> 0;
 *                    start+len>total -> clamped to total-start (yon_rt.c:6964).
 *                    No OOB read past the end.
 *   yon_rt.c:7117 double yon_rt_string_lit(const char *bytes);  (no header decl)
 *
 * Marker on success: "STRING: PASS".
 */

#include "yon_rt.h"
#include <stdio.h>

/* Not in yon_rt.h, but non-static in yon_rt.c:7117. */
extern double yon_rt_string_lit(const char *bytes);

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-44s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

/* Read back a String handle char-by-char into a C buffer for round-trip checks.
 * Uses only the public char_at/length API. */
static int handle_eq_cstr(double h, const char *expect) {
    int len = (int)yon_rt_string_length(h);
    int elen = 0; while (expect[elen]) elen++;
    if (len != elen) return 0;
    for (int i = 0; i < len; i++) {
        double c = yon_rt_string_char_at(h, (double)i);
        if (c != (double)(unsigned char)expect[i]) return 0;
    }
    return 1;
}

int main(void) {
    printf("=== yon_rt_string_* oracle ===\n");

    double hello = yon_rt_string_lit("hello");
    double world = yon_rt_string_lit("world");
    double empty = yon_rt_string_lit("");

    /* lit handles must be valid (non-zero) — 0.0 is the failure sentinel. */
    check(hello != 0.0 && world != 0.0, "lit('hello'),('world') -> valid handles");

    /* length */
    check(yon_rt_string_length(hello) == 5.0, "length('hello') == 5");
    check(yon_rt_string_length(empty) == 0.0, "length('') == 0");
    check(yon_rt_string_length(0.0) == 0.0, "length(invalid id) == 0 (sentinel)");

    /* char_at, in range and the defined out-of-range sentinel (-1.0). */
    check(yon_rt_string_char_at(hello, 0.0) == (double)(unsigned char)'h',
          "char_at('hello',0) == 'h'");
    check(yon_rt_string_char_at(hello, 4.0) == (double)(unsigned char)'o',
          "char_at('hello',4) == 'o'");
    check(yon_rt_string_char_at(hello, 5.0) == -1.0,
          "char_at past end -> -1.0 (no OOB)");
    check(yon_rt_string_char_at(hello, 1000.0) == -1.0,
          "char_at far past end -> -1.0");
    check(yon_rt_string_char_at(hello, -1.0) == -1.0,
          "char_at(-1) -> -1.0");
    check(yon_rt_string_char_at(empty, 0.0) == -1.0,
          "char_at('',0) -> -1.0");

    /* find_char */
    check(yon_rt_string_find_char(hello, (double)'l', 0.0) == 2.0,
          "find_char('hello','l',0) == 2");
    check(yon_rt_string_find_char(hello, (double)'l', 3.0) == 3.0,
          "find_char('hello','l',from=3) == 3");
    check(yon_rt_string_find_char(hello, (double)'z', 0.0) == -1.0,
          "find_char('hello','z') -> -1.0 (absent)");
    check(yon_rt_string_find_char(hello, (double)'h', -5.0) == 0.0,
          "find_char negative from clamps to 0 -> 0");

    /* concat: empty || empty, and a normal pair (round-trip via length+char_at). */
    {
        double ee = yon_rt_string_concat(empty, empty);
        check(yon_rt_string_length(ee) == 0.0 && handle_eq_cstr(ee, ""),
              "concat('','') -> '' (len 0)");
    }
    {
        double hw = yon_rt_string_concat(hello, world);
        check(yon_rt_string_length(hw) == 10.0, "concat len == 10");
        check(handle_eq_cstr(hw, "helloworld"),
              "concat('hello','world') round-trips to 'helloworld'");
    }
    {
        /* concat with empty on one side is identity in content. */
        double he = yon_rt_string_concat(hello, empty);
        check(handle_eq_cstr(he, "hello"), "concat('hello','') -> 'hello'");
    }
    /* concat with an invalid id -> 0.0 sentinel (no crash). */
    check(yon_rt_string_concat(hello, 0.0) == 0.0,
          "concat(valid, invalid) -> 0.0 sentinel");

    /* parse_number: a valid number string, and a non-numeric / empty string. */
    check(yon_rt_string_parse_number(yon_rt_string_lit("42")) == 42.0,
          "parse_number('42') == 42");
    check(yon_rt_string_parse_number(yon_rt_string_lit("-3.5")) == -3.5,
          "parse_number('-3.5') == -3.5");
    check(yon_rt_string_parse_number(yon_rt_string_lit("  7")) == 7.0,
          "parse_number('  7') skips spaces -> 7");
    check(yon_rt_string_parse_number(yon_rt_string_lit("abc")) == 0.0,
          "parse_number('abc') -> 0.0 (defined, no crash)");
    check(yon_rt_string_parse_number(empty) == 0.0,
          "parse_number('') -> 0.0 (defined)");
    check(yon_rt_string_parse_number(0.0) == 0.0,
          "parse_number(invalid id) -> 0.0");

    /* substring: normal, and the edge cases. */
    {
        double mid = yon_rt_string_substring(hello, 1.0, 3.0);
        check(handle_eq_cstr(mid, "ell"), "substring('hello',1,3) == 'ell'");
    }
    {
        /* len 0 -> empty string, not a failure. */
        double z = yon_rt_string_substring(hello, 2.0, 0.0);
        check(z != 0.0 && yon_rt_string_length(z) == 0.0,
              "substring len 0 -> '' (valid empty, no OOB)");
    }
    {
        /* start+len past end -> clamped to total-start (yon_rt.c:6976). */
        double tail = yon_rt_string_substring(hello, 3.0, 1000.0);
        check(handle_eq_cstr(tail, "lo"),
              "substring start=3 len past end -> 'lo' (clamped)");
    }
    {
        /* start == total -> clamped len 0 -> empty (start<=total allowed). */
        double end = yon_rt_string_substring(hello, 5.0, 4.0);
        check(end != 0.0 && yon_rt_string_length(end) == 0.0,
              "substring start==len -> '' (boundary, no OOB)");
    }
    /* start past total -> 0.0 sentinel (yon_rt.c:6974). */
    check(yon_rt_string_substring(hello, 6.0, 1.0) == 0.0,
          "substring start past end -> 0.0 sentinel");
    /* negative len -> treated as 0 (yon_rt.c:6975). */
    {
        double nl = yon_rt_string_substring(hello, 1.0, -4.0);
        check(nl != 0.0 && yon_rt_string_length(nl) == 0.0,
              "substring negative len -> '' (clamped to 0)");
    }

    if (fails == 0) {
        printf("STRING: PASS\n");
        return 0;
    }
    printf("STRING: FAIL (%d)\n", fails);
    return 1;
}
