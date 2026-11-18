"""What acts and what is pure: the purity the compiler infers.

Purity is judged inside the Space. A fun acts when it has an effect, waits, or reaches
memory that is not its own; a cell of the activation cannot leave it, so it does not
make a fun act. Read from the frontend's --dump-acting.

Layer/kind: frontend / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not FRONTEND.exists(), reason="frontend not built")

USO = program("test_nullary_purity/module_1.yon")


def _acting(tmp_path):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "p"\n\n[world.W]\nobjects = ["X"]\n'
                                   'spaces  = ["w"]\n\n[runtime]\nbackend = "memory"\n')
    (proj / "w" / "Topos.yon").write_text(program("test_nullary_purity/_acting_1.yon"))
    (proj / "w" / "Opened.yon").write_text(program("test_nullary_purity/_acting_2.yon"))
    (proj / "w" / "Scelta.yon").write_text(program("test_nullary_purity/_acting_3.yon"))
    (proj / "w" / "Uso.yon").write_text(USO)
    (proj / "Entry.yon").write_text(program("test_nullary_purity/_acting_4.yon"))
    r = subprocess.run([str(FRONTEND), str(proj), "--dump-acting"], capture_output=True,
                       text=True, timeout=120, cwd=ROOT)
    assert r.returncode == 0, r.stdout + r.stderr
    return set(r.stdout.split())


@pytest.fixture(scope="module")
def acting(tmp_path_factory):
    return _acting(tmp_path_factory.mktemp("purity"))


@pytest.mark.parametrize("name", ["SystemOs__arg_count", "SystemOs__fnv_heap_region",
                                  "SystemOs__leech_heap_region", "SystemOs__process_id"])
def test_a_value_fixed_for_the_life_of_the_space_is_pure(acting, name):
    assert name not in acting


@pytest.mark.parametrize("name", ["SystemOs__monotonic_ns", "SystemOs__wall_ns"])
def test_a_clock_acts(acting, name):
    assert name in acting


def test_reading_a_word_of_shared_memory_acts(acting):
    assert "FnvHeap__read_word" in acting and "FnvHeap__made" in acting


def test_a_body_that_builds_a_section_is_pure(acting):
    assert "Uso__built" not in acting


def test_a_body_that_matches_and_branches_is_pure(acting):
    assert "Uso__matched" not in acting and "Uso__branches" not in acting


def test_a_loop_on_local_cells_is_pure(acting):
    assert "Uso__loop_on_a_local_cell" not in acting


def test_acting_is_closed_along_the_calls(acting):
    assert {"Uso__prints", "Uso__calls_one_that_prints", "Uso__clock",
            "Uso__calls_the_clock"} <= acting
    assert "Uso__args" not in acting


def test_the_empty_collections_of_the_prelude_are_pure(acting):
    assert not {"HashSet__empty", "HashMap__empty", "XRelMap__empty", "XRelSet__empty",
                "XRelFrame__whole"} & acting
