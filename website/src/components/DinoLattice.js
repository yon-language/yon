import React, { useMemo, useState } from 'react';
import trace from '@site/src/data/jp-traces/dino_lattice.json';

/**
 * "Classifying the animals." Two ways to ask how four dinosaur genomes are related.
 *
 * HONESTY CONTRACT:
 *   - The of2 CLASS on every pair is the REAL stdout of regression/book/jp/07_dino_lattice
 *     (toolchain/yonc; regenerate with website/scripts/build-jp-traces.py). of2(a,b) =
 *     XSimplex.of2 = the leech2 subtype of a^b: a CATEGORICAL class in 0..11, NOT an ordered
 *     distance. Deterministic, symmetric, stable across builds. Co2-invariant but NOT Co0
 *     (the harness records the xi counterexample). We never render it as a position/length.
 *   - Wu's ruler is |genome_i - genome_j|, computed here in JS and shown as the arbitrary
 *     ruler it is. It is not an emitted fact; it is the chosen table the chapter critiques.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  border: 'var(--ifm-color-emphasis-300, #dadde1)',
  panel: 'var(--ifm-color-emphasis-100, #f5f6f7)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  same: 'var(--viz-green)',
  sameText: 'var(--viz-green)',
  diff: 'var(--ifm-color-emphasis-500, #8a8f98)',
};

// categorical colours for the realized of2 classes (NO order implied)
const CLASS_COLOR = { 1: 'var(--viz-accent)', 7: 'var(--viz-gold)', 11: 'var(--viz-accent)' };
const CLASS_TEXT = { 1: 'var(--viz-accent-2)', 7: 'var(--viz-gold)', 11: 'var(--viz-accent-2)' };
const SHORT = {
  Tyrannosaurus: 'T. rex',
  Velociraptor: 'Raptor',
  Dilophosaurus: 'Dilo',
  Gallimimus: 'Galli',
};

const gx = Object.fromEntries(trace.genomes.map((g) => [g.id, g.x]));
const gname = Object.fromEntries(trace.genomes.map((g) => [g.id, SHORT[g.name] || g.name]));
const PAIRS = trace.edges.map((e) => ({
  a: e.a,
  b: e.b,
  of2: e.of2,
  delta: Math.abs(gx[e.a] - gx[e.b]),
  label: `${gname[e.a]} — ${gname[e.b]}`,
}));
const DELTAS = PAIRS.map((p) => p.delta);
const LO = Math.log10(Math.min(...DELTAS)) - 0.25; // slider / bar domain in log10
const HI = Math.log10(Math.max(...DELTAS)) + 0.25;
const barFrac = (d) => (Math.log10(d) - LO) / (HI - LO);

// two real labs, two cutoffs, two groupings -- chosen to disagree
const LABS = [
  { name: 'Lab α', cut: 2000 },
  { name: 'Lab β', cut: 500 },
];

function clusters(cutoff) {
  const ids = trace.genomes.map((g) => g.id);
  const parent = Object.fromEntries(ids.map((i) => [i, i]));
  const find = (x) => (parent[x] === x ? x : (parent[x] = find(parent[x])));
  PAIRS.forEach((p) => {
    if (p.delta <= cutoff) parent[find(p.a)] = find(p.b);
  });
  const groups = {};
  ids.forEach((i) => {
    (groups[find(i)] = groups[find(i)] || []).push(i);
  });
  return Object.values(groups).map((g) => g.map((i) => gname[i]));
}

const fmtDelta = (d) =>
  d >= 1e6 ? (d / 1e6).toFixed(1) + 'M' : d >= 1000 ? (d / 1000).toFixed(1) + 'k' : '' + d;

export default function DinoLattice() {
  const [logCut, setLogCut] = useState(Math.log10(LABS[0].cut));
  const cutoff = Math.pow(10, logCut);
  const groups = useMemo(() => clusters(cutoff), [cutoff]);
  const spot = trace.spotlight; // B-C

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 760,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>Four genomes, two ways to relate them.</strong> The{' '}
        <strong>of2</strong> class of each pair is Yon's real output (<code>{trace.source}</code>):
        a label in <code>0..{trace.alphabet_size - 1}</code>, computed, not chosen. Wu's ruler is
        the raw difference of the genome numbers, a table someone builds. Drag Wu's cutoff and watch
        his verdicts move; the classes do not.
      </div>

      {/* Wu's cutoff control */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          flexWrap: 'wrap',
          marginBottom: 6,
        }}
      >
        <span style={{ fontSize: 12, color: C.sub, minWidth: 96 }}>Wu's cutoff</span>
        <input
          type="range"
          min={LO}
          max={HI}
          step={0.01}
          value={logCut}
          onChange={(e) => setLogCut(parseFloat(e.target.value))}
          style={{ flex: 1, minWidth: 180, accentColor: C.same }}
        />
        <code style={{ fontSize: 12, color: C.text }}>≤ {fmtDelta(Math.round(cutoff))}</code>
        {LABS.map((l) => (
          <button
            key={l.name}
            onClick={() => setLogCut(Math.log10(l.cut))}
            style={{
              fontFamily: 'var(--ifm-font-family-base)',
              fontSize: 12,
              padding: '4px 10px',
              borderRadius: 7,
              border: `0.5px solid ${C.border}`,
              background: 'transparent',
              color: C.text,
              cursor: 'pointer',
            }}
          >
            {l.name}
          </button>
        ))}
      </div>
      <div style={{ fontSize: 12, color: C.sub, marginBottom: 12 }}>
        Wu's groups here:{' '}
        {groups.map((g, i) => (
          <span
            key={i}
            style={{
              display: 'inline-block',
              padding: '1px 8px',
              margin: '2px 4px 2px 0',
              borderRadius: 10,
              background: C.rail,
              fontSize: 11.5,
              color: C.text,
            }}
          >
            {g.join(' · ')}
          </span>
        ))}
        <span style={{ color: C.faint }}>&nbsp;— another cutoff, another grouping.</span>
      </div>

      {/* the six pairs, two columns */}
      <div style={{ border: `1px solid ${C.border}`, borderRadius: 10, overflow: 'hidden' }}>
        <div
          style={{
            display: 'flex',
            fontSize: 10.5,
            textTransform: 'uppercase',
            letterSpacing: '.04em',
            color: C.sub,
            background: C.panel,
            padding: '7px 12px',
            borderBottom: `1px solid ${C.border}`,
          }}
        >
          <div style={{ flex: '0 0 130px' }}>pair</div>
          <div style={{ flex: 1 }}>Wu's ruler — chosen</div>
          <div style={{ flex: '0 0 92px', textAlign: 'right' }}>of2 — computed</div>
        </div>
        {PAIRS.map((p, i) => {
          const same = p.delta <= cutoff;
          const isSpot = `${p.a}-${p.b}` === spot.pair;
          return (
            <div
              key={i}
              style={{
                display: 'flex',
                alignItems: 'center',
                padding: '9px 12px',
                borderBottom: i < PAIRS.length - 1 ? `1px solid ${C.rail}` : 'none',
                background: isSpot ? 'var(--viz-fill)' : 'transparent',
              }}
            >
              <div style={{ flex: '0 0 130px', fontSize: 12.5, fontWeight: isSpot ? 600 : 400 }}>
                {p.label}
              </div>
              <div style={{ flex: 1, paddingRight: 14 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <div
                    style={{
                      flex: 1,
                      height: 8,
                      background: C.rail,
                      borderRadius: 4,
                      overflow: 'hidden',
                    }}
                  >
                    <div
                      style={{
                        width: `${Math.max(3, barFrac(p.delta) * 100)}%`,
                        height: '100%',
                        borderRadius: 4,
                        background: same ? C.same : C.diff,
                        transition: 'background .25s, width .3s',
                      }}
                    />
                  </div>
                  <code
                    style={{ fontSize: 10.5, color: C.faint, minWidth: 40, textAlign: 'right' }}
                  >
                    {fmtDelta(p.delta)}
                  </code>
                  <span
                    style={{
                      fontSize: 10.5,
                      fontWeight: 600,
                      minWidth: 62,
                      textAlign: 'right',
                      color: same ? C.sameText : C.diff,
                    }}
                  >
                    {same ? 'same kind' : 'different'}
                  </span>
                </div>
              </div>
              <div style={{ flex: '0 0 92px', textAlign: 'right' }}>
                <span
                  style={{
                    display: 'inline-block',
                    minWidth: 58,
                    padding: '3px 0',
                    borderRadius: 7,
                    fontFamily: 'var(--ifm-font-family-monospace)',
                    fontSize: 12.5,
                    fontWeight: 600,
                    color: '#fff',
                    background: CLASS_COLOR[p.of2] || C.faint,
                  }}
                >
                  class {p.of2}
                </span>
              </div>
            </div>
          );
        })}
      </div>

      {/* the spotlight: opposite verdicts */}
      <div
        style={{
          marginTop: 14,
          padding: '11px 14px',
          borderRadius: 9,
          background: C.panel,
          borderLeft: `3px solid ${CLASS_COLOR[spot.of2]}`,
          fontSize: 12.5,
          color: C.sub,
          lineHeight: 1.55,
        }}
      >
        <strong style={{ color: C.text }}>
          {gname[spot.pair.split('-')[0]]} and {gname[spot.pair.split('-')[1]]}.
        </strong>{' '}
        Wu's ruler calls them maximally different — their genome numbers differ by{' '}
        <code>{fmtDelta(spot.genome_delta)}</code>, the widest gap on the table. of2 puts them in{' '}
        <strong style={{ color: CLASS_TEXT[spot.of2] }}>class {spot.of2}</strong>, the same class as{' '}
        {gname.A} — {gname.B}. The ruler is fooled by the size of the number; the lattice reads the
        structure. One of these is a choice. The other is not.
      </div>

      <div style={{ fontSize: 11, color: C.faint, lineHeight: 1.5, marginTop: 12 }}>
        of2 is a <strong>category</strong>, not a distance: the colours are labels, not lengths, and
        a smaller class does not mean "closer". It is deterministic and symmetric, and{' '}
        <strong>Co2-invariant</strong> by construction (the frame-fixing symmetries) — not Co0: a
        frame rotation can relabel a pair, and that witness is not even build-stable, so only the
        matrix of fixed genomes is shown. Of the {trace.alphabet_size} possible classes these four
        realize {trace.realized_classes.map((c) => `class ${c}`).join(', ')}. Wu's bars are |genomeᵢ
        − genomeⱼ|, drawn here as the chosen ruler they are.
      </div>
    </div>
  );
}
