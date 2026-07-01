#!/usr/bin/env python3
"""Project-level surface fuzzer for the Yon frontend.

The in-process test_surface_fuzz.ml hammers SINGLE-FILE inline programs. It does
not touch the filesystem project model: `yon.toml` worlds, space directories,
place files, `Topos.yon`, and the seven arrows (fun/view/move/reduction/functor/
nat transform/geomorph). That surface, which is exactly what chapters 6/7/10/16
teach, was entirely un-fuzzed. This closes the gap.

It generates whole projects (valid + mutated) on disk and runs the real project
pipeline (`yoner_emit_mlir <projdir>`), asserting the same robustness invariant as
the inline fuzzer:

    the frontend TERMINATES and either ACCEPTS (emits) or REJECTS CLEANLY (a parse
    error, a type/manifest/layout diagnostic). It NEVER CRASHES: no uncaught OCaml
    exception ("Fatal error: exception"), no signal, no hang.

A crash is a real bug: an accepted-then-Fatal, or a malformed project that blows up
instead of yielding a clean diagnostic. Run:
    python regression/surface_fuzz_projects.py [seed] [cases]
Exit 0 iff zero crashes.
"""
import random
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

FIELDS = ["a", "b", "v", "w", "balance", "temp", "qty", "label", "seat"]
TYPES = ["number", "text"]


def rand_place_file(rng, name):
    n = rng.randint(1, 3)
    fnames = [rng.choice(FIELDS) for _ in range(n)]
    fields = "\n".join(f"  {fn} number" for fn in fnames)  # all-number: views/moves stay valid
    extra, wf, has_op = "", "", False
    if rng.random() < 0.4:
        extra += f"\n  fun mm(): number {{ return {rng.randint(0, 99)} }}"
    if rng.random() < 0.3:  # with-effects place carries operations (reduction targets)
        wf, has_op = " with effects", True
        extra += "\n  operation op(v: number): number"
    return f"place {name}{wf} {{\n{fields}{extra}\n}}\n", fnames, has_op


def rand_arrow(rng, pinfo):
    """A random arrow decl. ~65% valid (real place + real field + correct syntax),
    ~35% perturbed (ghost target, dropped `by`), to exercise both accept and reject."""
    if not pinfo:
        return ""
    names = list(pinfo.keys())
    p = rng.choice(names)
    q = rng.choice(names)
    fld = rng.choice(pinfo[p]["fields"]) if pinfo[p]["fields"] else "v"
    valid = rng.random() < 0.65
    tgt = p if valid else "Ghost"
    kind = rng.choice(["view", "move", "reduction", "functor", "geomorph", "fun"])
    if kind == "view":
        return f"view V{rng.randint(0,9)} of {tgt} {{ show {fld} }}\n"
    if kind == "move":
        pf = pinfo[p]["fields"][0] if pinfo[p]["fields"] else "v"
        qf = pinfo[q]["fields"][0] if pinfo[q]["fields"] else "v"
        by = " by identity" if valid else ""
        return (f"fun identity(x: number): number {{ return x }}\n"
                f"move Mv{rng.randint(0,9)} from {p} to {q} {{ {qf} maps to {pf}{by} }}\n")
    if kind == "reduction":
        # reduction needs a with-effects target (has an `operation`)
        eff = [n for n in names if pinfo[n]["op"]]
        rt = rng.choice(eff) if (eff and valid) else tgt
        return f"reduction R{rng.randint(0,9)} of {rt} {{ on op(v: number) {{ return v }} }}\n"
    if kind == "functor":
        return f"functor F{rng.randint(0,9)}(x: number) from W to V {{ return x }}\n"
    if kind == "geomorph":
        return (f"geomorph G{rng.randint(0,9)} from {p} to {q} "
                f"{{ pull(a: {q}): {p} {{ be t holds a  return t }} }}\n")
    return f"fun top{rng.randint(0,99)}(x: number): number {{ return x * {rng.randint(1,9)} }}\n"


def gen_files(rng):
    spaces = [f"s{i}" for i in range(rng.randint(1, 2))]
    files = {}
    toml = ['[package]', 'name="t"', '[runtime]', 'backend="memory"',
            '[world.W]', 'objects=["Code"]',
            'spaces=[' + ",".join(f'"{s}"' for s in spaces) + ']']
    files["yon.toml"] = "\n".join(toml) + "\n"
    files["Entry.yon"] = "place Entry { fun main(): number { return 0 } }\n"
    pinfo = {}  # place name -> {"fields": [...], "op": bool, "space": s}
    for s in spaces:
        files[f"{s}/Topos.yon"] = f"topos T_{s} where {{ }}\n"
        for j in range(rng.randint(1, 3)):
            nm = f"P{s}{j}"
            content, fnames, has_op = rand_place_file(rng, nm)
            files[f"{s}/{nm}.yon"] = content
            pinfo[nm] = {"fields": fnames, "op": has_op, "space": s}
    if pinfo and rng.random() < 0.85:
        nm = rng.choice(list(pinfo.keys()))
        files[f"{pinfo[nm]['space']}/{nm}.yon"] += rand_arrow(rng, pinfo)
    return files, spaces, list(pinfo.keys())


def mutate(rng, files, spaces, places):
    """Corrupt the project to hammer the reject/diagnostic paths (must not crash)."""
    for _ in range(rng.randint(1, 3)):
        keys = list(files.keys())  # recompute: earlier mutations add/remove files
        m = rng.randint(0, 8)
        if m == 0:  # drop a toml key
            files["yon.toml"] = "\n".join(
                l for l in files["yon.toml"].splitlines()
                if rng.random() > 0.4) + "\n"
        elif m == 1 and places:  # two places in one file (layout violation)
            k = rng.choice([x for x in keys if x.endswith(".yon") and "/" in x])
            files[k] += f"place Extra{rng.randint(0,9)} {{ z number }}\n"
        elif m == 2:  # unbalanced brace
            k = rng.choice(keys)
            files[k] = files[k].replace("}", "", 1) if "}" in files[k] else files[k] + "{"
        elif m == 3:  # a place file in the project root (not a space)
            files[f"Loose{rng.randint(0,9)}.yon"] = "place Loose { q number }\n"
        elif m == 4:  # garbage line injected
            k = rng.choice(keys)
            files[k] += rng.choice(["@@@ ??? ;\n", "place\n", "move from to {}\n",
                                    "view of {}\n", "reduction of\n", "}}}}\n"])
        elif m == 5:  # space in two worlds (manifest error)
            files["yon.toml"] += '[world.V]\nobjects=["C2"]\nspaces=[' + \
                (f'"{spaces[0]}"' if spaces else '"s0"') + ']\n'
        elif m == 6:  # reference a nonexistent place in an arrow
            k = rng.choice([x for x in keys if x.endswith(".yon") and "/" in x] or keys)
            files[k] += "view VG of NoSuchPlace { show a }\n"
        elif m == 7:  # empty a required file
            k = rng.choice(keys)
            files[k] = ""
        else:  # drop the Topos of a space
            tk = [x for x in keys if x.endswith("Topos.yon")]
            if tk:
                del files[rng.choice(tk)]
    return files


def classify(files):
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        for rel, content in files.items():
            p = d / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
        try:
            r = subprocess.run([str(EMIT), str(d)], capture_output=True, text=True, timeout=15)
        except subprocess.TimeoutExpired:
            return "CRASH", "timeout"
        if r.returncode < 0:
            return "CRASH", f"signal {-r.returncode}"
        err = r.stderr or ""
        if "Fatal error: exception" in err or "Stack overflow" in err:
            return "CRASH", (err.strip().splitlines() or [""])[0][:200]
        return ("accept" if r.returncode == 0 else "reject"), ""


def run(seed, cases):
    rng = random.Random(seed)
    acc = rej = 0
    bugs = []
    kinds = ["view", "move ", "reduction", "functor", "geomorph", "with effects"]
    cov = {k: [0, 0] for k in kinds}  # [generated, accepted]
    for _ in range(cases):
        files, spaces, places = gen_files(rng)
        if rng.random() < 0.55:
            files = mutate(rng, dict(files), spaces, places)
        blob = "".join(files.values())
        verdict, detail = classify(files)
        for k in kinds:
            if k in blob:
                cov[k][0] += 1
                if verdict == "accept":
                    cov[k][1] += 1
        if verdict == "CRASH":
            bugs.append((detail, files))
        elif verdict == "accept":
            acc += 1
        else:
            rej += 1
    print(f"project-fuzz (seed {seed}, {cases} cases): accept={acc} reject={rej} BUGS={len(bugs)}")
    print("  coverage (generated / of-those-accepted): "
          + ", ".join(f"{k.strip()} {cov[k][0]}/{cov[k][1]}" for k in kinds))
    if bugs:
        print("\n--- crashes (a project the frontend could not handle without a Fatal) ---")
        seen = set()
        for detail, files in bugs:
            if detail in seen:
                continue
            seen.add(detail)
            print(f"\n[CRASH] {detail}")
            for rel, content in files.items():
                print(f"  === {rel} ===\n" + "\n".join("    " + l for l in content.splitlines()))
        print(f"\n({len(bugs)} total, {len(seen)} distinct)")
    return 0 if not bugs else 1


if __name__ == "__main__":
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 20260701
    cases = int(sys.argv[2]) if len(sys.argv) > 2 else 1500
    if not EMIT.exists():
        print(f"SKIP: {EMIT} not built (cd frontend && dune build ./yoner_emit_mlir.exe)")
        sys.exit(0)
    sys.exit(run(seed, cases))
