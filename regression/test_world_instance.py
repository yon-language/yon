"""The world instance scopes every name a world publishes in the kernel.

Two runs of the same program at once are two instances of its world: each
launches its own server for the Space `Who`, and each must talk only to its
own. The server answers with a value of ITS instance (read from the
environment it inherited), the client checks every one of 400 answers against
its own value. If the names were global (no instance), the second client
would find the first one's mailbox and get the first one's answers, or the
two would deadlock on one mailbox.
"""
import os
import signal
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_SERVER = """\
place Entry {
  fun instance(x: Number): Number { return String.length(Env.get("YON_PROBE_INSTANCE")) + x * 0 }
  fun main(): Number { return 0 }
}
"""

_CLIENT = """\
import who::instance from Who

place Entry {
  fun main(): Number {
    be k holds String.length(Env.get("YON_PROBE_INSTANCE"))
    be good holds 0
    be i holds 0
    while i < 400 do {
      good = good + (if instance(i) == k then 1 else 0)
      i = i + 1
    }
    return if good == 400 then k else 99
  }
}
"""


def _build(tmp: Path):
    (tmp / "who.yon").write_text(_SERVER)
    (tmp / "client.yon").write_text(_CLIENT)
    for src, out in (("who.yon", "Who_srv"), ("client.yon", "client")):
        r = subprocess.run([str(YONC), src, "-o", out], cwd=tmp, capture_output=True,
                           text=True, timeout=240)
        assert r.returncode == 0, r.stdout + r.stderr


def _run(tmp: Path, values: list, worlds: list | None = None) -> list:
    """Start one client per value, all at once. Without `worlds` each run
    starts its own world; with them, each joins the world named there."""
    procs = []
    for i, value in enumerate(values):
        env = dict(os.environ, YON_PROBE_INSTANCE=value)
        env.pop("YON_WORLD", None)
        if worlds:
            env["YON_WORLD"] = worlds[i]
        # own process group: a failed run must not leave its server behind
        procs.append(subprocess.Popen(["./client"], cwd=tmp, env=env, start_new_session=True,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    try:
        return [p.wait(timeout=60) for p in procs]
    finally:
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()


def test_two_instances_of_one_program_in_parallel(tmp_path):
    _build(tmp_path)
    assert _run(tmp_path, ["abc", "abcdefg"]) == [3, 7]   # instances 3 and 7


def test_one_instance_is_shared_by_the_spaces_it_launches(tmp_path):
    """The server is forked and exec'd by the client: it answers the client's
    value because it inherited the client's world (else no answer: 247)."""
    _build(tmp_path)
    assert _run(tmp_path, ["abcde"]) == [5]


def test_named_worlds_are_distinct(tmp_path):
    """A world joined by name (YON_WORLD set by whoever starts the processes):
    names longer than the tag width are hashed into it, and stay apart."""
    _build(tmp_path)
    assert _run(tmp_path, ["abc", "abcdefg"],
                worlds=["staging-eu-west", "staging-eu-east"]) == [3, 7]

