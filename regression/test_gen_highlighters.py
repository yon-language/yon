"""The generator of the highlighters stops instead of guessing (tools/gen_highlighters.py).

It stops if a live word or spelling of the lexer has no category, if a category names a word the
lexer does not give or that no live form reads, if a word of the lexer has no description in
22-keywords.md, or if a description names a word the lexer does not have. Each case is provoked
on a copy of the source it reads.
"""
import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
GEN = ROOT / "tools" / "gen_highlighters.py"


@pytest.fixture
def gen():
    spec = importlib.util.spec_from_file_location("gen_highlighters", GEN)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["gen_highlighters"] = mod
    spec.loader.exec_module(mod)
    return mod


def _stops(gen, words):
    with pytest.raises(gen.Stop) as e:
        gen.generate()
    for w in words:
        assert w in str(e.value), e.value


def test_the_sources_generate(gen):
    out = gen.generate()
    assert set(out) == {gen.PRISM, gen.VSCODE, gen.SYNREF}


def test_a_live_word_without_category_stops_it(gen, tmp_path):
    cats = tmp_path / "cats.txt"
    cats.write_text(gen.CATEGORIES.read_text().replace("word\tback\thott\n", ""))
    gen.CATEGORIES = cats
    _stops(gen, ["no category", "back"])


def test_a_category_for_a_word_the_lexer_lacks_stops_it(gen, tmp_path):
    cats = tmp_path / "cats.txt"
    cats.write_text(gen.CATEGORIES.read_text() + "word\tzebra\tcontrol\n")
    gen.CATEGORIES = cats
    _stops(gen, ["zebra"])


def test_a_category_for_a_refused_word_stops_it(gen, tmp_path):
    # `carry`: the lexer gives it, every production of the parser refuses it
    cats = tmp_path / "cats.txt"
    cats.write_text(gen.CATEGORIES.read_text() + "word\tcarry\tword\n")
    gen.CATEGORIES = cats
    _stops(gen, ["carry", "no live form"])


def test_a_word_without_description_stops_it(gen, tmp_path):
    md = tmp_path / "kw.md"
    md.write_text(gen.KEYWORDS_MD.read_text().replace("#### `walk`", "#### walk-gone"))
    gen.KEYWORDS_MD = md
    _stops(gen, ["no description", "walk"])


def test_a_description_of_a_word_the_lexer_lacks_stops_it(gen, tmp_path):
    md = tmp_path / "kw.md"
    md.write_text(gen.KEYWORDS_MD.read_text() + "\n#### `zebra`\n\nNot a word.\n")
    gen.KEYWORDS_MD = md
    _stops(gen, ["zebra"])
