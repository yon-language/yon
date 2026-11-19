"""The round trip of the shared-memory wire between two processes.

The pong (regression/wire_pingpong/pong.yon) creates two channels and answers every value v that
comes in on the first with v + 1 on the second; the ping (ping.yon) sends 0 .. n-1, checks every
answer and prints the nanoseconds of each round trip. The test asserts what holds on every machine:
every answer comes back, right and in order, and each round trip is a positive time. The numbers
themselves (the p50, the p99, the throughput) are measured by tools/bench/wire_pingpong.py, on a
quiet machine, and kept with the machine they were measured on.
"""
import os
import subprocess
import threading
from pathlib import Path

import pytest

import _wire_pair as wp

ROOT = Path(__file__).resolve().parent.parent
PINGPONG = ROOT / "regression" / "wire_pingpong"
N = 2000
PING_EXIT = {0: "ok", 2: "a channel could not be attached", 3: "an answer out of place"}
PONG_EXIT = {0: "ok", 2: "a channel could not be created", 3: "the ready signal could not be written",
             4: "an await or a produce timed out"}


def _compile(tmp: Path, name: str) -> Path:
    exe = tmp / name
    c = subprocess.run([str(wp.YONC), str(PINGPONG / f"{name}.yon"), "-o", str(exe)], capture_output=True,
                       text=True, timeout=240)
    assert c.returncode == 0, f"{name}.yon does not compile:\n{c.stdout[-800:]}{c.stderr[-800:]}"
    return exe


@pytest.mark.skipif(not wp.YONC.exists(), reason="toolchain/yonc not present")
def test_every_answer_comes_back_in_order(tmp_path):
    wp.require_ipc_shm(fork=False)
    ping, pong = _compile(tmp_path, "ping"), _compile(tmp_path, "pong")
    world = wp.world_tag()
    env = dict(os.environ, YON_WORLD=world)
    fifo = tmp_path / "ready"
    os.mkfifo(fifo)
    for ch in (21, 22):
        wp.shm_unlink(world, ch)
    p = subprocess.Popen([str(pong), str(fifo), str(N), "21", "22"], stdout=subprocess.DEVNULL,
                         stderr=subprocess.PIPE, env=env, cwd=tmp_path)
    try:
        got = {}
        t = threading.Thread(target=lambda: got.setdefault("d", open(fifo, "rb").read()), daemon=True)
        t.start()
        t.join(wp.READY_DEADLINE_S)
        assert got.get("d") == b"ready", f"the pong did not signal readiness (exit {p.poll()})"
        r = subprocess.run([str(ping), str(N), "21", "22"], capture_output=True, text=True,
                           timeout=wp.RUN_DEADLINE_S, env=env, cwd=tmp_path)
        p.wait(timeout=wp.RUN_DEADLINE_S)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
        for ch in (21, 22):
            wp.shm_unlink(world, ch)
    assert r.returncode == 0, f"ping exit {r.returncode}: {PING_EXIT.get(r.returncode)}\n{r.stderr[-500:]}"
    assert p.returncode == 0, f"pong exit {p.returncode}: {PONG_EXIT.get(p.returncode)}"
    rtt = [int(x) for x in r.stdout.split()]
    assert len(rtt) == N and all(x > 0 for x in rtt), r.stdout[-300:]
