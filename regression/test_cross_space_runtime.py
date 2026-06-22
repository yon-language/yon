"""Serial runtime gate for the cross-Space wire scenarios."""

import os
import subprocess
from multiprocessing import shared_memory
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
RUNNER = ROOT / "regression" / "cross_space" / "run.sh"


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
        pytest.skip(
            f"cross-space runtime needs IPC/SHM, unavailable in this sandbox: {exc}"
        )
    finally:
        if shm is not None:
            shm.close()
            try:
                shm.unlink()
            except FileNotFoundError:
                pass


def test_cross_space_wire_runtime():
    if os.environ.get("PYTEST_XDIST_WORKER"):
        pytest.skip("cross-space runtime gate must run outside xdist workers")
    if not YONC.exists():
        pytest.skip(f"toolchain not built: {YONC}")
    if not RUNNER.exists():
        pytest.skip(f"cross-space runner missing: {RUNNER}")

    _require_ipc_shm()

    result = subprocess.run(
        ["bash", "regression/cross_space/run.sh"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=240,
    )
    assert result.returncode == 0, (
        "cross-space runtime gate failed\n"
        f"stdout:\n{result.stdout[-4000:]}\n"
        f"stderr:\n{result.stderr[-4000:]}"
    )
