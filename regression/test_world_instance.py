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
import time
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
    k := String.length(Env.get("YON_PROBE_INSTANCE"))
    mut good := 0
    mut i := 0
    while i < 400 do {
      good <- good + (if instance(i) == k then 1 else 0)
      i <- i + 1
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
    # Each client is waited for without being reaped, and its group (the
    # server it may have left) is killed before it is: once a leader is reaped
    # its pid, and so its group id, can be handed to a process of another test,
    # and a SIGKILL to that group would kill a stranger.
    try:
        for p in procs:
            _exited_unreaped(p, 60)
    finally:
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass   # nothing alive in the group (macOS: EPERM for a lone zombie)
    return [p.wait() for p in procs]


def _exited_unreaped(p, timeout):
    """Wait for p to exit, leaving it a zombie (its pid stays its own)."""
    deadline = time.monotonic() + timeout
    while os.waitid(os.P_PID, p.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG) is None:
        if time.monotonic() > deadline:
            raise subprocess.TimeoutExpired(p.args, timeout)
        time.sleep(0.01)


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


# ── The world is a region of names: it is released in one piece ──────────────
# Every process that creates a kernel object appends its name to the world's
# registry ($TMPDIR/yon-world-<tag>); the world's reaper waits for the launcher
# (the process that chose the instance) to end, normally or killed, and removes
# every recorded name and the registry. Each test points TMPDIR
# at a directory of its own, so the registry it watches is the one its program
# writes.

_HOLDER = """\
place Entry {
  fun main(): Number {
    a := Wire.make_shm(5, 1)
    b := Wire.make_shm(6, 1)
    mut v := Wire.await_shm(6)
    return if v == 7 then 0 else 1
  }
}
"""

_SENDER = """\
place Entry {
  fun main(): Number {
    c := Wire.make_shm(6, 0)
    s := Wire.produce_shm(6, 7)
    e := Wire.close_shm(6)
    return 0
  }
}
"""


def _project(tmp: Path, name: str, entry: str) -> Path:
    d = tmp / name
    d.mkdir()
    (d / "yon.toml").write_text(f'[package]\nname = "{name}"\n[runtime]\nbackend = "memory"\n')
    (d / "Entry.yon").write_text(entry)
    out = tmp / f"{name}.bin"
    r = subprocess.run([str(YONC), str(d), "-o", str(out)], capture_output=True, text=True,
                       timeout=240)
    assert r.returncode == 0, r.stdout + r.stderr
    return out


def _shm_exists(name: str) -> bool:
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    libc.shm_open.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
    fd = libc.shm_open(name.encode(), os.O_RDONLY, 0)
    if fd >= 0:
        os.close(fd)
    return fd >= 0


def _until(pred, seconds: float, what: str):
    deadline = time.monotonic() + seconds
    while not pred():
        assert time.monotonic() < deadline, f"timed out waiting for {what}"
        time.sleep(0.02)


def _start_holder(tmp: Path):
    """Start the holder as a world launcher with a private TMPDIR; return the
    process, its registry path, and the kernel names it recorded."""
    exe = _project(tmp, "holder", _HOLDER)
    run_dir = tmp / "run"
    run_dir.mkdir()
    env = dict(os.environ, TMPDIR=str(run_dir))
    env.pop("YON_WORLD", None)
    env.pop("YON_WORLD_LAUNCHER", None)
    p = subprocess.Popen([str(exe)], env=env, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    regs = lambda: sorted(run_dir.glob("yon-world-*"))
    # both channels recorded: the holder has created them and is waiting
    _until(lambda: regs() and len(regs()[0].read_text().split()) == 2, 30,
           "the holder's two channels in its registry")
    reg = regs()[0]
    names = reg.read_text().split()
    assert all(_shm_exists(n) for n in names), names
    return p, reg, names, env


def test_launcher_exit_releases_every_name(tmp_path):
    """A normal end: a second process joins the holder's world by its tag,
    sends the value the holder waits for, and the holder exits 0. The registry
    and every name in it are gone."""
    sender = _project(tmp_path, "sender", _SENDER)
    p, reg, names, env = _start_holder(tmp_path)
    tag = reg.name[len("yon-world-"):]
    try:
        joined = dict(env, YON_WORLD=tag)
        joined.pop("YON_WORLD_LAUNCHER", None)       # a guest, not a launcher
        s = subprocess.run([str(sender)], env=joined, capture_output=True, timeout=60)
        assert s.returncode == 0, s.stderr
        assert p.wait(timeout=60) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
    _until(lambda: not reg.exists(), 10, "the reaper to sweep the registry")
    assert not [n for n in names if _shm_exists(n)]


def test_killed_launcher_releases_every_name(tmp_path):
    """SIGKILL gives the launcher no chance to clean up: its reaper does."""
    p, reg, names, _ = _start_holder(tmp_path)
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    _until(lambda: not reg.exists(), 10, "the reaper to sweep the registry")
    assert not [n for n in names if _shm_exists(n)]


_PRODUCER = """\
place Entry {
  fun main(): Number {
    c := Wire.make_shm(7, 1)
    a := Wire.produce_shm(7, 10)
    b := Wire.produce_shm(7, 32)
    e := Wire.close_shm(7)
    return 0
  }
}
"""

_CONSUMER = """\
place Entry {
  fun main(): Number {
    c := Wire.make_shm(7, 0)
    mut total := 0
    mut v := Wire.await_shm(7)
    while v != 4294967295 do {
      total <- total + v
      v <- Wire.await_shm(7)
    }
    return total
  }
}
"""


def test_consumer_removes_a_finished_stream(tmp_path):
    """In a world named from outside nobody is the launcher; the stream's
    consumer, at the end of the stream, removes its name."""
    prod = _project(tmp_path, "producer", _PRODUCER)
    cons = _project(tmp_path, "consumer", _CONSUMER)
    env = dict(os.environ, YON_WORLD=_tag_for(tmp_path))
    env.pop("YON_WORLD_LAUNCHER", None)
    name = f"/y{env['YON_WORLD']}s_id_7"
    try:
        assert subprocess.run([str(prod)], env=env, timeout=60).returncode == 0
        assert _shm_exists(name)                    # the stream waits for its reader
        assert subprocess.run([str(cons)], env=env, timeout=60).returncode == 42
        assert not _shm_exists(name)
    finally:
        _shm_unlink(name)


def test_each_run_is_a_fresh_instance(tmp_path):
    """The instance is random per run: two runs of one program never share a
    registry, even when the second starts after the first was killed."""
    tags = []
    for i in range(2):
        sub = tmp_path / f"r{i}"
        sub.mkdir()
        p, reg, _, _ = _start_holder(sub)
        tags.append(reg.name)
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        _until(lambda: not reg.exists(), 10, "the reaper")
    assert tags[0] != tags[1]


def _tag_for(tmp: Path) -> str:
    import hashlib
    v = int(hashlib.sha1(str(tmp).encode()).hexdigest(), 16)
    digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    for _ in range(4):
        out, v = digits[v % 36] + out, v // 36
    return out


def _shm_unlink(name: str):
    import ctypes
    libc = ctypes.CDLL(None)
    libc.shm_unlink.argtypes = [ctypes.c_char_p]
    libc.shm_unlink(name.encode())
