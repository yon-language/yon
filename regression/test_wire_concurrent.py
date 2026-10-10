"""Concurrent shared-memory Wire correctness: producer and consumer ALIVE AT ONCE.

cross_space/run.sh scenario 3 runs its producer to completion before the consumer
starts (its concurrent-liveness case is deferred), so nothing checked a shared-memory
Wire with both ends running. Here they must be: the ring holds 256 messages and the
producer sends N = 20000, so it cannot finish until a live consumer has drained all
but the last 256; the test also checks the producer is still running when the
consumer starts.

The pair is regression/wire_pair/{producer,consumer}.yon, started apart and joined in
one world instance through YON_WORLD. The producer sends 3k+1 for k = 0..N-1; the
consumer checks every value and its order, the sum, and the end-of-stream after the
last message, and encodes the outcome in its exit code. The readiness handshake is a
FIFO and every wait has a deadline (_wire_pair.py): no sleeps.

Not a timing test: it runs in the parallel phase (its world tag keeps its channel
apart from any other node's).
"""

import pytest

import _wire_pair as wp

pytestmark = [pytest.mark.yon, pytest.mark.integration]

N = 20000
CHANNEL = 11


@pytest.mark.skipif(not wp.YONC.exists(), reason="toolchain/yonc not present")
def test_wire_concurrent_count_and_sum(tmp_path):
    wp.require_ipc_shm(fork=False)
    producer, consumer = wp.compile_pair(tmp_path)
    cons, prod_rc, prod_err = wp.run_pair(producer, consumer, tmp_path, N, CHANNEL,
                                          wp.world_tag(), assert_producer_waits=True)
    assert cons.returncode == 0, (
        f"consumer exit {cons.returncode}: {wp.CONSUMER_EXIT.get(cons.returncode, 'unknown')}\n"
        f"{cons.stderr.decode(errors='replace')[-500:]}")
    assert prod_rc == 0, (
        f"producer exit {prod_rc}: {wp.PRODUCER_EXIT.get(prod_rc, 'unknown')}\n{prod_err[-500:]}")
