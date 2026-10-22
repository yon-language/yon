"""Writes Entry.yon next to this script: HashMap against XRelMap and HashSet
against XRelSet, on the same keys.

Yon cannot choose at run time which map a loop uses, so each (family, key
kind) gets its own functions; this script writes them all from one template,
so the six variants are the same code but for the names. Regenerate with
    python3 regression/bench/maps_compare/gen.py

With no argument the program checks every combination at N = 1000 and
prints, for each, five values the suite knows (regression/test_benchmarks.py):
the size of the map (N), the keys it holds that `has` finds (N), the absent
keys it finds (0), the size of the union (3N/2) and of the intersection
(N/2) of the two sets: 30 numbers, no timing. For a measurement it runs one combination
per process, chosen on the command line: `maps_compare FAMILY KIND N` with FAMILY 0 = HashMap/HashSet,
1 = XRelMap/XRelSet, and KIND 0 = LatticePoint, 1 = Number, 2 = Text. It
prints five integers, ns per operation, each the minimum over REPS runs:
  set   N persistent sets building a map, net of an exact twin (the same
        loop making the same keys without the map)
  get   N reads of keys the map holds, net of the same twin
  miss  N reads of keys it does not hold, net of their own twin (0 for
        LatticePoint keys: every point of the shell is a key once N = 196560)
  union, intersect   of two sets of N keys sharing N/2, per key of one set
"""
from pathlib import Path

REPS = 3
# name: (Yon type, key k, absent key k); a LatticePoint key is made by a match
KINDS = [
    ("point", "LatticePoint", None, None),
    ("number", "Number", "k * 0.5", "k * 0.5 + 0.25"),
    ("text", "String", "String.from_int(k)", 'String.concat(String.from_int(k), "x")'),
]
FAMILIES = [("hash", "HashMap", "HashSet"), ("xrel", "XRelMap", "XRelSet")]

POINT = "match LatticePoint.at_index(k % 196560) {{ LatticePoint as key => {op}, DomainError as d => {none} }}"

out = []
w = out.append
w("place Entry {")
w("  fun mn(a: Number, b: Number): Number { return if a < b then a else b }")
for fam, Map, Set in FAMILIES:
    for kind, ty, make, miss in KINDS:
        p = f"{fam}_{kind}"
        M, S = f"{Map}<{ty}, Number>", f"{Set}<{ty}>"
        if kind == "point":
            w(f"  fun {p}_put(m: {M}, k: Number): {M} {{")
            w(f"    return {POINT.format(op=f'{Map}.set(m, key, k)', none='m')}")
            w("  }")
            w(f"  fun {p}_has(m: {M}, k: Number): Number {{")
            w(f"    return {POINT.format(op=f'(if {Map}.has(m, key) then 1 else 0)', none='0')}")
            w("  }")
            w(f"  fun {p}_add(s: {S}, k: Number): {S} {{")
            w(f"    return {POINT.format(op=f'{Set}.add(s, key)', none='s')}")
            w("  }")
            w(f"  fun {p}_twin(k: Number): Number {{")
            w(f"    return {POINT.format(op='1', none='0')}")
            w("  }")
        else:
            w(f"  fun {p}_put(m: {M}, k: Number): {M} {{ return {Map}.set(m, {make}, k) }}")
            w(f"  fun {p}_has(m: {M}, k: Number): Number {{ return if {Map}.has(m, {make}) then 1 else 0 }}")
            w(f"  fun {p}_miss(m: {M}, k: Number): Number {{ return if {Map}.has(m, {miss}) then 1 else 0 }}")
            w(f"  fun {p}_add(s: {S}, k: Number): {S} {{ return {Set}.add(s, {make}) }}")
            w(f"  fun {p}_twin(k: Number): Number {{")
            w(f"    be key := {make}")
            w("    return 1")
            w("  }")
            w(f"  fun {p}_miss_twin(k: Number): Number {{")
            w(f"    be key := {miss}")
            w("    return 1")
            w("  }")

        def loop(name, args, body_acc, ret="Number"):
            w(f"  fun {p}_t_{name}({args}): {ret} visits Output {{")
            w("    be acc := 0")
            w("    be k := 0")
            w("    be t0 := Time.now_ns(0)")
            w("    iter n do {")
            w(f"      acc = acc + {body_acc}")
            w("      k = k + 1")
            w("    }")
            w("    return Time.now_ns(0) - t0 + 0 * acc")
            w("  }")

        w(f"  fun {p}_build(n: Number): {M} {{")
        w(f"    be m := {Map}.empty()")
        w("    be k := 0")
        w("    iter n do {")
        w(f"      m = {p}_put(m, k)")
        w("      k = k + 1")
        w("    }")
        w("    return m")
        w("  }")
        w(f"  fun {p}_t_build(n: Number): Number visits Output {{")
        w("    be t0 := Time.now_ns(0)")
        w(f"    be m := {p}_build(n)")
        w("    be t1 := Time.now_ns(0)")
        w(f"    return (t1 - t0) + 0 * {Map}.size(m)")
        w("  }")
        loop("twin", "n: Number", f"{p}_twin(k)")
        loop("get", f"m: {M}, n: Number", f"{p}_has(m, k)")
        if miss:
            loop("miss", f"m: {M}, n: Number", f"{p}_miss(m, k)")
            loop("miss_twin", "n: Number", f"{p}_miss_twin(k)")
        w(f"  fun {p}_set(start: Number, n: Number): {S} {{")
        w(f"    be s := {Set}.empty()")
        w("    be k := start")
        w("    iter n do {")
        w(f"      s = {p}_add(s, k)")
        w("      k = k + 1")
        w("    }")
        w("    return s")
        w("  }")
        for op, call in (("union", "union"), ("inter", "intersect")):
            w(f"  fun {p}_t_{op}(a: {S}, b: {S}): Number visits Output {{")
            w("    be t0 := Time.now_ns(0)")
            w(f"    be u := {Set}.{call}(a, b)")
            w(f"    return Time.now_ns(0) - t0 + 0 * {Set}.size(u)")
            w("  }")
        # the values the suite checks: what the map and the sets hold
        w(f"  fun {p}_count_has(m: {M}, n: Number): Number {{")
        w("    be acc := 0")
        w("    be k := 0")
        w("    iter n do {")
        w(f"      acc = acc + {p}_has(m, k)")
        w("      k = k + 1")
        w("    }")
        w("    return acc")
        w("  }")
        if miss:
            w(f"  fun {p}_count_miss(m: {M}, n: Number): Number {{")
            w("    be acc := 0")
            w("    be k := 0")
            w("    iter n do {")
            w(f"      acc = acc + {p}_miss(m, k)")
            w("      k = k + 1")
            w("    }")
            w("    return acc")
            w("  }")
        w(f"  fun {p}_check(n: Number): Number visits Output {{")
        w(f"    be m := {p}_build(n)")
        w(f"    be a := {p}_set(0, n)")
        w(f"    be b := {p}_set(n / 2, n)")
        w(f"    be _0 := Output.print(String.from_int({Map}.size(m)))")
        w(f"    be _1 := Output.print(String.from_int({p}_count_has(m, n)))")
        w(f"    be _2 := Output.print(String.from_int(" + (f"{p}_count_miss(m, n)" if miss else "0") + "))")
        w(f"    be _3 := Output.print(String.from_int({Set}.size({Set}.union(a, b))))")
        w(f"    be _4 := Output.print(String.from_int({Set}.size({Set}.intersect(a, b))))")
        w("    return 0")
        w("  }")
        w(f"  fun {p}_row(n: Number): Number visits Output {{")
        w(f"    be m := {p}_build(n)")
        w(f"    be a := {p}_set(0, n)")
        w(f"    be b := {p}_set(n / 2, n)")
        w(f"    be tb := {p}_t_build(n)")
        w(f"    be tw := {p}_t_twin(n)")
        w(f"    be tg := {p}_t_get(m, n)")
        w(f"    be tm := {p}_t_miss(m, n)" if miss else "    be tm := 0")
        w(f"    be tmw := {p}_t_miss_twin(n)" if miss else "    be tmw := 0")
        w(f"    be tu := {p}_t_union(a, b)")
        w(f"    be ti := {p}_t_inter(a, b)")
        w(f"    iter {REPS - 1} do {{")
        w(f"      tb = mn(tb, {p}_t_build(n))")
        w(f"      tw = mn(tw, {p}_t_twin(n))")
        w(f"      tg = mn(tg, {p}_t_get(m, n))")
        if miss:
            w(f"      tm = mn(tm, {p}_t_miss(m, n))")
            w(f"      tmw = mn(tmw, {p}_t_miss_twin(n))")
        w(f"      tu = mn(tu, {p}_t_union(a, b))")
        w(f"      ti = mn(ti, {p}_t_inter(a, b))")
        w("    }")
        for i, e in enumerate(["(tb - tw) / n", "(tg - tw) / n", "(tm - tmw) / n", "tu / n", "ti / n"]):
            w(f"    be _{i} := Output.print(String.from_int({e}))")
        w("    return 0")
        w("  }")

w("  fun arg(i: Number): Number { return String.parse_number(Args.get(i)) }")
w("  fun smoke(n: Number): Number visits Output {")
for fam, _, _ in FAMILIES:
    for kind, _, _, _ in KINDS:
        w(f"    be _{fam}_{kind} := {fam}_{kind}_check(n)")
w("    return 0")
w("  }")
w("  fun main(): Number visits Output {")
w("    be full := Args.count(0) >= 4")
w("    be fam := if full then arg(1) else 0")
w("    be kind := if full then arg(2) else 0")
w("    be n := if full then arg(3) else 1000")
# the first point pays the one-time mmgroup table init; pay it before timing
w("    be _warm := hash_point_twin(0)")
chain = []
for fi, (fam, _, _) in enumerate(FAMILIES):
    for ki, (kind, _, _, _) in enumerate(KINDS):
        chain.append((fi, ki, f"{fam}_{kind}_row(n)"))
expr = "1"
for fi, ki, call in reversed(chain):
    expr = f"(if fam == {fi} and kind == {ki} then {call} else {expr})"
w("    return if full then " + expr + " else smoke(n)")
w("  }")
w("}")
Path(__file__).with_name("Entry.yon").write_text("\n".join(out) + "\n")
