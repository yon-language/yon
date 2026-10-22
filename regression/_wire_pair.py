"""Shared driver for the shared-memory Wire tests (test_wire_throughput,
test_wire_concurrent): compile the producer/consumer pair in regression/wire_pair/,
run them as two processes of ONE world instance, and hand back what each did.

The handshake is a FIFO, not a sleep. The producer creates its channel first and
only then writes "ready" to the path it was given; the test makes that path a
FIFO, so the producer's open blocks until the test reads it, and the test starts
the consumer only after it has read "ready": the channel exists by construction.
Every wait has a deadline and a timed-out wait FAILS the test.
"""

import os
import subprocess
import sys
import threading
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
PAIR = Path(__file__).resolve().parent / "wire_pair"
READY_DEADLINE_S = 30
# the runtime's blocking produce/await give up after ~60 s each (YON_SHM_MAX_POLLS)
RUN_DEADLINE_S = 120

_counter = [0]


def require_ipc_shm(fork=True):
    """POSIX shared memory (and, with fork=True, fork) must work. Where they are supported (macOS,
    Linux) a failure here is an environment fault the test must report: it
    FAILS. Elsewhere the test does not apply: skip.
    The wire pair itself never forks: fork=False spares an xdist worker (a
    threaded process, where Python warns about fork) the fork probe."""
    from multiprocessing import shared_memory
    supported = sys.platform.startswith(("darwin", "linux"))
    shm = None
    try:
        shm = shared_memory.SharedMemory(create=True, size=64)
        shm.close()
        shm.unlink()
        shm = None
        if fork:
            pid = os.fork()
            if pid == 0:
                os._exit(0)
            _, status = os.waitpid(pid, 0)
            if status != 0:
                raise OSError(f"fork probe child exited with status {status}")
    except (OSError, PermissionError) as exc:
        if supported:
            pytest.fail(f"IPC/SHM probe failed on {sys.platform}, where it is supported: {exc}")
        pytest.skip(f"needs fork + POSIX shared memory, unavailable on {sys.platform}: {exc}")
    finally:
        if shm is not None:
            shm.close()
            try:
                shm.unlink()
            except FileNotFoundError:
                pass


def world_tag() -> str:
    """A world instance of its own (4 base-36 chars, the width the runtime uses
    in kernel names), distinct per call in this process: the producer and the
    consumer are started apart, so they join one world by sharing YON_WORLD."""
    _counter[0] += 1
    digits, v, out = "0123456789abcdefghijklmnopqrstuvwxyz", os.getpid() * 7 + _counter[0], ""
    for _ in range(4):
        out, v = digits[v % 36] + out, v // 36
    return out


def shm_unlink(world: str, channel: int):
    """Remove channel `channel` of world `world` (runtime name
    "/y<world>s_id_<channel>", see yon_rt_ipc_name). Absent is fine."""
    import ctypes
    libc = ctypes.CDLL(None)
    libc.shm_unlink.argtypes = [ctypes.c_char_p]
    libc.shm_unlink(f"/y{world}s_id_{channel}".encode())


def compile_pair(tmp: Path):
    """Compile producer.yon and consumer.yon; return their binaries."""
    out = []
    for name in ("producer", "consumer"):
        binp = tmp / name
        c = subprocess.run([str(YONC), str(PAIR / f"{name}.yon"), "-o", str(binp)],
                           capture_output=True, timeout=240)
        assert c.returncode == 0, (
            f"{name}.yon compile failed\n{c.stderr.decode(errors='replace')[-800:]}")
        out.append(binp)
    return out


def _read_ready(fifo: Path, producer: subprocess.Popen):
    """Block (with a deadline) until the producer writes its ready signal."""
    got = {}

    def reader():
        with open(fifo, "rb") as f:
            got["data"] = f.read()

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    t.join(READY_DEADLINE_S)
    if t.is_alive():
        # unblock the reader thread (it waits in open() for a writer) and fail
        os.close(os.open(fifo, os.O_WRONLY | os.O_NONBLOCK))
        t.join(5)
        producer.kill()
        producer.wait()
        pytest.fail(f"the producer did not signal readiness within {READY_DEADLINE_S} s "
                    f"(exit {producer.returncode})")
    assert got.get("data") == b"ready", (
        f"the producer's ready signal reads {got.get('data')!r}, expected b'ready' "
        f"(producer exit {producer.poll()})")


def run_pair(producer_bin, consumer_bin, tmp: Path, n: int, channel: int,
             world: str, assert_producer_waits=False):
    """One round: start the producer, wait for its ready signal, run the
    consumer to completion, reap the producer. Returns
    (consumer CompletedProcess, producer exit code, producer stderr).

    assert_producer_waits: when n exceeds the ring (256 slots), the producer
    cannot finish before a consumer drains it, so it must still be running
    when the consumer starts; checked here, before the consumer exists."""
    env = dict(os.environ, YON_WORLD=world)
    fifo = tmp / f"ready_{world}_{channel}"
    if fifo.exists():
        fifo.unlink()
    os.mkfifo(fifo)
    shm_unlink(world, channel)
    # stderr to a file, not a pipe: a pipe nobody reads until the end could
    # fill and stall the producer mid-run
    perr_path = tmp / f"producer_{world}_{channel}.err"
    with open(perr_path, "wb") as perr_f:
        # both run in the test's own directory: whatever a run writes by a
        # relative path stays there, never in the directory pytest started in
        prod = subprocess.Popen([str(producer_bin), str(fifo), str(n), str(channel)],
                                stdout=subprocess.DEVNULL, stderr=perr_f, env=env, cwd=tmp)
    try:
        _read_ready(fifo, prod)
        if assert_producer_waits:
            assert prod.poll() is None, (
                f"the producer exited ({prod.returncode}) before any consumer attached, "
                f"with {n} messages for a 256-slot ring")
        cons = subprocess.run([str(consumer_bin), str(n), str(channel)],
                              capture_output=True, timeout=RUN_DEADLINE_S, env=env, cwd=tmp)
        try:
            prod.wait(timeout=RUN_DEADLINE_S)
        except subprocess.TimeoutExpired:
            pytest.fail(f"the producer did not exit within {RUN_DEADLINE_S} s after "
                        f"the consumer finished (consumer exit {cons.returncode})")
        return cons, prod.returncode, perr_path.read_text(errors="replace")
    finally:
        if prod.poll() is None:
            prod.kill()
            prod.wait()
        shm_unlink(world, channel)


# the consumer's exit codes (regression/wire_pair/consumer.yon)
CONSUMER_EXIT = {
    0: "ok", 2: "the channel could not be attached",
    3: "a message out of place (wrong value, wrong order, or an await timed out)",
    4: "the sum of the messages is wrong", 5: "no end-of-stream after the last message",
}
PRODUCER_EXIT = {
    0: "ok", 2: "the channel could not be created", 3: "the ready signal could not be written",
    4: "a produce timed out (the ring was never drained)",
}
