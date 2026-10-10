"""Cross-process shared-memory wire throughput gate (IPC-guarded, like spawn scaling).

Two processes talk over a shared-memory Wire: the producer pushes N messages, the
consumer drains them and prints the per-message nanoseconds. This asserts the
build-invariant DESIGN PROPERTY that the wire actually carries messages at speed (well
under a microsecond-scale ceiling), not a machine-specific number, and that what it
carried is right: the consumer checks every one of the N values (3k+1, in order), their
sum, and the end-of-stream after the last, and its exit code says which check failed.

The pair is regression/wire_pair/{producer,consumer}.yon: the book's
bench/wire_throughput/{sensor,dash}.yon loops (which stay as the book prints them) plus
a readiness signal and those checks. The producer signals "channel created" through a
FIFO (see _wire_pair.py), so the consumer never starts before the channel exists: no
sleep, and every wait has a deadline. The dated wall-clock measurement lives in
regression/book/jp/bench/wire_throughput-*.json and Appendix D.
"""

import os

import pytest

import _wire_pair as wp

N = 200000
CHANNEL = 9


def _ints(s):
    return [int(t) for t in s.split() if t.lstrip("-").isdigit()]


@pytest.mark.skipif(not wp.YONC.exists(), reason="toolchain/yonc not present")
def test_wire_throughput(tmp_path):
    if os.environ.get("PYTEST_XDIST_WORKER"):
        pytest.skip("wire throughput must run outside xdist workers")
    wp.require_ipc_shm()
    producer, consumer = wp.compile_pair(tmp_path)

    world = wp.world_tag()
    best = None
    for _ in range(3):
        cons, prod_rc, prod_err = wp.run_pair(producer, consumer, tmp_path, N, CHANNEL, world)
        assert cons.returncode == 0, (
            f"consumer exit {cons.returncode}: "
            f"{wp.CONSUMER_EXIT.get(cons.returncode, 'unknown')}\n"
            f"{cons.stderr.decode(errors='replace')[-500:]}")
        assert prod_rc == 0, (
            f"producer exit {prod_rc}: {wp.PRODUCER_EXIT.get(prod_rc, 'unknown')}\n{prod_err[-500:]}")
        ns = _ints(cons.stdout.decode(errors="replace"))
        assert ns, f"consumer produced no ns/message reading; stderr={cons.stderr.decode(errors='replace')[-300:]}"
        best = ns[0] if best is None else min(best, ns[0])

    # real throughput: a message must cross the wire in well under 10 us. A floor of
    # 10,000 ns/msg fails hard if the wire serialized or stalled.
    assert 0 < best < 10000, f"wire throughput out of range: {best} ns/message for {N} messages"
