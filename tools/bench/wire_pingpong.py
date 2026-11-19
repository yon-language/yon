#!/usr/bin/env python3
"""The measure of the wire between two processes: the round trip of one message, and the throughput.

Two measures, each by the method of the benchmarks (a twin base taken off, the median over many
runs, the machine written beside the numbers):

  ping-pong   regression/wire_pingpong/{ping,pong}.yon: the ping sends i, the pong answers i + 1 on
              a second channel, and the ping prints the nanoseconds of each round trip. The base is
              clock.yon, the same loop with nothing between the two readings of the clock: its median
              is taken off every round trip. One run gives the p50 and the p99 of its round trips (the
              first WARMUP left out); the result is the median of each over the runs.
  throughput  regression/wire_pair/{producer,consumer}.yon (the pair of test_wire_throughput): N
              messages through one channel; the consumer prints the nanoseconds per message. The
              result is the median over the runs, and the messages per second it gives.

  python3 tools/bench/wire_pingpong.py --label before          # writes notes/bench/wire/<label>-...json
  python3 tools/bench/wire_pingpong.py --runs 15 --n 5000 --label after
  python3 tools/bench/wire_pingpong.py --out -                  # the JSON on the standard output

Run on a quiet machine: the numbers are of that machine, at that commit, on that day.
"""
import argparse
import datetime
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent, check=True).stdout.strip())
YONC = ROOT / "toolchain" / "yonc"
PINGPONG = ROOT / "regression" / "wire_pingpong"
PAIR = ROOT / "regression" / "wire_pair"
WARMUP = 100
DEADLINE_S = 300


def compile_yon(src: Path, out: Path):
    c = subprocess.run([str(YONC), str(src), "-o", str(out)], capture_output=True, text=True, timeout=600)
    if c.returncode != 0:
        sys.exit(f"{src.name} does not compile:\n{c.stdout[-800:]}{c.stderr[-800:]}")


def read_ready(fifo: Path, proc: subprocess.Popen):
    got = {}

    def reader():
        with open(fifo, "rb") as f:
            got["data"] = f.read()

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    t.join(30)
    if t.is_alive() or got.get("data") != b"ready":
        proc.kill()
        sys.exit("the server side did not signal readiness")


def world(k: int) -> str:
    digits, v, out = "0123456789abcdefghijklmnopqrstuvwxyz", os.getpid() * 13 + k, ""
    for _ in range(4):
        out, v = digits[v % 36] + out, v // 36
    return out


def pct(xs, q):
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * len(s)))]


def one_pingpong(bins, tmp: Path, n: int, k: int):
    env = dict(os.environ, YON_WORLD=world(k))
    fifo = tmp / f"ready_{k}"
    os.mkfifo(fifo)
    pong = subprocess.Popen([str(bins["pong"]), str(fifo), str(n), "61", "62"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, env=env, cwd=tmp)
    read_ready(fifo, pong)
    ping = subprocess.run([str(bins["ping"]), str(n), "61", "62"], capture_output=True, text=True,
                          env=env, cwd=tmp, timeout=DEADLINE_S)
    pong.wait(timeout=DEADLINE_S)
    if ping.returncode != 0 or pong.returncode != 0:
        sys.exit(f"ping exit {ping.returncode}, pong exit {pong.returncode}: a round trip went wrong")
    rtt = [int(t) for t in ping.stdout.split()]
    if len(rtt) != n:
        sys.exit(f"the ping printed {len(rtt)} round trips of {n}")
    return rtt[WARMUP:]


def one_clock(bins, n: int):
    r = subprocess.run([str(bins["clock"]), str(n)], capture_output=True, text=True, timeout=DEADLINE_S)
    return [int(t) for t in r.stdout.split()][WARMUP:]


def one_throughput(bins, tmp: Path, n: int, k: int):
    env = dict(os.environ, YON_WORLD=world(1000 + k))
    fifo = tmp / f"ready_t{k}"
    os.mkfifo(fifo)
    prod = subprocess.Popen([str(bins["producer"]), str(fifo), str(n), "63"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, env=env, cwd=tmp)
    read_ready(fifo, prod)
    cons = subprocess.run([str(bins["consumer"]), str(n), "63"], capture_output=True, text=True, env=env,
                          cwd=tmp, timeout=DEADLINE_S)
    prod.wait(timeout=DEADLINE_S)
    if cons.returncode != 0 or prod.returncode != 0:
        sys.exit(f"consumer exit {cons.returncode}, producer exit {prod.returncode}")
    return int(cons.stdout.split()[0])


def wait_mechanism(tmp: Path) -> str:
    """the wait the runtime uses on this machine, as its unit test of the wait names it"""
    exe = tmp / "bell"
    rt = ROOT / "runtime"
    src = rt / "test_unit_bell.c"
    if not src.exists():
        return "the sleep of 1 ms (no wait on a word in the wire)"
    sys.path.insert(0, str(ROOT / "regression"))
    from test_runtime_units import RTSET, DISPATCH_STUB   # the objects the runtime's unit tests link
    c = subprocess.run([os.environ.get("YONC_CC", "cc"), "-std=c11", "-O2", f"-I{rt}", f"-I{rt}/vendor/mmgroup",
                        str(src), *RTSET, DISPATCH_STUB, "-lpthread", "-lm", "-o", str(exe)],
                       capture_output=True, text=True)
    if c.returncode != 0:
        return "unknown (the unit test of the wait does not build)"
    r = subprocess.run([str(exe), "--mechanism"], capture_output=True, text=True, timeout=60)
    return r.stdout.strip() or "unknown"


def machine() -> dict:
    m = {"system": platform.system(), "release": platform.release(), "machine": platform.machine(),
         "python": platform.python_version()}
    if sys.platform == "darwin":
        q = lambda *a: subprocess.run(a, capture_output=True, text=True).stdout.strip()
        m.update(cpu=q("sysctl", "-n", "machdep.cpu.brand_string"), model=q("sysctl", "-n", "hw.model"),
                 cores=q("sysctl", "-n", "hw.ncpu"), os=q("sw_vers", "-productVersion"))
    else:
        cpu = ""
        try:
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.startswith("model name"):
                    cpu = line.split(":", 1)[1].strip()
                    break
        except OSError:
            pass
        m.update(cpu=cpu, cores=str(os.cpu_count()), os=platform.version())
    return m


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=15)
    ap.add_argument("--n", type=int, default=5000, help="round trips per run of the ping-pong")
    ap.add_argument("--messages", type=int, default=200000, help="messages per run of the throughput")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default=None, help="the JSON file; '-' for the standard output; "
                    "default notes/bench/wire/<label>-<commit>-<date>.json")
    a = ap.parse_args()
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                            cwd=ROOT).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], capture_output=True,
                                text=True, cwd=ROOT).stdout.strip())
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        bins = {}
        for name, d in [("ping", PINGPONG), ("pong", PINGPONG), ("clock", PINGPONG), ("producer", PAIR),
                        ("consumer", PAIR)]:
            bins[name] = tmp / name
            compile_yon(d / f"{name}.yon", bins[name])
        mech = wait_mechanism(tmp)
        base = statistics.median(one_clock(bins, a.n))
        p50s, p99s, maxs, thr = [], [], [], []
        for k in range(a.runs):
            rtt = [t - base for t in one_pingpong(bins, tmp, a.n, k)]
            p50s.append(pct(rtt, 0.50))
            p99s.append(pct(rtt, 0.99))
            maxs.append(max(rtt))
            thr.append(one_throughput(bins, tmp, a.messages, k))
            print(f"run {k + 1}/{a.runs}: p50 {p50s[-1]:.0f} ns, p99 {p99s[-1]:.0f} ns, "
                  f"throughput {thr[-1]} ns/message", file=sys.stderr)
    ns_msg = statistics.median(thr)
    result = {
        "what": "the wire between two processes: the round trip of one message (ping-pong) and the throughput",
        "commit": commit + ("+working-tree" if dirty else ""),
        "date": datetime.date.today().isoformat(),
        "machine": machine(),
        "wait": mech,
        "method": {"runs": a.runs, "round_trips_per_run": a.n, "warmup_left_out": WARMUP,
                   "clock_base_ns": base, "messages_per_run": a.messages,
                   "statistic": "the median over the runs of each run's percentile"},
        "pingpong": {"p50_ns": statistics.median(p50s), "p99_ns": statistics.median(p99s),
                     "max_ns_median": statistics.median(maxs), "p50_runs": p50s, "p99_runs": p99s},
        "throughput": {"ns_per_message": ns_msg, "messages_per_second": round(1e9 / ns_msg) if ns_msg else None,
                       "runs": thr},
    }
    text = json.dumps(result, indent=2) + "\n"
    if a.out == "-":
        sys.stdout.write(text)
        return
    out = Path(a.out) if a.out else (ROOT / "notes" / "bench" / "wire" /
                                     f"{a.label}-{commit}-{result['date']}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    print(f"p50 {result['pingpong']['p50_ns']:.0f} ns, p99 {result['pingpong']['p99_ns']:.0f} ns, "
          f"throughput {ns_msg} ns/message; written {out}")


if __name__ == "__main__":
    main()
