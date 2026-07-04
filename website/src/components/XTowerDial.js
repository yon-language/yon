import React, { useState } from 'react';
import trace from '@site/src/data/jp-traces/dial.json';

/**
 * "The dial of equality." XTower's same_branch(a, b, level): are two genes the same,
 * at a grain you turn? Co0 (1 class, all one) -> N (3) -> M24 (12, XRelSet's classes)
 * -> id (196560, XSet's individuals). Real Yon output (regression/book/jp/12_xtower_dial,
 * 08_xtower_surface): the mutant 2361 is the SAME as 1445 at the coarse end and
 * DIFFERENT once the grain is fine -- same_branch = 1,1,0,0. The blind spot is the
 * LEVEL, not the structure. The widths and the verdict are real; the cell layout is a
 * drawing. Orbit labels build-unstable; the partition (same/different) is stable.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  border: 'var(--ifm-color-emphasis-300, #dadde1)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  panel: 'var(--ifm-color-emphasis-100, #f5f6f7)',
  same: 'var(--viz-gold)',
  sameT: 'var(--viz-gold)', // collapsed / blind = warning gold
  diff: 'var(--viz-green)',
  diffT: 'var(--viz-green)', // distinguished / seen = green
  accent: 'var(--viz-accent)',
};
const L = trace.levels;
const fmt = (n) => n.toLocaleString('en-US');
// fractional positions chosen so the cell-split matches the gated same_branch (1,1,0,0)
const POS = { orig: 0.34, mutant: 0.63 };

export default function XTowerDial() {
  // Default to M24 (level 2): the coarsest grain where same_branch flips 1 -> 0, i.e.
  // the frame where the mutant first APPEARS. At Co0/N it is still hidden; at id
  // everything differs from everything (no blind spot left). M24 is the dramatic beat —
  // where seeing or not seeing depends on the grain. The dial still turns to any level.
  const [lvl, setLvl] = useState(2);
  const d = L[lvl];
  const merged = d.same === 1;
  const segs = Math.min(d.width, 24); // cap drawn cells
  const cellOf = (p) => Math.min(segs - 1, Math.floor(p * segs));
  const cO = cellOf(POS.orig),
    cM = cellOf(POS.mutant);
  const W = 560,
    H = 64,
    x0 = 8,
    bw = W - 16;
  const seg = bw / segs;

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 620,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>The dial of equality.</strong> Turn the grain and ask: is
        the mutant <code>{trace.mutant}</code> the same animal as <code>{trace.orig}</code>? (
        <code>{trace.source}</code>) At the coarse end it is hidden; turn toward the fine end and it
        appears. The blind spot is the level you stop at.
      </div>

      <svg viewBox={`0 0 ${W} ${H}`} style={{ width: '100%', height: 'auto', marginBottom: 6 }}>
        {Array.from({ length: segs }, (_, k) => {
          const isGene = k === cO || k === cM;
          const col = !isGene ? C.rail : merged ? C.same : C.diff;
          return (
            <rect
              key={k}
              x={x0 + k * seg + 1}
              y={18}
              width={Math.max(1, seg - 2)}
              height={30}
              rx={3}
              fill={col}
              opacity={isGene ? 0.9 : 0.5}
              style={{ transition: 'fill .35s, opacity .35s' }}
            />
          );
        })}
        {/* gene markers */}
        {[
          ['orig', POS.orig, cO],
          ['mutant', POS.mutant, cM],
        ].map(([name, p, c]) => {
          const cx = x0 + c * seg + seg / 2;
          return (
            <g key={name} style={{ transition: 'transform .35s' }}>
              <circle
                cx={cx}
                cy={33}
                r={5}
                fill="#fff"
                stroke={merged ? C.sameT : C.diffT}
                strokeWidth={2}
              />
              <text
                x={cx}
                y={12}
                textAnchor="middle"
                fontSize="10"
                fontWeight="600"
                fill={C.sub}
                fontFamily="var(--ifm-font-family-monospace)"
              >
                {trace[name]}
              </text>
            </g>
          );
        })}
        {d.width > segs && (
          <text x={W - 10} y={62} textAnchor="end" fontSize="9.5" fill={C.faint}>
            showing {segs} of {fmt(d.width)} cells
          </text>
        )}
      </svg>

      {/* the dial control */}
      <input
        type="range"
        min={0}
        max={L.length - 1}
        step={1}
        value={lvl}
        onChange={(e) => setLvl(+e.target.value)}
        style={{ width: '100%', accentColor: C.accent, margin: '4px 0 2px' }}
      />
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          fontSize: 11,
          color: C.faint,
          marginBottom: 12,
        }}
      >
        {L.map((x, i) => (
          <span
            key={i}
            onClick={() => setLvl(i)}
            style={{
              cursor: 'pointer',
              fontWeight: i === lvl ? 700 : 400,
              color: i === lvl ? C.text : C.faint,
            }}
          >
            {x.name}
          </span>
        ))}
      </div>

      <div style={{ display: 'flex', gap: 14, flexWrap: 'wrap', alignItems: 'stretch' }}>
        <div
          style={{
            flex: 1,
            minWidth: 150,
            padding: '10px 14px',
            borderRadius: 9,
            background: C.panel,
          }}
        >
          <div
            style={{
              fontSize: 10.5,
              textTransform: 'uppercase',
              letterSpacing: '.04em',
              color: C.faint,
            }}
          >
            level {d.level} · {d.name}
          </div>
          <div
            style={{
              fontFamily: 'var(--ifm-font-family-monospace)',
              fontSize: 'clamp(20px,5vw,30px)',
              fontWeight: 700,
              color: C.text,
              lineHeight: 1.2,
            }}
          >
            {fmt(d.width)}
          </div>
          <div style={{ fontSize: 11.5, color: C.sub }}>
            {d.width === 1 ? 'one class — everything is one' : `${fmt(d.width)} classes`}
            {d.name === 'M24' && ' = XRelSet (by kind)'}
            {d.name === 'id' && ' = XSet (each individual)'}
          </div>
        </div>
        <div
          style={{
            flex: 1,
            minWidth: 150,
            padding: '10px 14px',
            borderRadius: 9,
            background: merged ? `${C.same}14` : `${C.diff}14`,
            border: `1px solid ${merged ? C.same : C.diff}55`,
          }}
        >
          <div
            style={{
              fontSize: 10.5,
              textTransform: 'uppercase',
              letterSpacing: '.04em',
              color: C.faint,
            }}
          >
            {trace.orig} vs mutant {trace.mutant}
          </div>
          <div
            style={{
              fontSize: 'clamp(18px,4.5vw,26px)',
              fontWeight: 700,
              color: merged ? C.sameT : C.diffT,
              lineHeight: 1.25,
            }}
          >
            {merged ? 'the same' : 'different'}
          </div>
          <div style={{ fontSize: 11.5, color: C.sub }}>
            {merged ? 'the mutant is invisible at this grain' : 'the mutant has appeared'}{' '}
            (same_branch = {d.same})
          </div>
        </div>
      </div>

      <div style={{ fontSize: 11, color: C.faint, lineHeight: 1.5, marginTop: 12 }}>
        One structure, one parameter. <strong>id</strong> is XSet (the exact head count),{' '}
        <strong>M24</strong> is XRelSet (the count by kind) — two settings of the same dial. The
        tower is a true refinement: turning toward Co0 only ever loses individuals, never gains
        them.
      </div>
    </div>
  );
}
