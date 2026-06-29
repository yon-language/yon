"""Spawn-N parallel scaling gate (IPC-guarded, like the cross-space runtime test).

`spawn in N parallel { ... }` forks N isolated process replicas over a shared-memory
collection. This test does NOT assert wall-clock numbers (machine-dependent); it asserts
the build-invariant DESIGN PROPERTY that the construct delivers real parallelism: N
replicas each doing a fixed task complete in far less than N times the serial time. It
skips cleanly where fork + shared memory are unavailable (so it never breaks a sandboxed
or restricted CI). The dated wall-clock measurement lives in
regression/book/jp/bench/spawn_scaling-*.json and Appendix D.
"""

import os
import subprocess
from multiprocessing import shared_memory
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
PROJ = ROOT / "regression" / "book" / "jp" / "bench" / "spawn_scaling"


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
        pytest.skip(f"spawn scaling needs IPC/SHM, unavailable here: {exc}")
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

    binp = tmp_path / "spawn_scaling"
    comp = subprocess.run([str(YONC), str(PROJ), "-o", str(binp)],
                          capture_output=True, timeout=240)
    assert comp.returncode == 0, f"compile failed\n{comp.stderr.decode(errors='replace')[-800:]}"

    # min over a few runs to dampen scheduler noise; the property has a 4x margin.
    best = None
    for _ in range(3):
        r = subprocess.run([str(binp)], capture_output=True, timeout=120)
        w = _ints(r.stdout.decode(errors="replace"))
        assert len(w) == 5, f"expected 5 wall-times (N=1,2,4,8,16), got {w}"
        best = w if best is None else [min(a, b) for a, b in zip(best, w)]

    wall_1, wall_8 = best[0], best[3]
    # real parallelism: 8 replicas (8x the work) must finish in far less than 8x the
    # serial time. A 4x ceiling is generous (true ratio is ~1.1x on an 8-core machine)
    # yet still fails hard if spawn silently serialized.
    assert wall_8 < wall_1 * 4, (
        f"spawn did not parallelize: wall(N=8)={wall_8} ms vs wall(N=1)={wall_1} ms "
        f"(8x work should not cost ~8x time). full={best}"
    )
    # sanity: all positive, and oversubscription (N=16) is the slowest point.
    assert min(best) > 0, f"a wall-time is non-positive: {best}"
    assert best[4] >= best[3], f"N=16 not >= N=8 (oversubscription should not be faster): {best}"
