"""Shared pytest configuration for the Yon test suite.

Registers and AUTO-APPLIES two marker families so the whole suite can be sliced
by layer and by kind without editing individual tests:

    pytest -m c                     # every C-runtime test
    pytest -m unit                  # every unit test, all layers
    pytest -m "yon and integration" # full-program Yon runs
    pytest -m "ocaml or mlir"       # frontend + dialect

Layers:  yon | ocaml | mlir | llvm | c        Kinds: unit | integration

Marks are assigned per test module (and, for the mixed end-to-end module, per
test function), so existing tests need no annotations. New test modules should
either follow the naming map below or carry explicit pytest.mark.<layer> /
pytest.mark.<kind> decorators.
"""

import pytest

LAYERS = {"yon", "ocaml", "mlir", "llvm", "c"}
KINDS = {"unit", "integration"}

# module basename -> (layer, kind)
_MODULE_MARKS = {
    "test_runtime_units": ("c", "unit"),
    "test_yon_selfhost": ("yon", "integration"),
    "test_yon_coverage": ("yon", "unit"),
    "test_projects": ("yon", "integration"),
    "test_site": ("ocaml", "unit"),
    "test_cross_space_runtime": ("yon", "integration"),
}

# test_yon_pipeline mixes layers; mark by test function name.
_PIPELINE_FUNC_MARKS = {
    "test_example": ("yon", "integration"),
    "test_ocaml_oracle": ("ocaml", "unit"),
    "test_runtime_mphf": ("c", "unit"),
}


def pytest_configure(config):
    for m in sorted(LAYERS | KINDS):
        config.addinivalue_line("markers", f"{m}: Yon suite layer/kind tag")


def pytest_collection_modifyitems(config, items):
    for item in items:
        mod = item.module.__name__.split(".")[-1] if item.module else ""
        layer = kind = None
        if mod == "test_yon_pipeline":
            fn = getattr(item, "originalname", None) or item.name.split("[")[0]
            layer, kind = _PIPELINE_FUNC_MARKS.get(fn, ("yon", "integration"))
        elif mod in _MODULE_MARKS:
            layer, kind = _MODULE_MARKS[mod]
        if layer:
            item.add_marker(getattr(pytest.mark, layer))
            item.add_marker(getattr(pytest.mark, kind))
