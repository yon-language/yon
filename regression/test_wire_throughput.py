"""Cross-process shared-memory wire throughput gate (IPC-guarded, like spawn scaling).

Two processes talk over a shared-memory Wire: the producer (sensor.yon) pushes N messages,
the consumer (dash.yon) drains them and prints the per-message nanoseconds. This asserts the
build-invariant DESIGN PROPERTY that the wire actually carries messages at speed (well under a
microsecond-scale ceiling), not a machine-specific number. It skips cleanly where fork + shared
memory are unavailable. The dated wall-clock measurement lives in
regression/book/jp/bench/wire_throughput-*.json and Appendix D.
"""

import os
import subprocess
import time
from multiprocessing import shared_memory
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
BENCH = ROOT / "regression" / "book" / "jp" / "bench" / "wire_throughput"
N = 200000


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
        pytest.skip(f"wire throughput needs IPC/SHM, unavailable here: {exc}")
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
def test_wire_throughput(tmp_path):
    if os.environ.get("PYTEST_XDIST_WORKER"):
        pytest.skip("wire throughput must run outside xdist workers")
    _require_ipc_shm()

    sensor, dash = tmp_path / "sensor", tmp_path / "dash"
    for src, out in ((BENCH / "sensor.yon", sensor), (BENCH / "dash.yon", dash)):
        c = subprocess.run([str(YONC), str(src), "-o", str(out)], capture_output=True, timeout=240)
        assert c.returncode == 0, f"{src.name} compile failed\n{c.stderr.decode(errors='replace')[-800:]}"

    best = None
    for _ in range(3):
        for stale in ("/dev/shm/yon_stream_9", "/tmp/yon_stream_9"):
            try:
                os.unlink(stale)
            except OSError:
                pass
        prod = subprocess.Popen([str(sensor)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.3)
        r = subprocess.run([str(dash)], capture_output=True, timeout=60)
        # the producer can block on backpressure once the consumer has drained its share and
        # exited (the ring fills with no further drain); the consumer-side timing is what we
        # measure, so reap the producer without waiting on it.
        prod.terminate()
        try:
            prod.wait(timeout=5)
        except subprocess.TimeoutExpired:
            prod.kill()
        ns = _ints(r.stdout.decode(errors="replace"))
        assert ns, f"consumer produced no ns/message reading; stderr={r.stderr.decode(errors='replace')[-300:]}"
        best = ns[0] if best is None else min(best, ns[0])

    # real throughput: a message must cross the wire in well under 10 us (the measured value
    # is ~0.8 us on an M1). A floor of 10,000 ns/msg fails hard if the wire serialized or stalled.
    assert 0 < best < 10000, f"wire throughput out of range: {best} ns/message for {N} messages"
