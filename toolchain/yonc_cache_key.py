#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com>
"""The key of a compilation, for the content cache of yonc (YONC_CACHE_DIR).

A compilation is decided by its sources, the prelude, the binaries of the
toolchain, the objects of the runtime, the yonc script and its flags; the key
is the SHA-256 of all of them, by content. Two compilations with the same key
produce the same verdict, so the second one is answered from the cache.

The content hash of a large binary (the frontend, topos-opt, llc, ...) is
remembered by (path, size, mtime, inode) in the cache directory, so it is
read once per build of that binary, not once per compilation.

usage:
  yonc_cache_key.py key CACHE_DIR INPUT EMIT RUNTIME_DIR "RUNTIME_OBJS" TOOL... -- FLAG...
      prints the key and the digest of the toolchain alone (binaries, runtime,
      prelude, the yonc script): an entry of another toolchain never hits again
  yonc_cache_key.py wrap|unwrap INPUT   stderr with the input path as a
      placeholder, and back (a message names the file it is about)
  yonc_cache_key.py commit STAGE ENTRY  store a finished entry (a concurrent
      compile may have stored the same key first: then it is dropped)
  yonc_cache_key.py prune CACHE_DIR DIGEST  drop the entries of other toolchains
"""
import shutil
import hashlib
import json
import os
import sys
from pathlib import Path

VERSION = b"yonc-cache-1"
# what the frontend reads from the environment besides its input
ENV_KEYS = ["YON_PRELUDE", "YON_CORE_WF", "YON_DUMP_CORE"]


def file_hash(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Memo:
    """Content hashes of large files, remembered by their stat."""

    def __init__(self, cache_dir: Path):
        self.path = cache_dir / "binaries.json"
        try:
            self.table = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.table = {}
        self.dirty = False

    def hash(self, p: Path) -> str:
        st = p.stat()
        sig = f"{p.resolve()}|{st.st_size}|{st.st_mtime_ns}|{st.st_ino}"
        h = self.table.get(sig)
        if h is None:
            h = file_hash(p)
            self.table[sig] = h
            self.dirty = True
        return h

    def save(self):
        if not self.dirty:
            return
        tmp = self.path.with_name(f"{self.path.name}.{os.getpid()}")
        tmp.write_text(json.dumps(self.table))
        os.replace(tmp, self.path)


def sources(inp: Path):
    """The files a compilation of `inp` reads besides the prelude."""
    if inp.is_dir():
        return sorted(p for p in inp.rglob("*")
                      if p.is_file() and p.suffix in (".yon", ".toml"))
    if inp.suffix == ".mlir":
        return [inp]
    # a single file reads the modules of its directory (sibling <module>.yon
    # and yon_modules/) for the signatures of its imports
    d = inp.parent
    out = {inp}
    out.update(p for p in d.glob("*.yon") if p.is_file())
    out.update(p for p in d.glob("*.toml") if p.is_file())
    mods = d / "yon_modules"
    if mods.is_dir():
        out.update(p for p in mods.rglob("*") if p.is_file() and p.suffix in (".yon", ".toml"))
    return sorted(out)


def which(tool: str):
    if os.sep in tool:
        return Path(tool)
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = Path(d) / tool
        if p.is_file() and os.access(p, os.X_OK):
            return p
    return None


def key(argv):
    cache_dir, inp, emit, rt_dir, rt_objs = (Path(argv[0]), Path(argv[1]), argv[2],
                                             Path(argv[3]), argv[4].split())
    rest = argv[5:]
    cut = rest.index("--")
    tools, flags = rest[:cut], rest[cut + 1:]
    memo = Memo(cache_dir)
    tool = hashlib.sha256(VERSION)
    h = hashlib.sha256(VERSION)

    def part(hh, label: str, value: str):
        hh.update(label.encode() + b"\0" + value.encode() + b"\0")

    for k in ENV_KEYS:
        part(tool, "env:" + k, os.environ.get(k, "\x01unset"))
    for t in tools:
        p = which(t)
        part(tool, "tool", memo.hash(p) if p and p.exists() else "missing:" + t)
    for o in rt_objs:
        p = rt_dir / o
        part(tool, "runtime:" + o, memo.hash(p) if p.exists() else "missing")
    # the prelude: $YON_PRELUDE, else the one beside the frontend (tools[0])
    pre = os.environ.get("YON_PRELUDE")
    fe = which(tools[0])
    pre_dir = Path(pre) if pre else (fe.resolve().parent / "../../../prelude" if fe else None)
    if pre_dir and pre_dir.is_dir():
        for p in sorted(q for q in pre_dir.rglob("*") if q.is_file()):
            part(tool, "prelude:" + str(p.relative_to(pre_dir)), file_hash(p))
    digest = tool.hexdigest()
    part(h, "toolchain", digest)
    part(h, "emit", emit)
    for f in flags:
        part(h, "flag", f)
    base = inp if inp.is_dir() else inp.parent
    # which file is compiled: two files of one directory read the same files
    part(h, "input", "." if inp.is_dir() else inp.name)
    for p in sources(inp):
        part(h, "source:" + str(p.relative_to(base)), file_hash(p))
    memo.save()
    print(h.hexdigest(), digest)


PLACEHOLDER = "\x00yonc-input\x00"


def main(argv):
    cmd = argv[1]
    if cmd == "key":
        key(argv[2:])
    elif cmd in ("wrap", "unwrap"):
        inp = os.path.abspath(argv[2])
        text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
        text = text.replace(inp, PLACEHOLDER) if cmd == "wrap" else text.replace(PLACEHOLDER, inp)
        sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))
    elif cmd == "commit":
        try:
            os.rename(argv[2], argv[3])
        except OSError:
            shutil.rmtree(argv[2], ignore_errors=True)
    elif cmd == "prune":
        root, digest = Path(argv[2]), argv[3]
        for e in root.iterdir() if root.is_dir() else []:
            if not e.is_dir():
                continue
            t = e / "toolchain"
            stale = e.name.startswith(".part.") or not t.exists() or t.read_text().strip() != digest
            if stale:
                shutil.rmtree(e, ignore_errors=True)


if __name__ == "__main__":
    main(sys.argv)
