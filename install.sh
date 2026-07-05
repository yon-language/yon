#!/usr/bin/env bash
# install.sh — build Yon from source and install a minimal, self-contained
# toolchain into a prefix (default ~/.yon), then optionally wire the VS Code /
# Cursor extension. macOS (arm64) and Linux (Debian/Ubuntu, x86-64).
#
# Model: clone -> build the three stages -> copy only the artifacts the tools
# actually need (the 5 frontend .exe, topos-opt, runtime/*.o, the wrappers,
# yon-pkg) into the prefix, mirroring the repo layout so the wrappers resolve
# themselves with no env vars -> delete the clone. The wrappers are thin shells;
# what must survive is the built artifacts they invoke.
#
# Prerequisites are CHECKED and reported with versions, never auto-installed:
# if something is missing the script prints the exact command and stops.
#
# One-liner (rustup style, after this file is pushed to the public repo):
#   curl --proto '=https' --tlsv1.2 -sSf \
#     https://raw.githubusercontent.com/yon-language/yon/main/install.sh | bash
#   # with flags:  ... | bash -s -- --check
#
# Usage:
#   ./install.sh                 # clone (YON_REPO_URL), build, install to ~/.yon
#   ./install.sh --local         # build from THIS checkout, do not clone/prune
#   ./install.sh --check         # doctor only: report prerequisites and exit
#   ./install.sh --prefix DIR    # install elsewhere (default ~/.yon)
#   ./install.sh --repo URL      # clone source (default below)
#   ./install.sh --force         # rebuild even if artifacts already exist
#   ./install.sh --no-editor     # skip the VS Code / Cursor extension
#   ./install.sh --no-profile    # do not edit the shell rc; print the lines
set -uo pipefail
if [ -z "${BASH_VERSION:-}" ]; then
  echo "install.sh needs bash (not sh). Run:  curl -fsSL <url>/install.sh | bash" >&2
  exit 1
fi

usage(){ cat <<'USAGE'
install.sh — build Yon from source and install a minimal toolchain to a prefix.

  curl --proto '=https' --tlsv1.2 -sSf \
    https://raw.githubusercontent.com/yon-language/yon/main/install.sh | bash

  ./install.sh              clone YON_REPO_URL, build, install to ~/.yon
  ./install.sh --local      build from THIS checkout (no clone/prune)
  ./install.sh --check      doctor only: report prerequisites and exit
  --prefix DIR   install location (default ~/.yon)
  --repo URL     source to clone (default https://github.com/yon-language/yon.git)
  --force        rebuild even if artifacts exist
  --no-editor    skip the VS Code / Cursor extension
  --no-profile   do not edit the shell rc; print the lines instead
USAGE
}

# ---- config ---------------------------------------------------------------
REPO_URL="${YON_REPO_URL:-https://github.com/yon-language/yon.git}"
PREFIX="${YON_PREFIX:-$HOME/.yon}"
MODE="clone"; DO_EDITOR=1; DO_PROFILE=1; FORCE=0; CHECK_ONLY=0
FIVE_EXE="yoner_emit_mlir.exe yon_lsp.exe yonfmt.exe yon_lint.exe yon_doc.exe"
RUNTIME_OBJS="yon_rt.o yon_mmap.o leech_orbits.o yon_arena.o yon_curtis_canon.o xleech2_coord.o xleech2_heap.o xleech2_mphf.o vendor/mmgroup/mat24_tables.o vendor/mmgroup/mat24_functions.o vendor/mmgroup/gen_leech.o vendor/mmgroup/gen_leech3.o vendor/mmgroup/gen_leech_type.o vendor/mmgroup/gen_leech_reduce.o vendor/mmgroup/gen_xi_functions.o vendor/mmgroup/mm_group_n.o vendor/mmgroup/mm_index.o"

while [ $# -gt 0 ]; do case "$1" in
  --local) MODE="local"; shift ;;
  --check) CHECK_ONLY=1; shift ;;
  --prefix) PREFIX="$2"; shift 2 ;;
  --repo) REPO_URL="$2"; shift 2 ;;
  --force) FORCE=1; shift ;;
  --no-editor) DO_EDITOR=0; shift ;;
  --no-profile) DO_PROFILE=0; shift ;;
  -h|--help) usage; exit 0 ;;
  *) echo "install.sh: unknown option '$1'" >&2; exit 1 ;;
esac; done

# ---- pretty ---------------------------------------------------------------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=; G=; Y=; R=; N=; fi
say(){ printf '%s\n' "$*"; }
ok(){ printf "  ${G}ok${N}   %-10s %s\n" "$1" "$2"; }
warn(){ printf "  ${Y}warn${N} %-10s %s\n" "$1" "$2"; }
bad(){ printf "  ${R}miss${N} %-10s %s\n" "$1" "$2"; }
die(){ printf "${R}install.sh: %s${N}\n" "$*" >&2; exit 1; }

OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS" in Darwin) PM="brew";; Linux) PM="apt";; *) die "unsupported OS: $OS (Darwin or Linux)";; esac

# ---- LLVM 18 discovery ----------------------------------------------------
llvm18_bindir(){
  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    local p; p="$(brew --prefix llvm@18 2>/dev/null || true)"
    [ -n "$p" ] && [ -x "$p/bin/llc" ] && { echo "$p/bin"; return 0; }
  fi
  [ -x /usr/lib/llvm-18/bin/llc ] && { echo /usr/lib/llvm-18/bin; return 0; }
  command -v llc-18 >/dev/null 2>&1 && { dirname "$(command -v llc-18)"; return 0; }
  return 1
}
LLVM18_BIN="$(llvm18_bindir || true)"

# ---- doctor: check + report versions, never install -----------------------
MISSING=0
check(){ # name  version-cmd...
  local name="$1"; shift
  if "$@" >/tmp/.yonv 2>/dev/null; then ok "$name" "$(head -1 /tmp/.yonv)"; else bad "$name" "not found"; MISSING=1; fi
}
say "${B}Yon installer${N}  ($OS/$ARCH, prefix $PREFIX)"
say "${B}Prerequisites${N} (checked, not installed):"
check git    git --version
check opam   opam --version
# dune/menhir may live only inside the opam switch
command -v opam >/dev/null 2>&1 && eval "$(opam env 2>/dev/null || true)"
check dune   dune --version
check menhir menhir --version
check cmake  cmake --version
check ninja  ninja --version
check node   node --version
if command -v gcc >/dev/null 2>&1; then ok "cc" "$(gcc --version | head -1)"; elif command -v clang >/dev/null 2>&1; then ok "cc" "$(clang --version | head -1)"; else bad "cc" "no gcc/clang"; MISSING=1; fi
# LLVM 18 is the load-bearing one.
if [ -n "$LLVM18_BIN" ]; then
  ok "llvm@18" "$("$LLVM18_BIN/llc" --version 2>/dev/null | grep -iE 'LLVM version' | head -1) [$LLVM18_BIN]"
else
  bad "llvm@18" "not found (topos-opt, llc, mlir-translate need LLVM/MLIR 18)"; MISSING=1
fi
# Warn if a DIFFERENT llc shadows it on PATH (yonc prefers bare-name; we pin 18).
if command -v llc >/dev/null 2>&1; then
  bare="$(llc --version 2>/dev/null | grep -ioE 'LLVM version [0-9]+' | head -1)"
  case "$bare" in *" 18"*) : ;; "") : ;; *) warn "llc" "PATH llc is '$bare', not 18 — the installer pins the llvm@18 tools via YONC_LLC";; esac
fi

if [ "$MISSING" -eq 1 ]; then
  say ""
  say "${R}Missing prerequisites.${N} Install them, then re-run:"
  if [ "$PM" = "brew" ]; then
    say "  xcode-select --install"
    say "  brew install opam cmake ninja llvm@18 coreutils node git"
    say "  opam init -y && opam install -y dune menhir"
  else
    say "  sudo apt-get install -y llvm-18 mlir-18-tools libmlir-18-dev clang opam cmake ninja-build nodejs npm git build-essential"
    say "  opam init -y && opam install -y dune menhir"
  fi
  exit 1
fi
say "${G}All prerequisites present.${N}"
[ "$CHECK_ONLY" -eq 1 ] && exit 0

# ---- source tree ----------------------------------------------------------
CLONE=""
if [ "$MODE" = "local" ]; then
  SRC="$(cd "$(dirname "$0")" && pwd)"
  [ -d "$SRC/toolchain" ] && [ -d "$SRC/frontend" ] || die "--local: '$SRC' is not a Yon checkout"
  say "${B}Source${N}: local checkout $SRC (will not be modified or removed)"
else
  CLONE="$(mktemp -d -t yon-src.XXXXXX)"; SRC="$CLONE"
  say "${B}Source${N}: cloning $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$SRC" || die "git clone failed"
fi

LLVM18_CMAKE="$(dirname "$LLVM18_BIN")"   # <keg>/lib/cmake/{mlir,llvm} lives under here

# ---- build (skip stages whose outputs already exist, unless --force) ------
built_runtime(){ local o; for o in $RUNTIME_OBJS; do [ -f "$SRC/runtime/$o" ] || return 1; done; }
built_frontend(){ local e; for e in $FIVE_EXE; do [ -f "$SRC/frontend/_build/default/$e" ] || return 1; done; }
built_mlir(){ [ -x "$SRC/mlir/build/topos-opt" ]; }

say "${B}Build${N}:"
if [ "$FORCE" -eq 0 ] && built_runtime; then ok "runtime" "already built"; else
  say "  building C runtime..."; ( cd "$SRC/runtime" && make ) >/tmp/.yon-rt.log 2>&1 || { tail -20 /tmp/.yon-rt.log; die "runtime build failed"; }; ok "runtime" "built"
fi
if [ "$FORCE" -eq 0 ] && built_frontend; then ok "frontend" "already built"; else
  say "  building OCaml frontend..."; ( cd "$SRC/frontend" && eval "$(opam env)" && dune build ) >/tmp/.yon-fe.log 2>&1 || { tail -20 /tmp/.yon-fe.log; die "frontend build failed"; }; ok "frontend" "built"
fi
if [ "$FORCE" -eq 0 ] && built_mlir; then ok "topos-opt" "already built"; else
  say "  building Topos MLIR dialect (LLVM 18, this is the long one)..."
  ( cd "$SRC/mlir" && cmake -G Ninja -B build -DMLIR_DIR="$LLVM18_CMAKE/lib/cmake/mlir" -DLLVM_DIR="$LLVM18_CMAKE/lib/cmake/llvm" && ninja -C build topos-opt ) >/tmp/.yon-mlir.log 2>&1 || { tail -25 /tmp/.yon-mlir.log; die "mlir/topos-opt build failed"; }
  ok "topos-opt" "built"
fi

# ---- install the minimal tree into PREFIX ---------------------------------
say "${B}Install${N} -> $PREFIX"
case "$PREFIX" in ""|/|"$HOME"|"$HOME"/) die "refusing to wipe '$PREFIX' — pick a dedicated --prefix like ~/.yon";; esac
rm -rf "$PREFIX"
mkdir -p "$PREFIX/toolchain" "$PREFIX/pkg" "$PREFIX/frontend/_build/default" "$PREFIX/mlir/build" "$PREFIX/runtime/vendor/mmgroup"
cp "$SRC"/toolchain/yonc "$SRC"/toolchain/yon-lsp "$SRC"/toolchain/yon-fmt "$SRC"/toolchain/yon-lint "$SRC"/toolchain/yon-doc "$PREFIX/toolchain/"
cp "$SRC"/pkg/yon-pkg "$PREFIX/pkg/"
for e in $FIVE_EXE; do cp "$SRC/frontend/_build/default/$e" "$PREFIX/frontend/_build/default/"; done
cp "$SRC/mlir/build/topos-opt" "$PREFIX/mlir/build/"
for o in $RUNTIME_OBJS; do mkdir -p "$PREFIX/runtime/$(dirname "$o")"; cp "$SRC/runtime/$o" "$PREFIX/runtime/$o"; done
chmod +x "$PREFIX"/toolchain/* "$PREFIX"/pkg/* "$PREFIX/mlir/build/topos-opt" 2>/dev/null || true
ok "tree" "$(du -sh "$PREFIX" 2>/dev/null | cut -f1) in $PREFIX"

# ---- shell profile: PATH + pin the LLVM 18 tools --------------------------
PROFILE="$HOME/.bashrc"; case "${SHELL:-}" in *zsh) PROFILE="$HOME/.zshrc";; esac
BLOCK=$(cat <<EOF
# >>> yon >>>
export PATH="$PREFIX/toolchain:$PREFIX/pkg:\$PATH"
export YONC_LLC="$LLVM18_BIN/llc"
export YONC_MLIR_TRANSLATE="$LLVM18_BIN/mlir-translate"
# <<< yon <<<
EOF
)
if [ "$DO_PROFILE" -eq 1 ]; then
  if grep -q '# >>> yon >>>' "$PROFILE" 2>/dev/null; then ok "profile" "$PROFILE already has the yon block (skipped)"; else
    printf '\n%s\n' "$BLOCK" >> "$PROFILE"; ok "profile" "appended PATH + LLVM18 pins to $PROFILE"
  fi
else
  say "  add to your shell profile:"; printf '%s\n' "$BLOCK" | sed 's/^/    /'
fi

# ---- VS Code / Cursor extension -------------------------------------------
if [ "$DO_EDITOR" -eq 1 ]; then
  EXTDIR="$SRC/lsp/editors/vscode"
  if [ -d "$EXTDIR" ]; then
    say "${B}Editor extension${N}:"
    VSIX="$(ls "$EXTDIR"/*.vsix 2>/dev/null | head -1 || true)"
    if [ -z "$VSIX" ]; then
      ( cd "$EXTDIR" && npm install --omit=dev >/dev/null 2>&1 && npx --yes @vscode/vsce package >/dev/null 2>&1 ) && VSIX="$(ls "$EXTDIR"/*.vsix 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$VSIX" ]; then
      for ED in code cursor; do
        command -v "$ED" >/dev/null 2>&1 || continue
        "$ED" --install-extension "$VSIX" >/dev/null 2>&1 && ok "$ED" "installed $(basename "$VSIX")" || warn "$ED" "install-extension failed"
        # GUI editors don't inherit the shell PATH; pin the absolute server path.
        case "$OS" in Darwin) base="$HOME/Library/Application Support";; *) base="$HOME/.config";; esac
        SET="$base/$([ "$ED" = code ] && echo Code || echo Cursor)/User/settings.json"
        if node -e 'let fs=require("fs"),p=process.argv[1],v=process.argv[2];let o;try{o=JSON.parse(fs.readFileSync(p,"utf8")||"{}")}catch(e){process.exit(3)}o["yon.lspPath"]=v;fs.writeFileSync(p,JSON.stringify(o,null,2))' "$SET" "$PREFIX/toolchain/yon-lsp" 2>/dev/null; then
          ok "$ED" "set yon.lspPath"
        else
          warn "$ED" "set \"yon.lspPath\": \"$PREFIX/toolchain/yon-lsp\" in $SET yourself (has comments?)"
        fi
      done
    else warn "editor" "could not build a .vsix; skipping"; fi
  else
    warn "editor" "extension source not found at $EXTDIR; skipping"
  fi
fi

# ---- prune the clone (after the editor step, which reads $SRC) -------------
if [ -n "$CLONE" ]; then rm -rf "$CLONE"; ok "prune" "removed the clone"; fi

# ---- smoke test -----------------------------------------------------------
say "${B}Smoke test${N}:"
TMP="$(mktemp -d)"; printf 'fun main(): number {\n  be _ holds String.print("yon ok")\n  return 42\n}\n' > "$TMP/hello.yon"
YONC_LLC="$LLVM18_BIN/llc" YONC_MLIR_TRANSLATE="$LLVM18_BIN/mlir-translate" "$PREFIX/toolchain/yonc" "$TMP/hello.yon" -o "$TMP/hello" >/tmp/.yon-smoke.log 2>&1 \
  && "$TMP/hello" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 42 ]; then ok "yonc" "compiled + ran hello.yon (exit 42)"; else warn "yonc" "smoke test exit=$rc (see /tmp/.yon-smoke.log)"; fi
"$PREFIX/toolchain/yon-lsp" --check "$TMP/hello.yon" >/dev/null 2>&1 && ok "yon-lsp" "--check works" || warn "yon-lsp" "--check failed"
rm -rf "$TMP"

say ""
say "${G}Done.${N} Restart your shell (or: source $PROFILE), then:  yonc --help"
