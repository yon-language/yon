"""The mutants: one control predicate each, with the answer that accepts everything.

A mutant names the file, the predicate and the "always yes" of that predicate, well typed:
  ocaml  the guard `if Sys.opaque_identity true then (YES) else` is put in front of the body of the
         definition whose head matches `head` (the line after the head's `=`);
  cpp    every `signalPassFailure()` of the n-th `runOnOperation` of the file becomes a no-op, so
         the pass never fails (its diagnostics may still print).
The set is the grep of the certifiers (certify_*, *_check, factor_through, is_*_alias, cell_match),
the verifiers of the MLIR passes, and the predicates of regression/control_pairs.py.
"""
import difflib
import re
from dataclasses import dataclass


class NotApplied(Exception):
    pass


@dataclass
class Mutant:
    id: str
    file: str
    predicate: str
    kind: str          # "ocaml" or "cpp"
    head: str = ""     # ocaml: a regex matching the first line of the definition
    yes: str = ""      # ocaml: the accepting answer
    nth: int = 0       # cpp: which runOnOperation (0-based)
    why: str = ""


def _ocaml(m, src):
    lines = src.split("\n")
    hits = [i for i, l in enumerate(lines) if re.search(m.head, l)]
    if len(hits) != 1:
        raise NotApplied(f"head matches {len(hits)} lines")
    i = hits[0]
    j = i
    while j < len(lines) and not re.search(r"=\s*(\(\*.*\*\))?\s*$", lines[j]):
        j += 1
        if j - i > 12:
            raise NotApplied("no `=` closing the head within 12 lines")
    indent = re.match(r"\s*", lines[i]).group(0) + "  "
    lines.insert(j + 1, f"{indent}if Sys.opaque_identity true then ({m.yes}) else")
    return "\n".join(lines)


def _cpp(m, src):
    starts = [x.start() for x in re.finditer(r"void runOnOperation\(\)", src)]
    if m.nth >= len(starts):
        raise NotApplied(f"only {len(starts)} runOnOperation")
    a = starts[m.nth]
    b = starts[m.nth + 1] if m.nth + 1 < len(starts) else len(src)
    body = src[a:b]
    n = body.count("signalPassFailure()")
    if n == 0:
        raise NotApplied("no signalPassFailure in this pass")
    return src[:a] + body.replace("signalPassFailure()", "(void)0 /* mutant */") + src[b:]


def apply(m, src):
    if m.kind == "control":
        return src + "\n(* the control of the round: a comment, the gate must stay green *)\n"
    return _ocaml(m, src) if m.kind == "ocaml" else _cpp(m, src)


def show(old, new):
    return "\n".join(difflib.unified_diff(old.split("\n"), new.split("\n"), lineterm="", n=1))


def O(id, file, predicate, head, yes, why=""):
    return Mutant(id, file, predicate, "ocaml", head=head, yes=yes, why=why)


def C(id, file, predicate, nth, why=""):
    return Mutant(id, file, predicate, "cpp", nth=nth, why=why)


MUTANTS = [
    # the control: the export with a comment added to the checker; gate 1 must stay green on it
    Mutant("control", "frontend/tycheck.ml", "(none: a comment)", "control",
           why="the export and its gate work: this one must be SURVIVED"),
    # the grep of the certifiers
    O("certify_ty", "frontend/core_check.ml", "Core_check.certify_ty",
      r"^let certify_ty ", "`Ok"),
    O("certify_term", "frontend/core_check.ml", "Core_check.certify_term",
      r"^let certify_term ", "`Ok"),
    O("check_strict", "frontend/core_check.ml", "Core_check.check_strict",
      r"^let rec check_strict ", "true"),
    O("certify_program", "frontend/core_wf.ml", "Core_wf.certify_program",
      r"^let certify_program ",
      "Ok { certified = 0; skipped = 0; bodies_checked = 0; bodies_skipped = 0; "
      "proofs_certified = []; proofs_skipped = [] }"),
    O("occur_check", "frontend/ty_subst.ml", "Ty_subst.occur_check",
      r"^let occur_check ", "false", "accepting = no cycle found"),
    O("factor_through", "frontend/catt_r_yon.ml", "Catt_r_yon.factor_through (factor_with)",
      r"^let factor_with ", "Some univ", "the body of factor_through and factor_from"),
    O("certify_dependent_cone", "frontend/tycheck.ml", "Tycheck.certify_dependent_cone",
      r"^let certify_dependent_cone ", "true"),
    O("cell_match", "frontend/tycheck.ml", "Tycheck.cell_match",
      r"^and cell_match env ctx branches x loc",
      "Ok (match expected with Some t -> t | None -> TyPrim \"unknown\")"),
    # the predicates of the registry (regression/control_pairs.py)
    O("type_equal", "frontend/dispatcher.ml", "Dispatcher.type_equal",
      r"^let rec type_equal$", "true"),
    O("subtype", "frontend/dispatcher.ml", "Dispatcher.subtype",
      r"^let (rec )?subtype \(env", "true"),
    O("is_ring_carrier", "frontend/dispatcher.ml", "Dispatcher.is_ring_carrier",
      r"^let is_ring_carrier ", "true"),
    O("is_pure_expr", "frontend/tyenv.ml", "Tyenv.is_pure_expr",
      r"^let rec is_pure_expr ", "true"),
    O("sct_certify", "frontend/sct.ml", "Sct.certify",
      r"^let certify \(fns", "List.map (fun (fd : fundef) -> fd.name) fns"),
    O("check_drops", "frontend/space_liveness.ml", "Space_liveness.check_drops",
      r"^let check_drops ", "[]"),
    O("check_models", "frontend/algebra_check.ml", "Algebra_check.check_models",
      r"^let check_models ", "[]"),
    O("check_named_algebras", "frontend/algebra_check.ml", "Algebra_check.check_named_algebras",
      r"^let check_named_algebras ", "[]"),
    O("check_visibility", "frontend/module_prefix.ml", "Module_prefix.check_visibility",
      r"^let check_visibility ", "()"),
    O("naturality_check", "frontend/naturality_symcheck.ml", "Naturality_symcheck.check",
      r"^let check \(fun_idx", "Proven"),
    O("ring_equal", "frontend/naturality_symcheck.ml", "Naturality_symcheck.ring_equal",
      r"^let ring_equal ", "Some true"),
    # the predicates of the group S0
    O("index_of", "frontend/tycheck.ml", "Tycheck.index_of",
      r"^let index_of ", "ok (TyTermExpr e)", "accepting = every index is a value"),
    O("positivity_errors", "frontend/tycheck.ml", "Tycheck.positivity_errors",
      r"^let positivity_errors ", "[]"),
    O("reserved_names", "frontend/tycheck.ml", "Tycheck.reserved_names",
      r"^let reserved_names ", "[]"),
    O("decide_g3", "frontend/algebra_check.ml", "Algebra_check.decide_g3",
      r"^let decide_g3 ", "Law_check.Proven \"mutant\""),
    # the verifiers of the MLIR passes
    C("AlgebraVerifier", "mlir/passes/AlgebraVerifier.cpp", "AlgebraVerifier", 0),
    C("CCCEquationsCheck", "mlir/passes/CCCEquationsCheck.cpp", "CCCEquationsCheck", 0),
    C("CoherenceElimination", "mlir/passes/CoherenceElimination.cpp", "CoherenceElimination", 0),
    C("HeytingShortCircuit", "mlir/passes/HeytingShortCircuit.cpp", "HeytingShortCircuit", 0),
] + [C(f"StructuralPasses_{k}", "mlir/passes/StructuralPasses.cpp", f"StructuralPasses pass {k}", k)
     for k in range(10)]
