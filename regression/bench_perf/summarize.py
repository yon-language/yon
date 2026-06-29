#!/usr/bin/env python3
"""Turn a pytest-benchmark JSON into per-op timings + machine metadata for the page.

per_op = op_median / N_op - base_median / N_base   (per-iteration, baseline-subtracted)

Usage: python regression/bench_perf/summarize.py /tmp/perf.json [out.json]
"""
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _git_commit():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True, timeout=10).stdout.strip() or "?"
    except Exception:
        return "?"

OPS = {
    "equality": ("_read_base", 10_000_000, "String.equal (1-char)"),
    "merkle_equal": ("_read_base", 10_000_000, "MerkleTree.equal"),
    "golay_seal": ("_read_base", 10_000_000, "VoyagerList.seal"),
    "golay_open": ("_read_base", 10_000_000, "VoyagerList.open (corrected)"),
    "vec_get": ("_read_base", 10_000_000, "Vec.get"),
    "hashset_lookup": ("_read_base", 10_000_000, "HashSet.contains"),
    "list_head": ("_read_base", 10_000_000, "List.head"),
    "hashmap_get": ("_read_base", 10_000_000, "HashMap.get"),
    # The three Arena ops are omitted here: their loops call Leech.point (not in the shared
    # baselines) and the first call pays a one-time ~200 ms mmgroup init. Measured in-process
    # with an exact twin in regression/bench/arena_ops (put ~80 ns O(1), get ~41, same_orbit ~1.1 us).
    "vec_push": ("_thru_base", 1_000_000, "Vec.push"),
    "hashset_insert": ("_thru_base", 1_000_000, "HashSet.add"),
    # list_cons and hashmap_set omitted: they put on the content-addressed heap (one-time
    # g_yon_heap init smears at small N; set grows with the map). Measured in-process with
    # an exact twin at several N in regression/bench/ds_ops (cons ~70 ns flat, set ~130 ns
    # rising to ~340 ns by 1M).
    "merkle_construct": ("_read_base", 1_000_000, "MerkleTree.node2 (build)"),
    "equality_big": ("_read_base", 10_000_000, "String.equal (32768-char)"),
}
BASE_N = {"_read_base": 10_000_000, "_thru_base": 1_000_000}


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/perf.json"
    out = sys.argv[2] if len(sys.argv) > 2 else str(
        Path(__file__).resolve().parents[2] / "website" / "src" / "data" / "bench-perf.json")
    d = json.load(open(src))
    mi = d["machine_info"]
    median = {b["params"]["prog"] if "prog" in b.get("params", {}) else b["param"]: b["stats"]["median"]
              for b in d["benchmarks"]}
    rounds = min(b["stats"]["rounds"] for b in d["benchmarks"])

    per_op = {}
    for op, (base, n, label) in OPS.items():
        if op not in median or base not in median:
            continue
        ns = (median[op] / n - median[base] / BASE_N[base]) * 1e9
        per_op[op] = {"label": label, "ns": round(ns, 2), "n": n}

    meta = {
        "machine": mi.get("cpu", {}).get("brand_raw", "?"),
        "system": f"{mi.get('system','')} {mi.get('machine','')}".strip(),
        "tool": f"pytest-benchmark {d.get('version','')}",
        "rounds_min": rounds,
        "build": "runtime -O2, warm cache",
        "commit": _git_commit(),
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "note": "timings measured on this machine on the date above, at the commit above; NOT "
                "re-derived each build. The correctness gate (regression/bench/*) IS re-derived "
                "every build.",
    }
    # DCE / baseline sanity: a real op must cost MORE than its baseline. per_op <= 0 means the
    # operation was elided (its result unused) or the baseline does not mirror the op.
    suspect = [op for op, v in per_op.items() if v["ns"] <= 0]
    result = {"meta": meta, "per_op": dict(sorted(per_op.items(), key=lambda kv: kv[1]["ns"]))}
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    json.dump(result, open(out, "w"), indent=2)

    print(f"machine : {meta['machine']} | {meta['system']} | {meta['tool']} | >={rounds} rounds | commit {meta['commit']}")
    print(f"{'op':22s} {'ns/op':>10s}")
    for op, v in result["per_op"].items():
        print(f"{v['label']:22s} {v['ns']:>10.1f}")
    if suspect:
        print(f"\n!! SUSPECT (per_op <= 0, possible DCE or bad baseline): {suspect}")
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
