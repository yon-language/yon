"""Shared pytest configuration for the Yon test suite.

Registers and AUTO-APPLIES two marker families so the whole suite is a real,
measurable test pyramid sliceable by layer and by kind:

    pytest -m unit          # isolates one module / function / pass
    pytest -m functional    # a language feature works / is rejected (frontend)
    pytest -m integration   # full end-to-end, multiple components, running binary
    pytest -m c             # every C-runtime test
    pytest -m "yon and functional"

Layers:  yon | ocaml | mlir | llvm | c
Kinds:   unit | functional | integration

  unit        — calls one module's function / one MLIR pass / one C function with
                hand-built inputs and asserts the exact output or verdict.
  functional  — exercises a language FEATURE through the relevant frontend
                pipeline (a construct emits MLIR; a proof type-checks; an
                ill-typed program is rejected): black-box, feature-level, stops
                short of a running native binary.
  integration — the full chain to a running binary (.yon -> MLIR -> LLVM -> link
                -> run -> exit code), multi-file projects, cross-process wires.

Marks are assigned centrally here (per module, and per test function for the
mixed modules), so individual tests need no annotations.
"""

import pytest

LAYERS = {"yon", "ocaml", "mlir", "llvm", "c"}
KINDS = {"unit", "functional", "integration"}
SPEEDS = {"fast", "slow", "bench", "fuzz"}

# module basename -> speed class (default "fast"). Lets the harness slice by cost:
#   pytest -m "not slow and not bench and not fuzz"   # the quick inner loop
#   pytest -m bench                                    # the pytest-benchmark suite
#   pytest -m fuzz                                     # the property fuzzers
_SPEED = {
    "test_benchmarks": "bench",
    "test_spawn_scaling": "bench",
    "test_wire_throughput": "bench",
    "test_perf": "bench",                 # bench_perf/test_perf.py (pytest-benchmark)
    "test_surface_fuzz": "fuzz",
    "test_surface_fuzz_projects": "fuzz",
    "test_metatheory_fuzz": "fuzz",
    "test_cross_space_runtime": "slow",
    "test_source_binary_diff": "slow",
    "test_c_coverage": "slow",            # rebuilds the runtime instrumented (opt-in)
}

# module basename -> default (layer, kind)
_MODULE_DEFAULT = {
    "test_runtime_units": ("c", "unit"),          # direct C-function self-tests
    "test_mlir_passes":   ("mlir", "unit"),        # one topos-opt pass per node
    "test_site":          ("ocaml", "unit"),       # OCaml site oracle + properties
    "test_yon_coverage":  ("yon", "functional"),   # construct micro-tests (emit)
    "test_projects":      ("yon", "functional"),   # a project compiles
    "test_cross_space_runtime": ("yon", "integration"),  # multi-process, runs binaries
    "test_interp":        ("ocaml", "functional"),  # eval_runner (interpreter) over corpus
    "test_c_coverage":    ("c", "unit"),            # gcov floor gate (opt-in --gcov)
    "test_selfhost":      ("yon", "integration"),   # Yon-in-Yon seeds compile + run
}

# modules that MIX kinds: per test-function-name overrides, plus a module default.
_FUNC_OVERRIDE = {
    "test_yon_pipeline": (
        ("yon", "integration"),                    # module default
        {
            "test_example":       ("yon", "integration"),  # compile + run + exit code
            "test_ocaml_oracle":  ("ocaml", "unit"),       # one test_*.exe per node
            "test_runtime_mphf":  ("c", "unit"),           # MPHF bijection self-test
        },
    ),
    "test_yon_selfhost": (
        ("yon", "functional"),                     # module default
        {
            "test_proof_in_yon":    ("yon", "functional"),   # a proof type-checks
            "test_negative_in_yon": ("yon", "functional"),   # a bad program is rejected
            "test_runtime_in_yon":  ("yon", "integration"),  # binary runs, exit 0
            "test_mlir_erasure":    ("yon", "functional"),   # emitted MLIR property
        },
    ),
}


def pytest_addoption(parser):
    parser.addoption(
        "--stretch", action="store", type=float, default=1.0,
        help="scale factor for stretchable tests (fuzz case counts, soak sizes, "
             "bench rounds); 1.0 is the fast default, e.g. 100.0 for a nightly run",
    )
    parser.addoption(
        "--gcov", action="store_true", default=False,
        help="run the opt-in C gcov coverage gate (rebuilds the runtime instrumented, "
             "then restores it); off by default",
    )


def pytest_configure(config):
    for m in sorted(LAYERS | KINDS | SPEEDS):
        config.addinivalue_line("markers", f"{m}: Yon suite layer/kind/speed tag")
    config.addinivalue_line(
        "markers", "stretchable: scales its work by --stretch (fuzz / soak / bench)")


@pytest.fixture(scope="session")
def stretch(pytestconfig):
    """The --stretch factor (float, default 1.0). A stretchable test multiplies its
    base work count by this; use `max(1, int(BASE * stretch))` so 1.0 stays the fast
    baseline and a large factor makes an exhaustive run."""
    return float(pytestconfig.getoption("--stretch"))


def pytest_collection_modifyitems(config, items):
    for item in items:
        mod = item.module.__name__.split(".")[-1] if item.module else ""
        fn = getattr(item, "originalname", None) or item.name.split("[")[0]
        layer = kind = None
        if mod in _FUNC_OVERRIDE:
            default, table = _FUNC_OVERRIDE[mod]
            layer, kind = table.get(fn, default)
        elif mod in _MODULE_DEFAULT:
            layer, kind = _MODULE_DEFAULT[mod]
        if layer:
            item.add_marker(getattr(pytest.mark, layer))
            item.add_marker(getattr(pytest.mark, kind))
        item.add_marker(getattr(pytest.mark, _SPEED.get(mod, "fast")))
