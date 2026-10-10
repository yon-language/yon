"""Spawn-N parallel scaling gate (IPC-guarded, like the cross-space runtime test).

`spawn in N parallel { ... }` forks N isolated process replicas over a shared-memory
collection. This test does NOT assert wall-clock numbers (machine-dependent); it asserts
the build-invariant DESIGN PROPERTY that the construct delivers real parallelism: N
replicas each doing a fixed task complete in far less than N times the serial time,
and that the replicas really did the work: every replica's result reaches the folded
collection exactly once (see regression/spawn_check/Entry.yon, the book program with
each replica seeded by 2^i so the total pins the set of replica indices). Where fork +
shared memory are not supported it skips; on macOS and Linux, where they are, a failing
probe FAILS. The dated wall-clock measurement lives in
regression/book/jp/bench/spawn_scaling-*.json and Appendix D.
"""

import os
import subprocess
import sys
from multiprocessing import shared_memory
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
BOOK_PROJ = ROOT / "regression" / "book" / "jp" / "bench" / "spawn_scaling"
PROJ = ROOT / "regression" / "spawn_check"
NS = (1, 2, 4, 8, 16)
HEAVY = 8_000_000 * 7          # what heavy() adds to its seed


def _expected_total(n):
    """Replica i returns 2^i + HEAVY, so N replicas fold to N*HEAVY + 2^N - 1."""
    return n * HEAVY + 2 ** n - 1


def _require_ipc_shm():
    shm = None
    try:
        shm = shared_memory.SharedMemory(create=True, size=64)
        shm.close()
        shm.unlink()
        shm = None
        pid = os.fork()
        if pid == 0:
            os._exit(0)
        _, status = os.waitpid(pid, 0)
        if status != 0:
            raise OSError(f"fork probe child exited with status {status}")
    except (OSError, PermissionError) as exc:
        # macOS and Linux support fork + POSIX shm: a failure there (e.g. an shm
        # namespace exhausted by earlier runs) is a fault to report, not a skip.
        if sys.platform.startswith(("darwin", "linux")):
            pytest.fail(f"IPC/SHM probe failed on {sys.platform}, where it is supported: {exc}")
        pytest.skip(f"spawn scaling needs IPC/SHM, unavailable on {sys.platform}: {exc}")
    finally:
        if shm is not None:
            shm.close()
            try:
                shm.unlink()
            except FileNotFoundError:
                pass


def _ints(s):
    return [int(t) for t in s.split() if t.lstrip("-").isdigit()]


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
def test_spawn_parallel_scaling(tmp_path):
    if os.environ.get("PYTEST_XDIST_WORKER"):
        pytest.skip("spawn scaling must run outside xdist workers")
    _require_ipc_shm()

    # the book's program must still build as printed (the timed run below uses its
    # checked twin, regression/spawn_check)
    book = subprocess.run([str(YONC), str(BOOK_PROJ), "-o", str(tmp_path / "book")],
                          capture_output=True, timeout=240)
    assert book.returncode == 0, f"book program compile failed\n{book.stderr.decode(errors='replace')[-800:]}"

    binp = tmp_path / "spawn_check"
    comp = subprocess.run([str(YONC), str(PROJ), "-o", str(binp)],
                          capture_output=True, timeout=240)
    assert comp.returncode == 0, f"compile failed\n{comp.stderr.decode(errors='replace')[-800:]}"

    # min over a few runs to dampen scheduler noise; the property has a 4x margin.
    best = None
    for _ in range(3):
        r = subprocess.run([str(binp)], capture_output=True, timeout=120)
        assert r.returncode == 0, f"spawn_check exited {r.returncode}\n{r.stderr.decode(errors='replace')[-500:]}"
        out = _ints(r.stdout.decode(errors="replace"))
        assert len(out) == 2 * len(NS), f"expected (wall_ms, total) for N={NS}, got {out}"
        walls, totals = out[0::2], out[1::2]
        # every replica's result, each exactly once, in every run
        assert totals == [_expected_total(n) for n in NS], (
            f"replica results lost, duplicated or wrong: totals={totals}, expected "
            f"{[_expected_total(n) for n in NS]} for N={NS}")
        best = walls if best is None else [min(a, b) for a, b in zip(best, walls)]

    assert min(best) > 0, f"a wall-time is non-positive: {best}"
    wall_1, wall_8 = best[0], best[3]
    # real parallelism: 8 replicas (8x the work) must finish in far less than 8x the
    # serial time. On P cores the ideal is wall_1 * 8/min(8, P); a 4x margin over it
    # is generous (the ratio is ~1.1x on an 8-core machine) yet fails hard if spawn
    # silently serialized, and does not flake on a machine with fewer cores.
    p = min(8, os.cpu_count() or 1)
    assert wall_8 < wall_1 * (8 / p) * 4, (
        f"spawn did not parallelize: wall(N=8)={wall_8} ms vs wall(N=1)={wall_1} ms "
        f"on {os.cpu_count()} cores (8x work should not cost ~8x time). full={best}"
    )
    # Replaces "wall(16) >= wall(8)", which a 16+-core machine can break (16 replicas
    # run as fast as 8 there). What holds on ANY core count is the other side: 16
    # replicas are twice the work of 8, and twice the work on the same cores costs at
    # most about twice the time (when 8 replicas already fill the cores) and less when
    # there are spare cores. So wall(16) <= 2 * wall(8), with a 2x margin for noise;
    # a collapse under oversubscription (contention, a quadratic collection) breaks it.
    # (No lower bound: the first N=1 run carries one-time start-up cost, so wall(2)
    # is often below wall(1), and the totals above already prove the work was done.)
    wall_16 = best[4]
    assert wall_16 <= wall_8 * 2 * 2, (
        f"oversubscription not ~linear: wall(N=16)={wall_16} ms > 4 x wall(N=8)={wall_8} ms "
        f"(16 replicas are 2x the work of 8). full={best}")
