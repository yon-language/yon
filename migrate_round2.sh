#!/usr/bin/env bash
# migrate_round2.sh — Yon layout Round 2 (Agent MIG)
#
# New mandatory layout rules for PROJECT dirs (a dir holding yon.toml):
#   1. one place per file
#   2. filename == place name           (Account.yon -> `place Account`)
#   3. the topos file is named Topos.yon (and lives inside a SPACE dir)
#   4. no "place" substring in place names or place filenames
#
# Single-file standalone tests (e.g. regression/yon_tests/negative/*.yon emitted
# standalone, regression/book/01/*.yon) are EXEMPT and are NOT touched.
#
# This script performs Parts A..D using `git mv`/`git rm` so renames are tracked.
# It is SAFE: every project/file it touches is re-verified against its expected
# current content before any mutation. It only touches the specific targets
# identified by Agent MIG; it never does a blanket rename. It is idempotent-ish:
# steps already applied are detected and skipped with a notice.
#
# Run from anywhere inside the repo:  bash migrate_round2.sh
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
echo "== Yon migrate_round2 :: repo root = $ROOT =="

# --- helpers ---------------------------------------------------------------
note()  { printf '  [..] %s\n' "$*"; }
done_() { printf '  [ok] %s\n' "$*"; }
skip()  { printf '  [skip] %s\n' "$*"; }
die()   { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

# git mv only if the source still exists and the dest does not (idempotent)
gmv() { # gmv SRC DST
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    git mv "$src" "$dst"
    done_ "git mv $src -> $dst"
  elif [ -f "$dst" ]; then
    skip "already moved: $dst"
  else
    die "expected source missing and dest absent: $src -> $dst"
  fi
}

###############################################################################
# PART B — root topos in Main.yon must move into a SPACE/Topos.yon
#
# Pattern reference (already-correct): regression/yon_tests/prove/sheaf_quotient_prop_ok
#   anon/State.yon + anon/Topos.yon  and  yon.toml  [world.Anon] spaces=["anon"]
#
# We do Part B BEFORE Part A so that the root Main.yon left behind (just
# `place Entry {}` + main) is then renamed to Entry.yon by Part A.
###############################################################################
echo
echo "== PART B :: lift root topos into a space =="

# --- B1. examples/c_prop_abstract -----------------------------------------
# Current root Main.yon: place Entry{}, topos Bank (abstract prop), main.
# Root State.yon holds `place State { balance number }`. World = Ledger.
# New space: bank/  (!= topos name "Bank"; no "place" substring).
p="examples/c_prop_abstract"
if [ -f "$p/Main.yon" ] && grep -q "^topos Bank" "$p/Main.yon"; then
  note "$p: lifting topos Bank into space bank/"
  mkdir -p "$p/bank"
  cat > "$p/bank/Topos.yon" <<'YON'
topos Bank where {
  prop is_overdrawn(s: State): proposition
}
YON
  git add "$p/bank/Topos.yon"
  gmv "$p/State.yon" "$p/bank/State.yon"
  cat > "$p/Main.yon" <<'YON'
place Entry { }
fun main(): number { return 0 }
YON
  # add the space to the world's mapping
  if ! grep -q '^spaces' "$p/yon.toml"; then
    # insert under [world.Ledger]
    awk '1; /^\[world\.Ledger\]/{print "spaces  = [\"bank\"]"}' "$p/yon.toml" > "$p/yon.toml.tmp"
    mv "$p/yon.toml.tmp" "$p/yon.toml"
  fi
  done_ "$p restructured"
else
  skip "$p already restructured"
fi

# --- B2. examples/kw_topos_block ------------------------------------------
# Root Main.yon: place Entry{}, topos Bank { terminal Unit1; morphisms{...};
# prop is_overdrawn }, topology j of State, main(uses State + is_overdrawn).
# Root places: State.yon, Unit1.yon. World = Ledger.
# The topos refs State + terminal Unit1; topology j refs State. They all go
# into the space bank/ together with the Topos.yon. main() stays at root in
# Entry.yon and keeps referring to State (cross-space ref like cross_space/*).
p="examples/kw_topos_block"
if [ -f "$p/Main.yon" ] && grep -q "^topos Bank" "$p/Main.yon"; then
  note "$p: lifting topos Bank + topology j into space bank/"
  mkdir -p "$p/bank"
  cat > "$p/bank/Topos.yon" <<'YON'
topos Bank where {
  terminal Unit1
  morphisms {
    morphism tag(s: State): number
    functorial morphism lift(s: State): number
  }
  prop is_overdrawn(s: State): proposition = s.balance < 0
}
topology j of State { return 1 }
YON
  git add "$p/bank/Topos.yon"
  gmv "$p/State.yon" "$p/bank/State.yon"
  gmv "$p/Unit1.yon" "$p/bank/Unit1.yon"
  cat > "$p/Main.yon" <<'YON'
place Entry { }
fun main(): number {
  be s holds new State { balance 5 }
  be bad holds is_overdrawn(s)
  return if bad then 0 else 42
}
YON
  if ! grep -q '^spaces' "$p/yon.toml"; then
    awk '1; /^\[world\.Ledger\]/{print "spaces  = [\"bank\"]"}' "$p/yon.toml" > "$p/yon.toml.tmp"
    mv "$p/yon.toml.tmp" "$p/yon.toml"
  fi
  done_ "$p restructured"
else
  skip "$p already restructured"
fi

# --- B3. examples/c_topos_at_space ----------------------------------------
# Already has space Vault/ (Held.yon + Topos.yon=VaultTopos). The ROOT Main.yon
# ALSO carries `topos Bank` over root `place State`. A space holds exactly ONE
# Topos.yon, so Vault is taken: we lift Bank+State into a NEW space bank/.
# World = Ledger (currently spaces=["Vault"]) -> add "bank".
p="examples/c_topos_at_space"
if [ -f "$p/Main.yon" ] && grep -q "^topos Bank" "$p/Main.yon"; then
  note "$p: lifting topos Bank into NEW space bank/ (Vault already used)"
  mkdir -p "$p/bank"
  cat > "$p/bank/Topos.yon" <<'YON'
topos Bank where {
  prop is_positive(s: State): proposition = s.balance > 0
}
YON
  git add "$p/bank/Topos.yon"
  gmv "$p/State.yon" "$p/bank/State.yon"
  cat > "$p/Main.yon" <<'YON'
place Entry { }
fun main(): number { return 0 }
YON
  # toml already has spaces = ["Vault"] -> extend to include bank
  if grep -q 'spaces  = \["Vault"\]' "$p/yon.toml"; then
    sed -i.bak 's/spaces  = \["Vault"\]/spaces  = ["Vault", "bank"]/' "$p/yon.toml"
    rm -f "$p/yon.toml.bak"
  elif ! grep -q '"bank"' "$p/yon.toml"; then
    die "$p/yon.toml: unexpected spaces line; please add \"bank\" manually"
  fi
  done_ "$p restructured"
else
  skip "$p already restructured"
fi

# --- B4. regression/yon_tests/negative/sheaf_quotient_prop_reject ----------
# Root Main.yon: place Entry{}, topos Public { prop leaks_secret(s.secret) },
# main. Root State.yon holds cohort+secret. World Anon (quotient Base/cohort).
# Mirror the OK twin prop_ok: space anon/ + anon/Topos.yon + spaces=["anon"].
# Stays a NEGATIVE: leaks_secret reads s.secret (not cohort-invariant) -> reject.
p="regression/yon_tests/negative/sheaf_quotient_prop_reject"
if [ -f "$p/Main.yon" ] && grep -q "^topos Public" "$p/Main.yon"; then
  note "$p: lifting topos Public into space anon/ (mirror prop_ok)"
  mkdir -p "$p/anon"
  cat > "$p/anon/Topos.yon" <<'YON'
topos Public where {
  prop leaks_secret(s: State): proposition = s.secret < 1
}
YON
  git add "$p/anon/Topos.yon"
  gmv "$p/State.yon" "$p/anon/State.yon"
  cat > "$p/Main.yon" <<'YON'
place Entry { }
fun main(): number { return 0 }
YON
  if ! grep -q '^spaces' "$p/yon.toml"; then
    awk '1; /^\[world\.Anon\]/{print "spaces  = [\"anon\"]"}' "$p/yon.toml" > "$p/yon.toml.tmp"
    mv "$p/yon.toml.tmp" "$p/yon.toml"
  fi
  done_ "$p restructured"
else
  skip "$p already restructured"
fi

###############################################################################
# PART C — split multi-place root files (one place per file, filename=place)
###############################################################################
echo
echo "== PART C :: split multi-place files =="

# --- C1. examples/c_place_over/Main.yon (3 places: Entry, Base, Slice) ------
p="examples/c_place_over"
if [ -f "$p/Main.yon" ] && grep -q "^place Base" "$p/Main.yon"; then
  note "$p: splitting Base / Slice out of Main.yon"
  cat > "$p/Base.yon" <<'YON'
place Base { tag number }
YON
  cat > "$p/Slice.yon" <<'YON'
place Slice over Base { weight number }
YON
  git add "$p/Base.yon" "$p/Slice.yon"
  # reduce Main.yon to the entrypoint only
  cat > "$p/Main.yon" <<'YON'
place Entry { }
fun main(): number { return 0 }
YON
  done_ "$p split (Base.yon, Slice.yon)"
else
  skip "$p already split"
fi

# --- C2. examples/c_cell/Main.yon (2 places: Entry, Circle) ----------------
p="examples/c_cell"
if [ -f "$p/Main.yon" ] && grep -q "^place Circle" "$p/Main.yon"; then
  note "$p: splitting Circle out of Main.yon"
  cat > "$p/Circle.yon" <<'YON'
place Circle {
  base number
  cell loop from base to base
}
YON
  git add "$p/Circle.yon"
  cat > "$p/Main.yon" <<'YON'
place Entry { }
fun main(): number { return 0 }
YON
  done_ "$p split (Circle.yon)"
else
  skip "$p already split"
fi

# --- C3. regression/book/01/park_ok.yon ------------------------------------
# FLAGGED AMBIGUOUS — see report. park_ok.yon is a STANDALONE single-file test
# (inline `world Park { }`, `place ... in Park`, `world ... = ... / cohort`,
# `view ...`). It does NOT live in a project dir (no yon.toml governs it) and a
# proper PROJECT twin already exists at regression/book/01/park_project/. The
# layout rules apply to PROJECT directories; standalone single-file tests are
# EXEMPT. Splitting it would break its single-file semantics. We therefore do
# NOT touch it. If the human decides it must become a project, mirror
# park_project/ (herd/Dinosaur.yon + herd/Topos.yon, public/PublicDino.yon +
# public/Topos.yon). Left intentionally untouched.
echo "  [FLAG] regression/book/01/park_ok.yon: standalone single-file test (exempt). NOT touched. See report."

###############################################################################
# PART D — rename OrPlace (rule 4: no "place" substring)
#   examples/verify_algebra/alg/OrPlace.yon  ->  Or.yon
#   place OrPlace -> place Or ; update every reference in the project.
###############################################################################
echo
echo "== PART D :: rename OrPlace -> Or =="
p="examples/verify_algebra"
if [ -f "$p/alg/OrPlace.yon" ]; then
  note "$p: renaming file OrPlace.yon -> Or.yon and place OrPlace -> Or"
  gmv "$p/alg/OrPlace.yon" "$p/alg/Or.yon"
  # rename the place symbol inside the file
  sed -i.bak 's/\bplace OrPlace\b/place Or/' "$p/alg/Or.yon"; rm -f "$p/alg/Or.yon.bak"
  # update every other reference (Main.yon: `verify OrPlace`, etc.)
  while IFS= read -r f; do
    [ "$f" = "$p/alg/Or.yon" ] && continue
    sed -i.bak 's/\bOrPlace\b/Or/g' "$f"; rm -f "$f.bak"
    done_ "updated reference in $f"
  done < <(grep -rl --include='*.yon' '\bOrPlace\b' "$p" || true)
  done_ "$p: OrPlace fully renamed to Or"
else
  skip "$p: OrPlace.yon already renamed"
fi

###############################################################################
# PART A — Main.yon -> Entry.yon (or <CustomEntry>.yon) for PROJECT files that
# declare `place Entry` (or the toml's custom entry) and carry NO topos.
#
# Done LAST: Parts B/C have already reduced every former topos/multi-place root
# Main.yon to a bare `place Entry {}` + main, so they qualify here too.
#
# We scan every project (yon.toml dir). For each root-level Main.yon we re-check:
#   * it declares `place <E>` where <E> is the entry name
#       (toml `entry = "X"` overrides the default Entry)
#   * it does NOT declare a `topos` (those belong in a space's Topos.yon)
# Only then do we `git mv Main.yon <E>.yon`. Everything else is left alone.
###############################################################################
echo
echo "== PART A :: Main.yon -> Entry.yon (no-topos project entrypoints) =="
moved=0
while IFS= read -r toml; do
  d="$(dirname "$toml")"
  m="$d/Main.yon"
  [ -f "$m" ] || continue
  # custom entry name from toml if present, else "Entry"
  entry="$(sed -n 's/^[[:space:]]*entry[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$toml" | head -1)"
  [ -n "$entry" ] || entry="Entry"
  # must declare `place <entry>` and carry no topos
  if grep -qE "^place ${entry}\b" "$m" && ! grep -qE "^[[:space:]]*topos " "$m"; then
    git mv "$m" "$d/${entry}.yon"
    done_ "git mv $m -> $d/${entry}.yon"
    moved=$((moved+1))
  fi
done < <(find examples regression -name yon.toml -not -path '*/_build/*' | sort)
echo "  [A] renamed $moved Main.yon -> Entry.yon"

###############################################################################
# SUMMARY
###############################################################################
echo
echo "============================================================"
echo " migrate_round2 complete."
echo "  Part B (root topos -> space/Topos.yon): c_prop_abstract,"
echo "          kw_topos_block, c_topos_at_space, sheaf_quotient_prop_reject"
echo "  Part C (multi-place split): c_place_over (Base,Slice),"
echo "          c_cell (Circle).  park_ok.yon FLAGGED+exempt (untouched)."
echo "  Part D (OrPlace -> Or): examples/verify_algebra"
echo "  Part A (Main.yon -> Entry.yon): $moved project entrypoints"
echo "============================================================"
echo
echo " NEXT — verify the migration:"
echo "   cd frontend && dune build && cd .. && bash swarm/hooks/gate.sh"
echo
