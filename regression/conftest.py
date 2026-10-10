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

import re
from pathlib import Path

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
    "test_world_instance": ("yon", "integration"),     # two worlds side by side
    "test_interp":        ("ocaml", "functional"),  # eval_runner (interpreter) over corpus
    "test_c_coverage":    ("c", "unit"),            # gcov floor gate (opt-in --gcov)
    "test_selfhost":      ("yon", "integration"),   # Yon-in-Yon seeds compile + run
    "test_phase0_probes": ("yon", "integration"),   # improvement-plan probes P-01..P-16
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
        "--bench-publish", action="store_true", default=False,
        help="write the benchmark medians to website/src/data/bench-raw.json (the "
             "data the benchmarks page renders); off by default, so a test run "
             "never writes the site",
    )
    parser.addoption(
        "--skip-ledger", action="store", default=None,
        help="path of the declared-skips ledger: any skip not declared there, or a "
             "declared skip that ran, fails the session (gate.sh passes it)",
    )
    parser.addoption(
        "--gcov", action="store_true", default=False,
        help="run the opt-in C gcov coverage gate (rebuilds the runtime instrumented, "
             "then restores it); off by default",
    )


# ── Declared skips ────────────────────────────────────────────────────────────
# A skip is a test that did not run. With --skip-ledger (gate.sh passes it), the
# only skips allowed are those declared in the ledger, one `<node id>  # why` per
# line; any other skip fails the session, so a missing artifact or a fixture that
# vanished can no longer turn a module green by skipping itself. A declared skip
# that ran instead is stale and fails too (the ledger only states what is true).
# Entries for nodes that did not run here (a -m or -k subset) are ignored. A
# node is named relative to regression/ (`test_x.py::test_y[param]`): pytest's
# rootdir, hence the node id prefix, depends on how it was invoked.
_SKIPPED: set = set()
_REPORTED: set = set()


def _node_key(nodeid: str) -> str:
    return nodeid.split("regression/", 1)[-1]


def _read_skip_ledger(path: Path) -> dict:
    out = {}
    for line in path.read_text().splitlines():
        body = line.split("#", 1)
        node = body[0].strip()
        if node:
            out[node] = body[1].strip() if len(body) > 1 else ""
    return out


def pytest_runtest_logreport(report):
    # (under xdist the controller receives every worker's reports here)
    _REPORTED.add(_node_key(report.nodeid))
    # an xfail is reported as skipped with `wasxfail`: it ran, it is not a skip
    if report.skipped and not hasattr(report, "wasxfail"):
        _SKIPPED.add(_node_key(report.nodeid))


def pytest_sessionfinish(session, exitstatus):
    ledger_opt = session.config.getoption("--skip-ledger")
    # under xdist the controller sees every report; a worker checks nothing
    if not ledger_opt or hasattr(session.config, "workerinput"):
        return
    ledger = _read_skip_ledger(Path(ledger_opt))
    undeclared = sorted(_SKIPPED - set(ledger))
    stale = sorted(n for n in ledger if n in _REPORTED and n not in _SKIPPED)
    if undeclared or stale:
        tr = session.config.pluginmanager.get_plugin("terminalreporter")
        if tr:
            tr.write_sep("=", "skip ledger violated", red=True)
            for n in undeclared:
                tr.write_line(f"UNDECLARED SKIP: {n}")
            for n in stale:
                tr.write_line(f"STALE LEDGER ENTRY (the node ran): {n}")
        session.exitstatus = pytest.ExitCode.TESTS_FAILED


def pytest_configure(config):
    for m in sorted(LAYERS | KINDS | SPEEDS):
        config.addinivalue_line("markers", f"{m}: Yon suite layer/kind/speed tag")
    config.addinivalue_line(
        "markers", "stretchable: scales its work by --stretch (fuzz / soak / bench)")
    config.addinivalue_line(
        "markers", "machine: runs Yon binaries that use a machine-global name "
                   "(a TCP port, a fixed file path); serialized on one xdist worker")
    config.addinivalue_line(
        "markers", "serial: must run outside xdist workers; gate.sh runs it in the "
                   "serial phase, with the timing tests")
    # --gcov rebuilds the runtime objects every other test links against: it
    # cannot share the machine with a parallel run.
    if config.getoption("--gcov") and getattr(config.option, "numprocesses", None):
        raise pytest.UsageError("--gcov rebuilds the runtime in place; run it without -n")


# ── Parallel runs (pytest-xdist, `-n auto --dist loadgroup`) ──────────────────
# The suite's cost is the external toolchain (yonc -> topos-opt -> llc -> link ->
# run), not Python, so the speed-up is running nodes side by side. Names in the
# kernel's shared namespaces (a Space's shm heap, streams, RPC mailboxes) are
# scoped by the world instance (runtime: yon_rt_ipc_name, YON_WORLD), so two
# binaries running at once never meet there. What is still shared by concurrent
# nodes:
#   * machine-global names a program chooses itself: a TCP port, a fixed file
#     path. Programs that can use one go to ONE worker (xdist_group "machine").
#   * the fixed /tmp paths the self-host compiler reads and writes
#     (/tmp/yon_selfhost_in.yon, /tmp/yon_selfhost_out.mlir): the two modules
#     that drive it share the group "selfhost". (Each M1-M5 tool of
#     test_selfhost_emit writes a file of its own, /tmp/yon_m<k>_out.mlir, and
#     only its own test runs it.)
#   * the dune build lock: the modules that run `dune build` share "dune".
# Timing tests (speed "bench") measure wall clock and must not run under load at
# all: gate.sh runs them in a second, serial phase.
# Modules that refuse to run inside an xdist worker (they drive several OS
# processes themselves, e.g. the cross-Space runner): marked `serial`, excluded
# from the parallel phase and run in the serial one — never skipped by it.
_SERIAL_MODULES = {"test_cross_space_runtime"}
# Modules that invoke `dune build` themselves: concurrent dune runs on one
# _build wait on its lock indefinitely (dune 3.20, macOS — reproduced: four at
# once never finish), so they share one worker.
_DUNE_MODULES = {
    "test_surface_fuzz", "test_surface_fuzz_projects", "test_metatheory_fuzz",
    "test_kernel_independent",
}
_SELFHOST_MODULES = {"test_selfhost_fixpoint", "test_selfhost_differential"}
# A source that can touch a machine-global name: a network port, a file it
# writes, the host system. Over-inclusion only costs parallelism.
_MACHINE_SOURCE = re.compile(
    r"\b(Net|make_net|send_net|recv_net|write_text|append_text|System|syslog)\b")
_EXAMPLES = Path(__file__).resolve().parent.parent / "examples"
_machine_cache: dict = {}


def _example_uses_machine(name: str) -> bool:
    if name not in _machine_cache:
        srcs = [_EXAMPLES / f"{name}.yon"] + sorted((_EXAMPLES / name).rglob("*.yon"))
        _machine_cache[name] = any(_MACHINE_SOURCE.search(p.read_text(errors="replace"))
                                   for p in srcs if p.is_file())
    return _machine_cache[name]


def _param_uses_machine(v) -> bool:
    """A node's parameters name the program it runs: an example name, a path to a
    .yon file or project, or the source text itself (book code windows). Any of
    them that can touch a machine-global name puts the node in the "machine"
    group."""
    if isinstance(v, (tuple, list)):
        return any(_param_uses_machine(x) for x in v)
    if isinstance(v, Path):
        if v.is_dir():
            return any(_MACHINE_SOURCE.search(p.read_text(errors="replace"))
                       for p in v.rglob("*.yon"))
        if v.suffix == ".yon" and v.is_file():
            return bool(_MACHINE_SOURCE.search(v.read_text(errors="replace")))
        return False
    if isinstance(v, str):
        if "\n" not in v and (_EXAMPLES / v).exists():
            return _example_uses_machine(v)
        return "\n" in v and bool(_MACHINE_SOURCE.search(v))
    return False


def _xdist_group(item, mod: str, fn: str):
    if mod in _SELFHOST_MODULES:
        return "selfhost"
    if mod in _DUNE_MODULES:
        return "dune"
    if item.get_closest_marker("machine"):
        return "machine"
    callspec = getattr(item, "callspec", None)
    if callspec and any(_param_uses_machine(v) for v in callspec.params.values()):
        return "machine"
    return None


@pytest.fixture(scope="session")
def stretch(pytestconfig):
    """The --stretch factor (float, default 1.0). A stretchable test multiplies its
    base work count by this; use `max(1, int(BASE * stretch))` so 1.0 stays the fast
    baseline and a large factor makes an exhaustive run."""
    return float(pytestconfig.getoption("--stretch"))


# tryfirst: pytest-xdist reads the xdist_group marks in its own
# collection_modifyitems (it rewrites the node ids per group); the marks must
# exist before that runs, or every node is distributed freely.
@pytest.hookimpl(tryfirst=True)
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
        if mod in _SERIAL_MODULES:
            item.add_marker(pytest.mark.serial)
        group = _xdist_group(item, mod, fn)
        if group:
            item.add_marker(pytest.mark.xdist_group(group))
    # The grouped nodes are serialized chains, the longest paths of a parallel
    # run: schedule them first so the free nodes fill the other workers around
    # them. A stable sort keeps the order deterministic (xdist requires every
    # worker to collect the same sequence) and serial runs unaffected in content.
    items.sort(key=lambda it: 0 if it.get_closest_marker("xdist_group") else 1)
