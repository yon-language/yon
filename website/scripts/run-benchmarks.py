#!/usr/bin/env python3
"""Run every Yon micro-benchmark under regression/bench/, K times each, and write
the per-position median of each program's integer stdout to bench-raw.json.

Each bench program already does an internal min-of-K (the least-interrupted run =
true cost) and baseline subtraction; running it K more times here and taking the
median across runs guards against a single bad invocation. The page-build step maps
these raw medians to labelled numbers via each bench's documented stdout schema.

Usage:  python3 website/scripts/run-benchmarks.py [K]   (default K=7)
"""
import subprocess, statistics, json, os, glob, sys

ROOT = "/Users/anthem/Projects/yon"
BENCH_DIR = os.path.join(ROOT, "regression", "bench")
YONC = os.path.join(ROOT, "toolchain", "yonc")
OUT = os.path.join(ROOT, "website", "src", "data", "bench-raw.json")
K = int(sys.argv[1]) if len(sys.argv) > 1 else 7


def ints(s):
    out = []
    for tok in s.split():
        t = tok.strip()
        if t.lstrip("-").isdigit():
            out.append(int(t))
    return out


def main():
    results = {}
    for d in sorted(glob.glob(os.path.join(BENCH_DIR, "*"))):
        if not os.path.isdir(d):
            continue
        name = os.path.basename(d)
        binp = f"/tmp/bench_{name}"
        comp = subprocess.run([YONC, d, "-o", binp], capture_output=True, text=True)
        if comp.returncode != 0 or not os.path.exists(binp):
            results[name] = {"error": "compile failed", "stderr": comp.stderr[-400:]}
            print(f"  {name:16s} COMPILE FAILED")
            continue
        runs = []
        for _ in range(K):
            r = subprocess.run([binp], capture_output=True, text=True)
            nums = ints(r.stdout)  # the L2_SHM runtime banner has no bare integers
            if nums:
                runs.append(nums)
        if not runs:
            results[name] = {"error": "no numeric output"}
            print(f"  {name:16s} NO OUTPUT")
            continue
        L = min(len(r) for r in runs)
        median = [int(statistics.median(r[i] for r in runs)) for i in range(L)]
        results[name] = {"runs": len(runs), "median": median, "all": runs}
        print(f"  {name:16s} median={median}")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(results, open(OUT, "w"), indent=2)
    print(f"\nwrote {OUT}")


if __name__ == "__main__":
    main()
