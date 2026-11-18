"""The Yon programs of the Python tests, read from regression/programs/ (tools/extract_programs.py).

A program that depends on no parameter lives in a file, where every tool that reads Yon sees it; a
test reads it with `program("<test module>/<name>.yon")`.
"""
from pathlib import Path

PROGRAMS = Path(__file__).resolve().parent / "programs"


def program(name: str) -> str:
    return (PROGRAMS / name).read_text()
