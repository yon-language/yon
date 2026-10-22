"""The language server surfaces the Space-semantic diagnostics, in-process.

The drop check (the diagnostic no other language server can give) lives in the
compiler driver. The LSP is a separate binary that, before this, only parsed and
type-checked a single buffer. These pins prove the LSP -- made project aware --
finds the containing package, runs the WHOLE-PROGRAM drop check with the open
buffer substituted, and reports it under its stable code E3001, without shelling
out to the compiler. And that a well-placed drop raises nothing.
"""
import json
import os
import select
import shutil
import subprocess
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LSP = ROOT / "frontend" / "_build" / "default" / "yon_lsp.exe"
FIXTURE = ROOT / "regression" / "keyword_coverage" / "drop_reclaim"

_ILLEGAL = """\
import svc::d_op from D
place Entry { }
fun main(): Number {
  drop D
  be r := d_op(5)
  return r - r
}
"""

_LEGAL = """\
import svc::d_op from D
place Entry { }
fun main(): Number {
  be r := d_op(5)
  drop D
  return r - r
}
"""


def _check(tmp_path, entry: str) -> tuple[int, str]:
    """Run `yon_lsp --check` on the fixture with `entry` as Entry.yon. Returns
    (exit code, output); --check exits with the number of diagnostics and prints
    "OK: no errors" only when there are none."""
    proj = tmp_path / "proj"
    shutil.copytree(FIXTURE, proj)
    (proj / "Entry.yon").write_text(entry)
    r = subprocess.run([str(LSP), "--check", str(proj / "Entry.yon")],
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr


@pytest.mark.skipif(not LSP.exists() or not FIXTURE.exists(),
                    reason="yon_lsp or fixture missing")
def test_lsp_surfaces_drop_code(tmp_path):
    rc, out = _check(tmp_path, _ILLEGAL)
    assert rc >= 1, out
    assert "E3001" in out, out
    assert "Space D" in out, out


@pytest.mark.skipif(not LSP.exists() or not FIXTURE.exists(),
                    reason="yon_lsp or fixture missing")
def test_lsp_no_false_drop_on_legal(tmp_path):
    rc, out = _check(tmp_path, _LEGAL)
    # The positive signal first: an absence-only assert would also pass on a crash
    # or on empty output.
    assert rc == 0 and "OK: no errors" in out, out
    assert "E3001" not in out, out


def _two_world_project(root: Path) -> Path:
    (root / "A").mkdir(parents=True)
    (root / "B").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "bnd"\n[runtime]\nbackend = "separate"\n'
        '[world.W1]\nobjects = ["X"]\nspaces  = ["A"]\n'
        '[world.W2]\nobjects = ["Y"]\nspaces  = ["B"]\n')
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "B" / "Topos.yon").write_text("topos TB where { }\n")
    (root / "B" / "BP.yon").write_text(
        "fun b_op(x: Number): Number { return x + 1 }\nplace BP { }\n")
    # A (world W1) imports from B (world W2): the wire crosses a world boundary.
    a = root / "A" / "AP.yon"
    a.write_text(
        "import svc::b_op from B\nplace AP { }\n"
        "fun a_op(x: Number): Number { be r := b_op(x)  return r }\n")
    return a


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_surfaces_wire_boundary_code(tmp_path):
    """The other Space-semantic crown jewel: a wire crossing a world boundary is
    surfaced under its stable code E3010, at the import site, in-process."""
    a = _two_world_project(tmp_path / "proj")
    r = subprocess.run([str(LSP), "--check", str(a)],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "E3010" in out and "boundary" in out, out


def _world_project(root: Path):
    """A one-world package: space A (world W) with an UNANNOTATED place, a topos,
    and a root entry. Compiles clean; the place's world is a filesystem fact."""
    (root / "A").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "w"\n[runtime]\nbackend = "separate"\n'
        '[world.W]\nobjects = ["X"]\nspaces  = ["A"]\n')
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "A" / "AP.yon").write_text(
        "place AP { }\nfun a_op(x: Number): Number { return x + 1 }\n")
    # main uses a_op so the package is lint-clean too (no W1001 unused-function):
    # the check below can then demand the full "OK: no errors" verdict.
    (root / "Entry.yon").write_text(
        "place Entry { }\nfun main(): Number { return a_op(0) - 1 }\n")
    return root


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_no_false_cannot_infer_world_on_space_file(tmp_path):
    """A package file type-checked alone must NOT trip "cannot infer world": an
    unannotated place inherits its space's world (a project fact), so the LSP binds
    it from the manifest before type-checking, exactly as the compiler does."""
    root = _world_project(tmp_path / "proj")
    for f in [root / "A" / "AP.yon", root / "Entry.yon"]:
        r = subprocess.run([str(LSP), "--check", str(f)],
                           capture_output=True, text=True, timeout=60)
        out = r.stdout + r.stderr
        assert r.returncode == 0 and "OK: no errors" in out, f"{f}: {out}"
        assert "cannot infer world" not in out, f"{f}: {out}"
        assert "unknown world" not in out, f"{f}: {out}"
        assert "E2001" not in out, f"{f}: {out}"


def _two_boundary_files_same_pos(root: Path) -> Path:
    """A/AP.yon and B/BP.yon each import a DIFFERENT W2 space, both at the same
    line/col. Returns A/AP.yon. Each import crosses the W1->W2 boundary (E3010)."""
    for d in ["A", "B", "OtherX", "OtherY"]:
        (root / d).mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "col"\n[runtime]\nbackend = "separate"\n'
        '[world.W1]\nobjects = ["P"]\nspaces  = ["A", "B"]\n'
        '[world.W2]\nobjects = ["Q"]\nspaces  = ["OtherX", "OtherY"]\n')
    for d, t in [("A", "TA"), ("B", "TB"), ("OtherX", "TX"), ("OtherY", "TY")]:
        (root / d / "Topos.yon").write_text(f"topos {t} where {{ }}\n")
    (root / "OtherX" / "XP.yon").write_text(
        "fun fx(x: Number): Number { return x }\nplace XP { }\n")
    (root / "OtherY" / "YP.yon").write_text(
        "fun fy(x: Number): Number { return x }\nplace YP { }\n")
    a = root / "A" / "AP.yon"
    a.write_text("import svc::fx from OtherX\nplace AP { }\n")
    (root / "B" / "BP.yon").write_text("import svc::fy from OtherY\nplace BP { }\n")
    return a


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_attributes_boundary_by_file_not_position(tmp_path):
    """Per-file attribution is EXACT: two files carry a boundary error at the same
    line/col; opening one shows only ITS error (OtherX), never the sibling's
    (OtherY). A (line, col) heuristic would leak the sibling; the file each location
    carries does not."""
    a = _two_boundary_files_same_pos(tmp_path / "proj")
    r = subprocess.run([str(LSP), "--check", str(a)],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "E3010" in out and "OtherX" in out, out
    assert "OtherY" not in out, f"sibling file's boundary leaked in: {out}"


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_still_reports_genuine_type_error_in_package_file(tmp_path):
    """World-binding must not silence real type errors: an undefined identifier in
    a package file is still reported under E2001."""
    root = _world_project(tmp_path / "proj")
    (root / "A" / "AP.yon").write_text(
        "place AP { }\nfun a_op(x: Number): Number { return zzz + 1 }\n")
    r = subprocess.run([str(LSP), "--check", str(root / "A" / "AP.yon")],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "E2001" in out and "zzz" in out, out


def _cross_file_call_project(root: Path):
    """Two spaces in one world: A/AP.yon calls gee() defined in B/BP.yon."""
    (root / "A").mkdir(parents=True)
    (root / "B").mkdir(parents=True)
    (root / "yon.toml").write_text(
        '[package]\nname = "xf"\n[runtime]\nbackend = "separate"\n'
        '[world.W]\nobjects = ["X", "Y"]\nspaces  = ["A", "B"]\n')
    (root / "A" / "Topos.yon").write_text("topos TA where { }\n")
    (root / "B" / "Topos.yon").write_text("topos TB where { }\n")
    (root / "A" / "AP.yon").write_text(
        "place AP { }\nfun a_op(n: Number): Number { return gee(n) + 1 }\n")
    (root / "B" / "BP.yon").write_text(
        "place BP { }\nfun gee(n: Number): Number { return n * 2 }\n")
    # main uses a_op so the project is lint-clean (no unused-function warnings);
    # these tests are about cross-file type resolution, not lint.
    (root / "Entry.yon").write_text(
        "place Entry { }\nfun main(): Number { return a_op(1) }\n")
    return root


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_resolves_cross_file_reference(tmp_path):
    """A function defined in a sibling file resolves: the LSP type-checks the WHOLE
    package, so A's call to B's `gee` resolves."""
    root = _cross_file_call_project(tmp_path / "proj")
    r = subprocess.run([str(LSP), "--check", str(root / "A" / "AP.yon")],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    assert "OK: no errors" in out, out


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_type_error_attributes_to_owning_file(tmp_path):
    """A genuine type error is reported on the file that OWNS it, and does not leak
    onto a clean sibling that references it -- whole-program check, per-file view."""
    root = _cross_file_call_project(tmp_path / "proj")
    (root / "B" / "BP.yon").write_text(
        "place BP { }\nfun gee(n: Number): Number { return zzz }\n")
    b = subprocess.run([str(LSP), "--check", str(root / "B" / "BP.yon")],
                       capture_output=True, text=True, timeout=60)
    bout = b.stdout + b.stderr
    assert "E2001" in bout and "zzz" in bout, bout
    a = subprocess.run([str(LSP), "--check", str(root / "A" / "AP.yon")],
                       capture_output=True, text=True, timeout=60)
    aout = a.stdout + a.stderr
    assert "zzz" not in aout and "OK: no errors" in aout, aout


# ─── Over the protocol: diagnostics follow the UNSAVED buffer ─────────────────
#
# Every test above drives `--check <file on disk>`. An editor never does: it sends
# the buffer it holds over JSON-RPC, and that buffer differs from the disk exactly
# while the user types. These tests speak the protocol (Content-Length framing on
# stdio) and pin that the published diagnostics describe the BUFFER, in both
# directions: a clean file with a broken buffer reports the error, a broken file
# with a clean buffer reports nothing.


class _LspClient:
    """A minimal LSP client over the server's stdio. Reads are bounded by a
    deadline via select(), never by sleeping."""

    def __init__(self):
        self.proc = subprocess.Popen([str(LSP)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self._buf = b""
        self._next_id = 0

    def send(self, method, params=None, request=False):
        msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if request:
            self._next_id += 1
            msg["id"] = self._next_id
        body = json.dumps(msg).encode()
        self.proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        self.proc.stdin.flush()
        return msg.get("id")

    def _read_message(self, deadline):
        fd = self.proc.stdout.fileno()
        while True:
            head, sep, rest = self._buf.partition(b"\r\n\r\n")
            if sep:
                length = None
                for line in head.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":", 1)[1])
                assert length is not None, f"frame without Content-Length: {head!r}"
                if len(rest) >= length:
                    self._buf = rest[length:]
                    return json.loads(rest[:length])
            remaining = deadline - time.monotonic()
            assert remaining > 0, f"LSP deadline expired; buffered: {self._buf[-400:]!r}"
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                continue  # the loop re-checks the deadline
            chunk = os.read(fd, 65536)
            assert chunk, (f"LSP closed stdout (exit {self.proc.poll()}); "
                           f"stderr: {self.proc.stderr.read()[-400:]!r}")
            self._buf += chunk

    def wait_for(self, pred, timeout=60.0):
        """Read messages until one satisfies `pred`, or fail at the deadline."""
        deadline = time.monotonic() + timeout
        while True:
            m = self._read_message(deadline)
            if pred(m):
                return m

    def diagnostics_for(self, uri, timeout=60.0):
        m = self.wait_for(lambda m: m.get("method") == "textDocument/publishDiagnostics"
                          and m["params"]["uri"] == uri, timeout)
        return m["params"]["diagnostics"]

    def start(self):
        rid = self.send("initialize", {"processId": None, "rootUri": None,
                                       "capabilities": {}}, request=True)
        init = self.wait_for(lambda m: m.get("id") == rid)
        assert init["result"]["capabilities"]["textDocumentSync"] == 1, init
        self.send("initialized")

    def stop(self):
        """Clean shutdown/exit, then assert the server actually exited."""
        rid = self.send("shutdown", request=True)
        resp = self.wait_for(lambda m: m.get("id") == rid)
        assert resp.get("result") is None and "error" not in resp, resp
        self.send("exit")
        self.proc.stdin.close()
        assert self.proc.wait(timeout=30) == 0

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=30)


_AP_CLEAN = "place AP { }\nfun a_op(n: Number): Number { return gee(n) + 1 }\n"
_AP_BROKEN = "place AP { }\nfun a_op(n: Number): Number { return zzz + 1 }\n"


def _uri(p: Path) -> str:
    # path_of_uri does no percent-decoding, so the raw resolved path is the URI.
    return "file://" + str(p.resolve())


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_protocol_diagnoses_unsaved_broken_buffer(tmp_path):
    """Disk clean, buffer broken: the error is published; then a didChange back to
    the clean text clears it. The disk is never touched."""
    root = _cross_file_call_project(tmp_path / "proj")
    ap = root / "A" / "AP.yon"
    assert ap.read_text() == _AP_CLEAN
    uri = _uri(ap)
    c = _LspClient()
    try:
        c.start()
        c.send("textDocument/didOpen", {"textDocument": {
            "uri": uri, "languageId": "yon", "version": 1, "text": _AP_BROKEN}})
        diags = c.diagnostics_for(uri)
        msgs = [d["message"] for d in diags]
        assert any("zzz" in m for m in msgs), diags
        assert any(d.get("code") == "E2001" for d in diags), diags
        # The broken identifier is on line 1 (0-based) of the BUFFER.
        assert all(d["range"]["start"]["line"] == 1 for d in diags
                   if "zzz" in d["message"]), diags

        c.send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 2},
            "contentChanges": [{"text": _AP_CLEAN}]})
        assert c.diagnostics_for(uri) == []
        c.stop()
    finally:
        c.kill()
    assert ap.read_text() == _AP_CLEAN, "the server wrote the buffer to disk"


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_lsp_protocol_clean_buffer_over_broken_disk(tmp_path):
    """The reverse: the file on disk is broken, the buffer is clean. The published
    diagnostics are empty, because they describe the buffer. Control: --check on
    the same disk file DOES report the error, so the empty list is not vacuous."""
    root = _cross_file_call_project(tmp_path / "proj")
    ap = root / "A" / "AP.yon"
    ap.write_text(_AP_BROKEN)
    r = subprocess.run([str(LSP), "--check", str(ap)],
                       capture_output=True, text=True, timeout=60)
    assert r.returncode >= 1 and "zzz" in r.stdout + r.stderr, r.stdout + r.stderr
    uri = _uri(ap)
    c = _LspClient()
    try:
        c.start()
        c.send("textDocument/didOpen", {"textDocument": {
            "uri": uri, "languageId": "yon", "version": 1, "text": _AP_CLEAN}})
        assert c.diagnostics_for(uri) == []
        c.stop()
    finally:
        c.kill()


@pytest.mark.skipif(not LSP.exists() or not FIXTURE.exists(),
                    reason="yon_lsp or fixture missing")
def test_lsp_protocol_whole_program_drop_check_uses_buffer(tmp_path):
    """The whole-program drop check (E3001) runs with the open buffer substituted
    into the package: disk has the LEGAL order, the buffer the ILLEGAL one."""
    proj = tmp_path / "proj"
    shutil.copytree(FIXTURE, proj)
    entry = proj / "Entry.yon"
    entry.write_text(_LEGAL)
    uri = _uri(entry)
    c = _LspClient()
    try:
        c.start()
        c.send("textDocument/didOpen", {"textDocument": {
            "uri": uri, "languageId": "yon", "version": 1, "text": _ILLEGAL}})
        diags = c.diagnostics_for(uri)
        assert any(d.get("code") == "E3001" and "Space D" in d["message"]
                   for d in diags), diags
        c.stop()
    finally:
        c.kill()
