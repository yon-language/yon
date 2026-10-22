"""Two Spaces connect on a wire only if they declare the same type.

The frame of a wire names its type by the type root of the value's place:
the place's name, then the name and the root of each field in declaration
order. A subscription carries the root the consumer awaits; the producer
compares it with its own and refuses before the first frame when they
differ, and the consumer checks every frame against the awaited root. A
consumer compiled against another version of the place gets a declared
error at the connection, never values of the other shape.

The scenario is regression/cross_space meteo: the Meteo Space produces three
Reading { temp, humidity } and the consumer sums the temperatures (36).
Read with the fields swapped, the old wire summed the humidities: 153.
"""
from pathlib import Path
import os
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
SCEN = ROOT / "regression" / "cross_space"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _connect(tmp_path: Path, consumer_reading: str | None):
    for p in ("meteo_svc", "meteo_sub"):
        shutil.copytree(SCEN / p, tmp_path / p)
    if consumer_reading is not None:
        (tmp_path / "meteo_sub" / "w" / "Reading.yon").write_text(consumer_reading)
    for src, exe in (("meteo_svc", "Meteo_srv"), ("meteo_sub", "sub")):
        c = subprocess.run([str(YONC), src, "-o", exe], cwd=str(tmp_path),
                           capture_output=True, text=True, timeout=180)
        assert c.returncode == 0, c.stdout + c.stderr
    env = dict(os.environ, YON_WORLD="r%03x" % (hash(str(tmp_path)) % 4096))
    r = subprocess.run(["./sub"], cwd=str(tmp_path), capture_output=True, text=True,
                       timeout=60, env=env)
    return r.returncode, r.stderr


def test_the_same_version_connects_as_before(tmp_path):
    rc, err = _connect(tmp_path, None)
    assert rc == 36, err


@pytest.mark.parametrize("reading", [
    "place Reading {\n  humidity Number\n  temp Number\n}\n",       # fields swapped
    "place Reading {\n  temp Number\n  moisture Number\n}\n",       # a field renamed
    "place Reading {\n  temp Number\n  humidity Int64\n}\n",        # Number -> Int64
], ids=["swapped", "renamed", "number-to-int64"])
def test_another_version_is_refused_at_the_connection(tmp_path, reading):
    rc, err = _connect(tmp_path, reading)
    assert rc != 153 and rc != 36, (rc, err)
    assert rc == 3, (rc, err)
    assert "the subscription was refused" in err, err


def test_a_type_the_wire_does_not_carry_is_refused_at_compile_time(tmp_path):
    # Number -> Boolean: a Boolean field has no frame, so the consumer that
    # declares it does not build; nothing reaches the connection
    for p in ("meteo_svc", "meteo_sub"):
        shutil.copytree(SCEN / p, tmp_path / p)
    (tmp_path / "meteo_sub" / "w" / "Reading.yon").write_text(
        "place Reading {\n  temp Number\n  humidity Boolean\n}\n")
    c = subprocess.run([str(YONC), "meteo_sub", "-o", "sub"], cwd=str(tmp_path),
                       capture_output=True, text=True, timeout=180)
    out = c.stdout + c.stderr
    assert c.returncode != 0 and "a wire does not carry a Reading" in out, out
