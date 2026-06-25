/* test_unit_bits.c — oracle for the bitwise + hashing runtime families:
 * yon_rt_bits_* (yon_rt.c:6826+) and yon_rt_crypto_* (yon_rt.c:7220+). All take
 * plain f64 (interpreted as uint32/uint64) except fnv1a, which takes a String
 * handle (xheap slot). No compiled-program context required.
 *
 * Signatures grounded on the header / impl:
 *   yon_rt.h:929  double yon_rt_bits_and(double a, double b);  -> (u32)a & (u32)b
 *                 (yon_rt.c:6826).
 *   yon_rt.h:930  double yon_rt_bits_or (double a, double b);  -> | (6829).
 *   yon_rt.h:931  double yon_rt_bits_xor(double a, double b);  -> ^ (6832).
 *   yon_rt.h:932  double yon_rt_bits_not(double a);            -> (~(u32)a) masked
 *                 to 24 bits 0xFFFFFF (Co_0 context, yon_rt.c:6835-6837).
 *   yon_rt.h:933  double yon_rt_bits_shl(double a, double n);  -> a << (n & 31)
 *                 (yon_rt.c:6839).
 *   yon_rt.h:934  double yon_rt_bits_shr(double a, double n);  -> a >> (n & 31)
 *                 (yon_rt.c:6842).
 *   yon_rt.h:935  double yon_rt_bits_popcount(double a);       -> popcount((u32)a)
 *                 (__builtin_popcount, yon_rt.c:6845).
 *   yon_rt.h:975  double yon_rt_bits_or_64 (double a, double b); -> (u64) | (7263).
 *   yon_rt.h:976  double yon_rt_bits_and_64(double a, double b); -> (u64) & (7266).
 *   yon_rt.h:977  double yon_rt_bits_xor_64(double a, double b); -> (u64) ^ (7269).
 *   yon_rt.h:957  double yon_rt_crypto_fnv1a(double str_id);
 *                 -> 32-bit FNV-1a over the slot payload bytes; INVALID id or
 *                    NULL payload -> 0.0 (yon_rt.c:7220-7233). seed 0x811c9dc5,
 *                    prime 0x01000193.
 *   yon_rt.h:958  double yon_rt_crypto_hash_int(double n);
 *                 -> xxHash-style avalanche of (u32)n, deterministic
 *                    (yon_rt.c:7235-7243).
 *   yon_rt.c:7117 double yon_rt_string_lit(const char *);  (mints a String slot,
 *                 not in header) — used to feed fnv1a.
 *
 * Marker on success: "BITS: PASS".
 */

#include "yon_rt.h"
#include <stdio.h>
#include <stdint.h>

/* Non-static in yon_rt.c but not in the header. */
extern double yon_rt_string_lit(const char *bytes);

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-52s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

/* Independent reference FNV-1a (same constants as yon_rt.c:7227-7231) so the
 * runtime value is checked against an oracle, not just itself. */
static uint32_t ref_fnv1a(const char *p) {
    uint32_t h = 0x811c9dc5u;
    for (; *p; p++) { h ^= (uint8_t)*p; h *= 0x01000193u; }
    return h;
}

int main(void) {
    printf("=== yon_rt bits/crypto oracle ===\n");

    /* ---- popcount: known values ---- */
    check(yon_rt_bits_popcount(0.0) == 0.0, "popcount(0) == 0");
    check(yon_rt_bits_popcount(1.0) == 1.0, "popcount(1) == 1");
    check(yon_rt_bits_popcount(7.0) == 3.0, "popcount(7) == 3 (0b111)");
    check(yon_rt_bits_popcount(255.0) == 8.0, "popcount(255) == 8");
    check(yon_rt_bits_popcount((double)0xFFFFFFFFu) == 32.0,
          "popcount(0xFFFFFFFF) == 32 (all 32 ones)");
    check(yon_rt_bits_popcount(0xAAAAu) == 8.0, "popcount(0xAAAA) == 8");

    /* ---- and / or / xor / not (u32) ---- */
    check(yon_rt_bits_and(12.0, 10.0) == 8.0, "and(0b1100,0b1010) == 0b1000");
    check(yon_rt_bits_or(12.0, 10.0) == 14.0, "or(0b1100,0b1010) == 0b1110");
    check(yon_rt_bits_xor(12.0, 10.0) == 6.0,  "xor(0b1100,0b1010) == 0b0110");
    check(yon_rt_bits_xor(5.0, 5.0) == 0.0,    "xor(x,x) == 0");
    check(yon_rt_bits_and(0.0, 0xFFFFu) == 0.0, "and(0,x) == 0");
    check(yon_rt_bits_or(0.0, 0xFFFFu) == (double)0xFFFFu, "or(0,x) == x");
    /* not is masked to 24 bits (Co_0): ~0 & 0xFFFFFF == 0xFFFFFF. */
    check(yon_rt_bits_not(0.0) == (double)0xFFFFFFu,
          "not(0) == 0xFFFFFF (24-bit mask)");
    check(yon_rt_bits_not((double)0xFFFFFFu) == 0.0,
          "not(0xFFFFFF) == 0 (24-bit)");

    /* ---- shifts (count masked to low 5 bits) ---- */
    check(yon_rt_bits_shl(1.0, 4.0) == 16.0, "shl(1,4) == 16");
    check(yon_rt_bits_shr(16.0, 4.0) == 1.0, "shr(16,4) == 1");
    check(yon_rt_bits_shl(1.0, 0.0) == 1.0,  "shl(1,0) == 1");
    check(yon_rt_bits_shr(255.0, 8.0) == 0.0, "shr(255,8) == 0");

    /* ---- 64-bit variants ---- */
    check(yon_rt_bits_or_64(12.0, 10.0) == 14.0, "or_64(0b1100,0b1010) == 0b1110");
    check(yon_rt_bits_and_64(12.0, 10.0) == 8.0, "and_64 == 0b1000");
    check(yon_rt_bits_xor_64(12.0, 10.0) == 6.0, "xor_64 == 0b0110");

    /* ---- fnv1a: deterministic + matches an independent reference ---- */
    {
        double s1 = yon_rt_string_lit("hello");
        double s2 = yon_rt_string_lit("hello");
        double sd = yon_rt_string_lit("world");
        double h1 = yon_rt_crypto_fnv1a(s1);
        double h2 = yon_rt_crypto_fnv1a(s2);
        check(h1 == h2, "fnv1a('hello') deterministic (two calls equal)");
        check(h1 != yon_rt_crypto_fnv1a(sd),
              "fnv1a('hello') != fnv1a('world')");
        check(h1 == (double)ref_fnv1a("hello"),
              "fnv1a('hello') matches independent FNV-1a reference");
        /* empty string -> the FNV offset basis itself (no bytes mixed). */
        double he = yon_rt_crypto_fnv1a(yon_rt_string_lit(""));
        check(he == (double)0x811c9dc5u,
              "fnv1a('') == 0x811c9dc5 (offset basis)");
        /* invalid string id -> 0.0 sentinel, no crash. */
        check(yon_rt_crypto_fnv1a(0.0) == 0.0, "fnv1a(invalid id) -> 0.0");
    }

    /* ---- hash_int: deterministic + avalanche-distinct ---- */
    {
        double a = yon_rt_crypto_hash_int(42.0);
        double b = yon_rt_crypto_hash_int(42.0);
        check(a == b, "hash_int(42) deterministic");
        check(yon_rt_crypto_hash_int(0.0) == 0.0,
              "hash_int(0) == 0 (avalanche of 0 is 0)");
        check(yon_rt_crypto_hash_int(1.0) != yon_rt_crypto_hash_int(2.0),
              "hash_int(1) != hash_int(2) (distinct)");
        check(yon_rt_crypto_hash_int(1.0) != 1.0,
              "hash_int(1) actually mixes (!= identity)");
    }

    if (fails == 0) {
        printf("BITS: PASS\n");
        return 0;
    }
    printf("BITS: FAIL (%d)\n", fails);
    return 1;
}
