"""The rule of the pair: every control predicate has a test that it says "yes" and one that it says "no".

A control predicate is a rule that refuses (a code of frontend/error_codes.ml), a certifier, a check
of a law, or the verifier of an MLIR pass. A predicate with only "no" tests may be a predicate that
refuses everything near the case; one with only "yes" tests may be one that accepts everything.
Each predicate is in PAIRS, with both halves, or in UNCOVERED, with the reason. UNCOVERED is the
debt: it only shrinks (regression/test_control_pairs.py checks that it does not grow, that each of
its names is still a predicate without a pair, and that each half of PAIRS exists and says what it
claims: a refusal by its code and by the words of its reason).

A half is one of:
  py:<file>::<test>        a test of the suite; for a "no", the test's source holds the code and
                           the words of the entry
  ml:<file>::<name>        a unit test of frontend/ (test_*.ml), found by name
  fixture:<dir>            a negative fixture: a line of regression/yon_tests/rejections.txt with
                           the code and the words of the entry ("no" only)
  canon:<file>.expect      a canonical form: `status: accept` for a "yes"; for a "no" the code and
                           the words of the entry in its `code:` and `match:`
  twin:<code>              the negative fixture of the code with its fault mended (TWINS below), run
                           by test_control_pairs.py::test_the_mended_fixture_is_accepted ("yes" only)
"""
from dataclasses import dataclass, field


@dataclass
class Pair:
    code: str            # the code of the refusal, "" for a certifier that refuses through another
    words: str           # the words the "no" carries
    yes: list = field(default_factory=list)
    no: list = field(default_factory=list)
    site: str = ""       # where the predicate lives


NEG = "regression/yon_tests/negative/"
_LEFT = ("place Left uses algebra Monoid {\n  this > None :U Some\n"
         "  fun op(a: Left, b: Left): Left { return match a { None => b, Some => Some } }\n"
         "  fun unit: Left { return None }\n}\n")

# The negative fixture of a code with the least change that removes the fault: (fixture, edits).
# An edit is a list of (old, new) replacements, each found once; a whole new text; None to remove
# the file; or "rename" for a key "old>new".
TWINS = {
    "E2002": ("return_outside_the_tail", {"Entry.yon": [("  return 9\n", "")]}),
    "E2004": ("shared_arm_without_an_expected_type", {"Entry.yon": [("y := Yes", "y := Ask.Yes")]}),
    "E2006": ("place_named_like_a_library_place", {
        "Entry.yon": [("of Math", "of Mathx"), ("visits Math", "visits Mathx"), ("Math.gcd", "Mathx.gcd")],
        "w/Math.yon": [("place Math", "place Mathx")], "w/Math.yon>w/Mathx.yon": "rename"}),
    "E2007": ("is_given_in_a_user_file", {"Left.yon": _LEFT}),
    "E2008": ("store_into_a_value", {"Entry.yon": [("x := 1", "mut x := 1")]}),
    "E2010": ("proof_fun_that_does_not_terminate", {"Entry.yon": [("return giro(n)", "return n")]}),
    "E2011": ("error_bind_without_on_error", {"Entry.yon": [
        ("fun f(x: Number): Number", "fun f(x: Number) on error DomainError: Number"),
        ("return f(4)", "return match f(4) { Number as v => v, DomainError as d => 100 }")]}),
    "E2012": ("error_bind_without_escape", {"Entry.yon": [("return Number.sqrt(x)", "return escape Number.sqrt(x)")]}),
    "E2013": ("error_bind_needless_escape", {"Entry.yon": [("return escape x + 1", "return escape Number.sqrt(x) + 1")]}),
    "E2101": ("law_of_an_algebra_not_held", {"Left.yon": _LEFT}),
    "E2102": ("operation_of_an_unknown_algebra", {"Or.yon": [("BooleanOrr", "BooleanOr")]}),
    "E3001": ("drop_before_a_use", {"Entry.yon": [("  drop D\n  r := d_op(5)\n", "  r := d_op(5)\n  drop D\n")]}),
    "E3002": ("drop_of_an_unknown_space", {"Entry.yon": [("  drop Zeta\n  r := d_op(5)\n", "  r := d_op(5)\n  drop D\n")]}),
    "E3010": ("import_across_worlds", {
        "yon.toml": [('spaces=["A"]', 'spaces=["A","Bx"]'), ('spaces=["Bx","C"]', 'spaces=["C"]')],
        "C/CP.yon": [("import svc::b_op from Bx\n", ""), ("mut r := b_op(x)", "mut r := x + 1")]}),
    "E4001": ("topos_layout", {"A/Topos2.yon": None}),
    "E2025": ("name_of_the_runtime", {"Entry.yon": [("yon_rt_section", "section")]}),
    "E2020": ("place_not_positive", {"Bad.yon": [("f Bad -> Number", "f Number -> Bad")]}),
    "E3011": ("operations_with_one_selector", {"Entry.yon": [("fun op_danb(", "fun op_other(")]}),
    "E2021": ("index_reads_a_variable", {"Entry.yon": [("    p := clear c\n", "    v := c\n    p := clear v\n")]}),
}

PAIRS = {
    # the codes of the registry
    "E1001": Pair("E1001", "let", yes=["canon:regression/canonical_forms/binding/canonical.expect"],
                  no=["canon:regression/canonical_forms/binding/dev_let.expect"]),
    "E1002": Pair("E1002", "unexpected character $",
                  yes=["py:regression/test_error_codes.py::test_lexer_error_carries_e1002"],
                  no=["py:regression/test_error_codes.py::test_lexer_error_carries_e1002"]),
    "E1003": Pair("E1003", "a quantifier carries its type",
                  yes=["canon:regression/canonical_forms/algebra/canonical.expect"],
                  no=["canon:regression/canonical_forms/algebra/dev_untyped_quantifier.expect"]),
    "E2001": Pair("E2001", "written x ↪ Full", yes=["canon:regression/canonical_forms/coproduct/canonical.expect"],
                  no=["canon:regression/canonical_forms/coproduct/dev_old_injection.expect"]),
    "E2002": Pair("E2002", "this `return` is not at the end of its body", yes=["twin:E2002"],
                  no=["fixture:" + NEG + "return_outside_the_tail"]),
    "E2004": Pair("E2004", "nothing here says which coproduct it injects into", yes=["twin:E2004"],
                  no=["fixture:" + NEG + "shared_arm_without_an_expected_type"]),
    "E2006": Pair("E2006", "takes the name of a place of the library", yes=["twin:E2006"],
                  no=["fixture:" + NEG + "place_named_like_a_library_place"]),
    "E2007": Pair("E2007", "the primitives of the runtime are declared in the prelude only", yes=["twin:E2007"],
                  no=["fixture:" + NEG + "is_given_in_a_user_file"]),
    "E2008": Pair("E2008", "a value does not change", yes=["twin:E2008"],
                  no=["fixture:" + NEG + "store_into_a_value"]),
    "E2010": Pair("E2010", "it does not pass the termination check", yes=["twin:E2010"],
                  no=["fixture:" + NEG + "proof_fun_that_does_not_terminate"]),
    "E2011": Pair("E2011", "so the error has no way out", yes=["twin:E2011"],
                  no=["fixture:" + NEG + "error_bind_without_on_error"]),
    "E2012": Pair("E2012", "without escape", yes=["twin:E2012"],
                  no=["fixture:" + NEG + "error_bind_without_escape"]),
    "E2013": Pair("E2013", "there is nothing to escape", yes=["twin:E2013"],
                  no=["fixture:" + NEG + "error_bind_needless_escape"]),
    "E3011": Pair("E3011", "have the same selector on the wire", yes=["twin:E3011"],
                  no=["fixture:" + NEG + "operations_with_one_selector"]),
    "E2101": Pair("E2101", "is refuted",
                  yes=["twin:E2101",
                       "py:regression/test_heyting_algebra.py::"
                       "test_the_laws_of_a_heyting_algebra_are_certified_on_the_three_truth_values"],
                  no=["fixture:" + NEG + "law_of_an_algebra_not_held",
                      "py:regression/test_heyting_algebra.py::test_the_excluded_middle_is_refuted_on_omega"]),
    "E2102": Pair("E2102", "is no algebra", yes=["twin:E2102"],
                  no=["fixture:" + NEG + "operation_of_an_unknown_algebra"]),
    "E3001": Pair("E3001", "is still reachable downstream", yes=["twin:E3001"],
                  no=["fixture:" + NEG + "drop_before_a_use"]),
    "E3002": Pair("E3002", "unknown Space Zeta", yes=["twin:E3002"],
                  no=["fixture:" + NEG + "drop_of_an_unknown_space"]),
    "E3010": Pair("E3010", "wire crosses a world boundary", yes=["twin:E3010"],
                  no=["fixture:" + NEG + "import_across_worlds"]),
    "E4001": Pair("E4001", "declares 2 topos files", yes=["twin:E4001"],
                  no=["fixture:" + NEG + "topos_layout"]),
    "E2020": Pair("E2020", "Bad appears left of an arrow in the field f of Bad",
                  yes=["twin:E2020", "py:regression/test_positivity.py::"
                       "test_a_place_right_of_the_arrow_of_a_parametric_place_is_accepted"],
                  no=["fixture:" + NEG + "place_not_positive"]),
    "E2021": Pair("E2021", "the index of a type reads the variable `c`",
                  yes=["twin:E2021",
                       "py:regression/test_index_is_a_value.py::test_the_endpoints_of_a_walk_on_a_bound_value_are_accepted",
                       "py:regression/test_index_is_a_value.py::test_a_path_on_a_bound_value_in_the_type_of_a_lambda_parameter_is_accepted",
                       "py:regression/test_index_is_a_value.py::test_the_application_of_a_bound_function_to_a_path_is_accepted",
                       "py:regression/test_index_is_a_value.py::test_a_fun_as_the_term_argument_of_a_place_is_accepted"],
                  no=["fixture:" + NEG + "index_reads_a_variable",
                      "py:regression/test_index_is_a_value.py::test_the_endpoints_of_a_walk_on_a_variable_are_refused",
                      "py:regression/test_index_is_a_value.py::test_a_path_on_a_variable_in_the_type_of_a_lambda_parameter_is_refused",
                      "py:regression/test_index_is_a_value.py::test_the_application_of_a_variable_to_a_path_is_refused",
                      "py:regression/test_index_is_a_value.py::test_a_variable_as_the_term_argument_of_a_place_is_refused"],
                  site="frontend/tycheck.ml::index_of"),
    "E2025": Pair("E2025", "the name `yon_rt_section` is reserved", yes=["twin:E2025"],
                  no=["fixture:" + NEG + "name_of_the_runtime"]),
    "E4002": Pair("E4002", "ENTRYPOINT ERROR", yes=["canon:regression/canonical_forms/entrypoint/canonical.expect"],
                  no=["canon:regression/canonical_forms/entrypoint/dev_b.expect"]),
    "Catt_r_yon.factor_through": Pair("", "", site="frontend/catt_r_yon.ml",
        yes=["ml:frontend/catt_r_yon.ml::test_factorization"],
        no=["ml:frontend/catt_r_yon.ml::test_non_commuting_cone_does_not_factor"]),
    # the certifiers of the kernel and the occur check (mutants of the first round: "always
    # yes" left gate 1 and the wide set green; their oracles are frontend/test_*.ml)
    "Core_check.certify_ty": Pair("", "Id endpoints not of the carrier type", site="frontend/core_check.ml",
        yes=["ml:frontend/test_core_check.ml::certify_ty certifies Id(number, 1, 2)"],
        no=["ml:frontend/test_core_check.ml::certify_ty refuses Id(number, 1, fun x -> x) with its words"]),
    "Core_check.certify_term": Pair("", "body does not check against its declared type",
        site="frontend/core_check.ml",
        yes=["ml:frontend/test_core_check.ml::(b) certify_term CERTIFIES a well-typed pure-dependent body"],
        no=["ml:frontend/test_core_check.ml::(c'') certify_term refuses it with the words of the gate"]),
    "Core_check.check_strict": Pair("", "", site="frontend/core_check.ml::check_strict",
        yes=["ml:frontend/test_core_check.ml::(b) certify_term CERTIFIES a well-typed pure-dependent body"],
        no=["ml:frontend/test_core_check.ml::(c') check_strict is false on the ill-typed body"]),
    "Ty_subst.occur_check": Pair("", "(infinite type)", site="frontend/ty_subst.ml",
        yes=["ml:frontend/test_ty_subst.ml::unify alpha0 with list of alpha1 -> unified"],
        no=["ml:frontend/test_ty_subst.ml::unify alpha0 with list of alpha0 -> refused with the words of the occur check"]),
    "E4004": Pair("E4004", "unterminated string",
                  yes=["py:regression/test_error_codes.py::test_manifest_error_carries_e4004"],
                  no=["py:regression/test_error_codes.py::test_manifest_error_carries_e4004"]),
}

# The predicates without a pair, each with the reason. It only shrinks.
UNCOVERED = {
    # codes produced today, whose "yes" is not written yet
    "E2003": "the accepting half (an operation with its handler) is not written",
    "E2005": "the accepting half (an arm and an arrow with two names) is not written",
    "E2009": "produced by a prelude with a heap fun only (OUTSIDE_THE_FIXTURES of test_error_codes.py)",
    "E3003": "the accepting half (a union whose arms live in one Space) is not written",
    # codes registered with no producer (NO_PRODUCER of test_error_codes.py): no "no" yet
    "E1004": "no producer", "E2014": "no producer", "E2015": "no producer", "E2016": "no producer",
    "E2017": "no producer", "E2018": "no producer", "E2019": "no producer",
    "E2022": "no producer", "E2023": "no producer", "E2024": "no producer",
    "E4003": "no constructor site",
    # the certifiers found by name: none refuses with a code of its own
    "Core_wf.certify_program": "advisory: the gate YON_CORE_WF reports counts, not a refusal with a code",
    "Tycheck.certify_dependent_cone": ("the certificate is computed, but where the checker reaches it every "
                                       "constructor has its branch: a missing one is refused before, E2001"),
    "Tycheck.cell_match": "a rule of the checker without a refusal of its own code",
    # the verifiers of the MLIR passes
    "mlir:algebra-verifier": "no test of the pair names its refusal",
    "mlir:ccc-equations-check": "not in the pipeline of yonc",
    "mlir:coherence-elimination": "not in the pipeline of yonc",
    "mlir:heyting-short-circuit": "not in the pipeline of yonc",
    "mlir:topos-type-preservation": "not in the pipeline of yonc",
    "mlir:topos-progress": "not in the pipeline of yonc",
    "mlir:topos-type-equiv-sanity": "not in the pipeline of yonc",
    "mlir:topos-hm-inference": "not in the pipeline of yonc",
    "mlir:topos-giraud-check": "not in the pipeline of yonc",
    "mlir:topos-simpson6": "not in the pipeline of yonc",
    "mlir:topos-localisation-decomp": "not in the pipeline of yonc",
    "mlir:topos-internal-lang": "not in the pipeline of yonc",
    "mlir:topos-alpha-rename": "not in the pipeline of yonc",
}

# The debt at the start of group S0: UNCOVERED never holds more names than this.
UNCOVERED_AT_MOST = 31

# Names the grep of the certifiers finds that are no predicate, with the reason.
NOT_PREDICATES = {
    "Desugar.is_naturality_check": "a test on the name of a generated fun",
    "Main.subst_check": "a local boolean of a unit test of main.ml",
}
