#!/usr/bin/env python3
"""Regenerate website/src/data/jp-traces/*.json from REAL Yon runs.

Each trace is the actual stdout of a `.yon` project, compiled and run by the
end-to-end compiler (`toolchain/yonc`), never hand-authored numbers. The React
components only replay these traces, so a hostile reader can reproduce any gif
from `.yon -> yonc -> run -> trace.json`. If a run's output contradicts the model
this script ASSERTS and fails, rather than shipping an animation that lies.

Run from anywhere:  python3 website/scripts/build-jp-traces.py
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))            # repo root (website/scripts -> ..)
YONC = os.path.join(ROOT, "toolchain", "yonc")
OUT_DIR = os.path.join(ROOT, "website", "src", "data", "jp-traces")


def run_project(proj):
    """Compile + run a .yon project; return the integers it printed, in order."""
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, "prog")
        c = subprocess.run([YONC, os.path.join(ROOT, proj), "-o", exe],
                           capture_output=True, text=True, timeout=180)
        if c.returncode != 0:
            sys.exit(f"yonc failed for {proj}:\n{c.stderr[-800:]}")
        r = subprocess.run([exe], capture_output=True, text=True, timeout=60)
        return [int(t) for t in r.stdout.split() if t.strip().lstrip("-").isdigit()]


def space_cell_no_alias():
    proj = "regression/book/jp/probe_no_alias"
    printed = run_project(proj)
    # The probe prints, in order:
    #   x (= the cell, after `be x holds 3`),
    #   y (a snapshot, after `be y holds x`),
    #   x (= the cell, after `x = 5`),
    #   y (again, after the store).
    assert len(printed) == 4, f"expected 4 printed numbers, got {printed}"
    cell0, y1, cell2, y2 = printed
    # THE PROOF. If y followed the cell, the no-aliasing model is false: fail loudly.
    assert y2 == y1, f"NO-ALIAS BROKEN: y went {y1} -> {y2} when x was reassigned"
    assert cell2 != y2, f"expected cell ({cell2}) to diverge from the snapshot ({y2})"
    return {
        "source": proj,
        "printed": printed,
        "steps": [
            {"op": "bind",     "src": "be x holds 3", "cell": cell0, "y": None},
            {"op": "snapshot", "src": "be y holds x", "cell": cell0, "y": y1},
            {"op": "store",    "src": "x = 5",        "cell": cell2, "y": y2},
        ],
    }


def genome_golay():
    proj = "regression/book/jp/05_golay_codeword"
    printed = run_project(proj)
    # data, codeword, corrupted-codeword, recovered
    assert len(printed) == 4, f"expected 4 printed numbers, got {printed}"
    data, codeword, corrupted, recovered = printed
    # THE PROOF: Golay recovers the datum through the flipped bits.
    assert recovered == data, f"GOLAY BROKEN: recovered {recovered} != data {data}"
    assert corrupted != codeword, "corrupt did not flip any bits"
    return {
        "source": proj,
        "printed": printed,
        "data": data, "codeword": codeword, "corrupted": corrupted,
        "recovered": recovered, "bits": 24, "data_bits": 12,
    }


def dino_lattice():
    proj = "regression/book/jp/07_dino_lattice"
    printed = run_project(proj)
    # 10 numbers, all reproducible: [1-4] genomes A,B,C,D (literals) ;
    # [5-10] of2 matrix AB,AC,AD,BC,BD,CD. of2 of fixed values is build-stable;
    # xi/orbit were excluded as build-UNSTABLE (their surface output is not
    # build-canonical), so the Co2-not-Co0 boundary lives in prose, not in a
    # number the harness can guard.
    assert len(printed) == 10, f"expected 10 printed numbers, got {len(printed)}: {printed}"
    genomes = printed[0:4]
    of2 = printed[4:10]
    assert genomes == [1536, 1280, 25167360, 512], f"genomes drifted: {genomes}"
    # THE CLASSIFICATION: of2 is a categorical class in 0..11, here the relation
    # matrix over four genomes. The viz depends on these exact classes, and they
    # are reproducible because of2 of fixed inputs is canonical.
    assert of2 == [1, 11, 7, 1, 1, 7], f"of2 matrix drifted: {of2}"
    assert len({x for x in of2 if x > 0}) >= 3, f"alphabet too thin: {of2}"
    pairs = [("A", "B"), ("A", "C"), ("A", "D"), ("B", "C"), ("B", "D"), ("C", "D")]
    names = {"A": "Tyrannosaurus", "B": "Velociraptor", "C": "Dilophosaurus", "D": "Gallimimus"}
    xby = dict(zip(("A", "B", "C", "D"), genomes))
    bc = of2[3]
    return {
        "source": proj,
        "printed": printed,
        "genomes": [{"id": k, "name": names[k], "x": xby[k]} for k in ("A", "B", "C", "D")],
        "edges": [{"a": p[0], "b": p[1], "of2": of2[i]} for i, p in enumerate(pairs)],
        "alphabet_size": 12,
        "realized_classes": sorted({x for x in of2 if x > 0}),
        "invariance": {
            "symmetric": True, "deterministic": True, "group": "Co2", "co0_invariant": False,
            "note": "Co2 is the code-certified group (runtime/yon_rt.c:4706). A Co0 rotation "
                    "can relabel a pair, but that witness is itself build-unstable, so only the "
                    "matrix of fixed genomes is shipped.",
        },
        "spotlight": {
            "pair": "B-C", "of2": bc, "genome_delta": abs(xby["B"] - xby["C"]),
            "note": "Wu's raw-difference ruler calls B-C maximally different; "
                    "of2 puts B-C in class %d, the same class as A-B." % bc,
        },
    }


def _cluster_tree(M, N):
    """Average-linkage agglomerative clustering of the clade matrix into a nested
    dendrogram. The pair_subtype value is the distance (0 = identical, higher =
    more different). Ties broken by lowest index, so the tree is deterministic."""
    node = {i: {"leaf": i, "leaves": [i], "height": 0} for i in range(N)}
    active = list(range(N))
    nid = N

    def dist(a, b):
        la, lb = node[a]["leaves"], node[b]["leaves"]
        return sum(M[i][j] for i in la for j in lb) / (len(la) * len(lb))

    while len(active) > 1:
        best = None
        for ii in range(len(active)):
            for jj in range(ii + 1, len(active)):
                d = dist(active[ii], active[jj])
                if best is None or d < best[0]:
                    best = (d, active[ii], active[jj])
        d, a, b = best
        node[nid] = {"leaves": node[a]["leaves"] + node[b]["leaves"], "height": d,
                     "children": [a, b]}
        active = [x for x in active if x != a and x != b] + [nid]
        nid += 1
    root = active[0]

    def nest(x):
        n = node[x]
        if "leaf" in n:
            return {"leaf": n["leaf"]}
        return {"height": round(n["height"], 3), "leaves": n["leaves"],
                "children": [nest(c) for c in n["children"]]}

    return nest(root), node[root]["leaves"]   # tree, leaf order (DFS)


def taxa_full():
    proj = "regression/book/jp/10_taxa_full"
    printed = run_project(proj)
    doc = json.load(open(os.path.join(OUT_DIR, "taxa.json")))
    taxa = [(t["name"], t["v"], b["band"]) for b in doc["bands"] for t in b["taxa"]]
    N = len(taxa)
    n_pair = N * (N - 1) // 2
    expected = N + N + n_pair + 18 + 4
    assert len(printed) == expected, f"expected {expected} ints, got {len(printed)}"
    grade = printed[0:N]                       # mode-0 orbit (popcount/grade)
    lin_t2 = printed[N:2 * N]                   # mode-3 orbit: type-2 check under the linear map
    clade_flat = printed[2 * N:2 * N + n_pair]  # pair_subtype (linear), the CLADE relation
    triples_flat = printed[2 * N + n_pair:2 * N + n_pair + 18]
    xi = printed[2 * N + n_pair + 18:]
    # reconstruct the symmetric CLADE matrix (diagonal 0)
    M = [[0] * N for _ in range(N)]
    k = 0
    for i in range(N):
        for j in range(i + 1, N):
            M[i][j] = M[j][i] = clade_flat[k]; k += 1
    assert all(x >= 0 for x in clade_flat), "pair_subtype negative?"
    assert xi[3] in (-1, 0, 1), f"omega(xi) not in -1/0/1: {xi[3]}"
    # GRADE: the mode-0 orbit is (we expect) a strict function of popcount.
    pc = lambda v: bin(v).count("1")
    by_pc = {}
    for (n, v, b), g in zip(taxa, grade):
        by_pc.setdefault(pc(v), set()).add(g)
    grade_is_popcount = all(len(s) == 1 for s in by_pc.values())
    # CLADE: the linear map must separate where grade collapses.
    clade_classes = sorted(set(clade_flat))
    assert len(clade_classes) >= 3, f"clade matrix too flat: {clade_classes}"
    # type-2 status of the linear (mode-3) points (informational, not asserted)
    lin_type2 = sum(1 for o in lin_t2 if 0 <= o <= 11)
    tree, leaf_order = _cluster_tree(M, N)
    triple_names = [["Eoraptor", "Velociraptor", "Gallus"],
                    ["Allosaurus", "Velociraptor", "Archaeopteryx"],
                    ["Velociraptor", "Deinonychus", "Microraptor"]]
    triples = []
    for t in range(3):
        a, b, c, tri, trif, om = triples_flat[t * 6:t * 6 + 6]
        triples.append({"taxa": triple_names[t], "of2": [a, b, c],
                        "triangle": tri, "triangle_fine": trif, "omega": om})
    return {
        "source": proj, "n": N,
        "taxa": [{"name": n, "v": v, "band": b} for (n, v, b) in taxa],
        "grade_orbit": grade,                  # mode-0 orbit (the popcount/grade family)
        "grade_is_popcount": grade_is_popcount,
        "linear_type2_count": lin_type2,       # how many mode-3 points are type-2 (of N)
        "clade": M,                            # pair_subtype (linear) — reads WHICH characters
        "clade_classes": clade_classes,
        "tree": tree, "leaf_order": leaf_order,   # dendrogram from clustering the clade matrix
        "triples": triples,                    # on type-2 mode-0 points (the omega coda)
        "xi_demo": {"triple": triple_names[0],
                    "home": {"of2": triples[0]["of2"], "omega": triples[0]["omega"]},
                    "frame_xi": {"of2": [xi[0], xi[1], xi[2]], "omega": xi[3]}},
        "note": "GRADE = mode-0 orbit (a function of popcount: how derived, not who is related). "
                "CLADE = linear mode-3 pair_subtype: the leech2 subtype of v^w, reads WHICH "
                "characters differ at Golay resolution (manuscript/linear-map.md). The tree is "
                "clustered from the clade matrix. omega is Co0-invariant on type-2 (mode-0) points. "
                "Vectors illustrative, not a TWG matrix; clade-direction, not weighted phylogenetics.",
    }


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    traces = {
        "space_cell_no_alias": space_cell_no_alias(),
        "genome_golay": genome_golay(),
        "dino_lattice": dino_lattice(),
        "taxa_full": taxa_full(),
    }
    for name, data in traces.items():
        path = os.path.join(OUT_DIR, name + ".json")
        data = {"_comment": "GENERATED by website/scripts/build-jp-traces.py; do not hand-edit.",
                **data}
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        pr = data.get("printed")
        if pr is None:
            print(f"wrote {path}   ({data.get('n', '?')} taxa: of2 matrix + orbits + triples)")
        else:
            shown = pr if len(pr) <= 12 else f"{len(pr)} ints"
            print(f"wrote {path}   (Yon printed: {shown})")


if __name__ == "__main__":
    main()
