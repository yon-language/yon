/* test_unit_hsh.c — oracle for the HSH (Hierarchical History Store) membership
 * and backward paths (yon_rt_hsh.c, #include'd into yon_rt.o). The level index
 * reaching hsh_contains is attacker-influenceable; an out-of-range level must
 * yield a defined "false", never an OOB read of levels[].
 *
 * These functions have NO public header (yon_rt_hsh.c is #include'd into
 * yon_rt.c at yon_rt.c:7504), so we declare them extern with the exact
 * f64-facade signatures from the implementation:
 *   yon_rt_hsh.c:76   double yon_rt_hsh_empty(double e_value)
 *   yon_rt_hsh.c:82   double yon_rt_hsh_step(double store_id, double a_i, double compose_op)
 *   yon_rt_hsh.c:135  double yon_rt_hsh_contains(double store_id, double level, double v)
 *                     -> hashset_contains (>=0.5 true, <0.5 false);
 *                        out-of-range level (i >= n_levels) -> 0.0 (defined false).
 *   yon_rt_hsh.c:144  double yon_rt_hsh_backward(double store_id, double goal, double weights_list)
 *   yon_rt_hsh.c:174  double yon_rt_hsh_levels(double store_id)
 *
 * Semantics grounded in the impl: empty(e) gives H_0 = {e}; step(s, a, 0) builds
 * H_1 = H_0 ∪ {v+a : v in H_0} = {e, e+a} (monoid (N,+), compose_op ignored at
 * yon_rt_hsh.c:129). contains uses the cumulative hashset of level i.
 *
 * backward(goal) (yon_rt_hsh.c:144) subtracts the recorded axioms a_i and
 * requires the residual v to reach EXACTLY 0.0 — i.e. goal must be the sum of
 * axioms above the base e. We therefore seed e = 0 so a single axiom a_1 gives a
 * clean witness for goal == a_1, and any other goal is unreachable. */

#include "yon_rt.h"
#include <stdio.h>

extern double yon_rt_hsh_empty(double e_value);
extern double yon_rt_hsh_step(double store_id, double a_i, double compose_op);
extern double yon_rt_hsh_contains(double store_id, double level, double v);
extern double yon_rt_hsh_backward(double store_id, double goal, double weights_list);
extern double yon_rt_hsh_levels(double store_id);

int main(void) {
    printf("=== yon_rt_hsh membership / backward oracle ===\n");
    int fails = 0;

    /* empty(0) -> H_0 = {0}. step adds a_1 = 5 -> H_1 = {0, 5}. */
    double s = yon_rt_hsh_empty(0.0);
    if (s == 0.0) { printf("[FAIL] hsh_empty returned 0\n"); return 1; }
    s = yon_rt_hsh_step(s, 5.0, 0.0);    /* H_1 = {0, 5} */
    double nlev = yon_rt_hsh_levels(s);
    {
        int ok = (nlev == 2.0);
        printf("  empty->step: levels=%g       : %s\n", nlev, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 1) contains(level 1, v=0) true: e is carried into every cumulative level. */
    {
        double c = yon_rt_hsh_contains(s, 1.0, 0.0);
        int ok = (c >= 0.5);
        printf("  contains(L1, 0) present       : c=%g %s\n", c, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 2) contains(level 1, v=5) true: 5 = 0 + a_1 was produced at the step. */
    {
        double c = yon_rt_hsh_contains(s, 1.0, 5.0);
        int ok = (c >= 0.5);
        printf("  contains(L1, 5) present       : c=%g %s\n", c, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 3) absent value -> false (a value never generated, e.g. 999). */
    {
        double c = yon_rt_hsh_contains(s, 1.0, 999.0);
        int ok = (c < 0.5);
        printf("  contains(L1, 999) absent      : c=%g %s\n", c, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 4) H_0 (level 0) does NOT yet contain 5 (only the cumulative L1 does). */
    {
        double c0_5 = yon_rt_hsh_contains(s, 0.0, 5.0);
        double c0_0 = yon_rt_hsh_contains(s, 0.0, 0.0);
        int ok = (c0_5 < 0.5) && (c0_0 >= 0.5);
        printf("  L0={0}: has 0, lacks 5        : 0=%g 5=%g %s\n",
               c0_0, c0_5, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 5) out-of-range level -> defined false, no crash (i >= n_levels at
     *    yon_rt_hsh.c:139). Probe several wild levels including a huge one. */
    {
        int ok = 1;
        double probes[4] = { 2.0, 1000.0, 1e9, 1e18 };
        for (int i = 0; i < 4; i++) {
            double c = yon_rt_hsh_contains(s, probes[i], 2.0);
            if (!(c < 0.5)) ok = 0;   /* must be a defined false */
        }
        printf("  out-of-range level -> false   : %s\n", ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 6) contains on a wild store_id -> defined false (hsh_lookup NULL guard,
     *    yon_rt_hsh.c:49-54). store_id 0 and a huge id are both invalid. */
    {
        double c0 = yon_rt_hsh_contains(0.0, 0.0, 2.0);
        double cbig = yon_rt_hsh_contains(1e9, 0.0, 2.0);
        int ok = (c0 < 0.5) && (cbig < 0.5);
        printf("  wild store_id -> false        : %g %g %s\n",
               c0, cbig, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 7) backward: goal 5 reduces to 0 via a_1=5 (5 - 5 = 0, base e=0 reached),
     *    so the witness mask is non-zero; goal 3 cannot reduce to 0 -> returns 0. */
    {
        double reach = yon_rt_hsh_backward(s, 5.0, 0.0);
        double unreach = yon_rt_hsh_backward(s, 3.0, 0.0);
        int ok = (reach != 0.0) && (unreach == 0.0);
        printf("  backward(5) wit, (3) none     : %g %g %s\n",
               reach, unreach, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    if (fails == 0) {
        printf("HSH: PASS\n");
        return 0;
    }
    printf("HSH: FAIL (%d)\n", fails);
    return 1;
}
