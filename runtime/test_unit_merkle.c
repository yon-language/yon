/* test_unit_merkle.c — oracle for the yon_rt_merkle_* content-addressing family
 * (yon_rt.c:5368+). A Merkle node is an xheap slot on g_ds_heap; its slot id is
 * the f64 handle and is its content address: identical (label, ordered children,
 * arity) hash to the SAME slot, so structural equality == handle equality. This
 * is the core invariant the family exists to provide.
 *
 * Signatures grounded on the header / impl:
 *   yon_rt.h:577  double yon_rt_merkle_leaf(double label);
 *                 -> slot id; 0.0 only on heap-slot exhaustion (yon_rt.c:5377).
 *   yon_rt.h:579  double yon_rt_merkle_node2(double label, double c1, double c2);
 *                 -> slot id; ORDER PRESERVED (non-commutative): node2(L,a,b) !=
 *                    node2(L,b,a) in general (yon_rt.c:5381).
 *   yon_rt.c:5403 double yon_rt_merkle_node2_commutative(double L, double a,
 *                    double b); (NOT in header) -> slot id; S_2 quotient: orders
 *                    the two children before hashing so node2_comm(L,a,b) ==
 *                    node2_comm(L,b,a) (yon_rt.c:5415-5416).
 *   yon_rt.h:582  double yon_rt_merkle_node3(double L, double c1,c2,c3);
 *                 -> slot id; S_3 canonicalize-by-sort: all 6 perms share a slot
 *                    (yon_rt.c:5432). Distinct XHEAP tag from node2.
 *   yon_rt.h:583  double yon_rt_merkle_node4(double L, double c1,c2,c3,c4);
 *                 -> slot id; S_4 canonicalize-by-sort: all 24 perms share a slot
 *                    (yon_rt.c:5449).
 *   yon_rt.h:586  double yon_rt_merkle_label(double node_id);
 *                 -> stored label; bad id -> -1.0 (yon_rt.c:5467-5473).
 *   yon_rt.h:588  double yon_rt_merkle_child(double node_id, double child_idx);
 *                 -> child slot (idx 0/1 for node2); bad id or idx>1 -> 0.0
 *                    (yon_rt.c:5477-5487).
 *   yon_rt.h:590  double yon_rt_merkle_equal(double a, double b);
 *                 -> 1.0 iff a==b (handle equality == content equality),
 *                    else 0.0 (yon_rt.c:5490).
 *
 * Marker on success: "MERKLE: PASS".
 */

#include "yon_rt.h"
#include <stdio.h>

/* Non-static in yon_rt.c:5403 but absent from yon_rt.h: declare it exactly. */
extern double yon_rt_merkle_node2_commutative(double label, double c1, double c2);

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-56s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

int main(void) {
    printf("=== yon_rt_merkle_* content-addressing oracle ===\n");

    /* ---- leaf round-trip + content-addressing ---- */
    double a = yon_rt_merkle_leaf(7.0);
    double b = yon_rt_merkle_leaf(9.0);
    check(a != 0.0 && b != 0.0, "leaf() -> valid slots (!= 0.0)");
    check(yon_rt_merkle_label(a) == 7.0, "leaf(7).label == 7 (round-trip)");
    check(yon_rt_merkle_label(b) == 9.0, "leaf(9).label == 9");

    /* same label -> same content address (deduped slot). */
    double a2 = yon_rt_merkle_leaf(7.0);
    check(a2 == a, "leaf(7) twice -> same slot (content-addressed)");
    check(yon_rt_merkle_equal(a, a2) == 1.0, "merkle_equal(leaf7,leaf7) == 1");
    check(yon_rt_merkle_equal(a, b) == 1.0 ? 0 : 1,
          "merkle_equal(leaf7,leaf9) == 0 (distinct)");

    /* ---- node2 deterministic + ordered (non-commutative) ---- */
    double n_ab = yon_rt_merkle_node2(1.0, a, b);
    double n_ab2 = yon_rt_merkle_node2(1.0, a, b);
    check(n_ab != 0.0, "node2(1,a,b) -> valid slot");
    check(n_ab2 == n_ab, "node2(1,a,b) deterministic: same inputs -> same slot");
    check(yon_rt_merkle_label(n_ab) == 1.0, "node2 label round-trips == 1");
    check(yon_rt_merkle_child(n_ab, 0.0) == a, "node2 child[0] == a");
    check(yon_rt_merkle_child(n_ab, 1.0) == b, "node2 child[1] == b");

    /* order matters: node2(L,a,b) != node2(L,b,a). */
    double n_ba = yon_rt_merkle_node2(1.0, b, a);
    check(n_ba != n_ab, "node2 ORDER-sensitive: (a,b) slot != (b,a) slot");
    check(yon_rt_merkle_equal(n_ab, n_ba) == 0.0,
          "merkle_equal(node2 a,b ; node2 b,a) == 0 (non-commutative)");

    /* ---- node2_commutative symmetric (S_2 quotient) ---- */
    double c_ab = yon_rt_merkle_node2_commutative(1.0, a, b);
    double c_ba = yon_rt_merkle_node2_commutative(1.0, b, a);
    check(c_ab == c_ba,
          "node2_commutative(a,b) == node2_commutative(b,a) (symmetric)");
    check(yon_rt_merkle_equal(c_ab, c_ba) == 1.0,
          "merkle_equal of the two comm orders == 1");
    /* commutative node lives in the same (label,ordered-children) space as the
     * canonicalized node2: c_ab equals whichever of n_ab/n_ba sorts children
     * ascending, and differs from the other. It is therefore != the *pair* in
     * the sense that the two raw orders are not both equal to it. */
    check((c_ab == n_ab) || (c_ab == n_ba),
          "comm node coincides with the canonical (sorted) ordered node");
    check(!((n_ab == c_ab) && (n_ba == c_ab)),
          "comm node does NOT equal BOTH raw orders (proves node2 non-comm)");

    /* ---- node3 S_3: all permutations share a slot ---- */
    {
        double c1 = yon_rt_merkle_leaf(11.0);
        double c2 = yon_rt_merkle_leaf(12.0);
        double c3 = yon_rt_merkle_leaf(13.0);
        double base = yon_rt_merkle_node3(2.0, c1, c2, c3);
        check(base != 0.0, "node3(2,c1,c2,c3) -> valid slot");
        check(yon_rt_merkle_node3(2.0, c3, c1, c2) == base,
              "node3 perm (c3,c1,c2) -> same slot (S_3 quotient)");
        check(yon_rt_merkle_node3(2.0, c3, c2, c1) == base,
              "node3 perm (c3,c2,c1) -> same slot");
        check(yon_rt_merkle_node3(2.0, c2, c1, c3) == base,
              "node3 perm (c2,c1,c3) -> same slot");
        /* different label -> different slot. */
        check(yon_rt_merkle_node3(3.0, c1, c2, c3) != base,
              "node3 different label -> different slot");
    }

    /* ---- node4 S_4: all permutations share a slot ---- */
    {
        double c1 = yon_rt_merkle_leaf(21.0);
        double c2 = yon_rt_merkle_leaf(22.0);
        double c3 = yon_rt_merkle_leaf(23.0);
        double c4 = yon_rt_merkle_leaf(24.0);
        double base = yon_rt_merkle_node4(4.0, c1, c2, c3, c4);
        check(base != 0.0, "node4(4,c1..c4) -> valid slot");
        check(yon_rt_merkle_node4(4.0, c4, c3, c2, c1) == base,
              "node4 reversed perm -> same slot (S_4 quotient)");
        check(yon_rt_merkle_node4(4.0, c2, c4, c1, c3) == base,
              "node4 shuffled perm -> same slot");
    }

    /* ---- error sentinels: bad ids ---- */
    check(yon_rt_merkle_label(0.0) == -1.0, "label(invalid id) -> -1.0 sentinel");
    check(yon_rt_merkle_child(0.0, 0.0) == 0.0, "child(invalid id) -> 0.0");
    check(yon_rt_merkle_child(n_ab, 5.0) == 0.0, "child idx out of range -> 0.0");
    check(yon_rt_merkle_equal(a, a) == 1.0, "merkle_equal(x,x) == 1 (reflexive)");

    if (fails == 0) {
        printf("MERKLE: PASS\n");
        return 0;
    }
    printf("MERKLE: FAIL (%d)\n", fails);
    return 1;
}
