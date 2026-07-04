import React, { useState } from 'react';
import trace from '@site/src/data/jp-traces/taxa_full.json';

/**
 * "The absolute invariant." A triple of taxa, its three of2 edge classes, and the
 * triangle's holonomy omega = sgn⟨u,v⟩·sgn⟨v,w⟩·sgn⟨w,u⟩ ∈ {−1,0,+1}.
 *
 * THE POINT (real Yon numbers, regression/book/jp/10_taxa_full xi_demo): apply a
 * frame change ξ to all three points and the single EDGE classes (of2) move — of2
 * is Co2-invariant only (the gate's C–D counterexample, made visual). But the
 * triangle's omega does NOT move: it is Co0-invariant (runtime/yon_rt.c:4764,
 * "verified: 0 deviations over 2e6 random triangles"), because the per-edge sign
 * is gauge and the product around the closed cycle cancels it. The one absolute
 * invariant in the family — the honest redemption of the Co0 claim of2 could not make.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  border: 'var(--ifm-color-emphasis-300, #dadde1)',
  panel: 'var(--ifm-color-emphasis-100, #f5f6f7)',
  edge: 'var(--viz-accent)',
  edgeText: 'var(--viz-accent-2)',
  move: 'var(--viz-red)',
  moveText: 'var(--viz-red)',
  fixed: 'var(--viz-green)',
  fixedText: 'var(--viz-green)',
};

const D = trace.xi_demo; // {triple, home:{of2,omega}, frame_xi:{of2,omega}}
const NAMES = D.triple; // [A, B, C]
const SHORT = (n) =>
  ({ Eoraptor: 'Eoraptor', Velociraptor: 'Velociraptor', Gallus: 'Gallus' })[n] || n;
// vertices A(top) B(bottom-left) C(bottom-right); edges in of2 order [AB, BC, AC]
const V = [
  { x: 230, y: 40 },
  { x: 70, y: 250 },
  { x: 390, y: 250 },
];
const EDGES = [
  [0, 1],
  [1, 2],
  [0, 2],
]; // AB, BC, AC  (matches of2 order)
const mid = (a, b) => ({ x: (V[a].x + V[b].x) / 2, y: (V[a].y + V[b].y) / 2 });
const omegaGlyph = (o) => (o > 0 ? '↻' : o < 0 ? '↺' : '∅');

export default function OmegaInvariant() {
  const [xi, setXi] = useState(false);
  const f = xi ? D.frame_xi : D.home;
  const moved = D.home.of2.map((v, i) => v !== D.frame_xi.of2[i]);

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 720,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 12 }}>
        <strong style={{ color: C.text }}>The absolute invariant.</strong> Three species, their
        three <code>of2</code> edge classes, and the triangle's <strong>omega</strong> (its
        holonomy, −1/0/+1). Real Yon output (<code>{trace.source}</code>). Change the frame (apply
        Conway's ξ): the edges move, the cycle does not.
      </div>

      <div style={{ display: 'flex', gap: 24, alignItems: 'center', flexWrap: 'wrap' }}>
        <svg viewBox="0 0 460 300" style={{ width: 380, flexShrink: 0 }}>
          {EDGES.map(([a, b], i) => {
            const m = mid(a, b);
            const on = xi && moved[i];
            return (
              <g key={i}>
                <line
                  x1={V[a].x}
                  y1={V[a].y}
                  x2={V[b].x}
                  y2={V[b].y}
                  stroke={on ? C.move : C.edge}
                  strokeWidth={on ? 3 : 2}
                  style={{ transition: 'stroke .3s, stroke-width .3s' }}
                />
                <rect
                  x={m.x - 26}
                  y={m.y - 12}
                  width="52"
                  height="22"
                  rx="6"
                  fill="#fff"
                  stroke={on ? C.move : C.border}
                  strokeWidth="1"
                />
                <text
                  x={m.x}
                  y={m.y + 3}
                  textAnchor="middle"
                  fontSize="11.5"
                  fontWeight="600"
                  fill={on ? C.moveText : C.edgeText}
                  fontFamily="var(--ifm-font-family-monospace)"
                >
                  {f.of2[i] < 0 ? 'none' : 'class ' + f.of2[i]}
                </text>
              </g>
            );
          })}
          {/* omega at the centroid */}
          <circle cx={230} cy={185} r="34" fill={C.panel} stroke={C.fixed} strokeWidth="2" />
          <text x={230} y={181} textAnchor="middle" fontSize="22" fill={C.fixedText}>
            {omegaGlyph(f.omega)}
          </text>
          <text
            x={230}
            y={199}
            textAnchor="middle"
            fontSize="11"
            fontWeight="600"
            fill={C.fixedText}
            fontFamily="var(--ifm-font-family-monospace)"
          >
            ω = {f.omega > 0 ? '+1' : f.omega}
          </text>
          {V.map((p, i) => (
            <g key={i}>
              <circle cx={p.x} cy={p.y} r="6" fill={C.text} />
              <text
                x={p.x}
                y={i === 0 ? p.y - 12 : p.y + 20}
                textAnchor="middle"
                fontSize="11.5"
                fontWeight="600"
                fill={C.text}
              >
                {SHORT(NAMES[i])}
              </text>
            </g>
          ))}
        </svg>

        <div style={{ flex: 1, minWidth: 230 }}>
          <button
            onClick={() => setXi((x) => !x)}
            style={{
              fontFamily: 'var(--ifm-font-family-base)',
              fontSize: 13,
              padding: '8px 16px',
              borderRadius: 8,
              border: `0.5px solid ${C.border}`,
              cursor: 'pointer',
              marginBottom: 14,
              background: xi ? 'var(--viz-fill-red)' : 'transparent',
              color: C.text,
              fontWeight: 600,
            }}
          >
            {xi ? '↩ back to the home frame' : '⟳ change frame (apply ξ)'}
          </button>

          <div style={{ fontSize: 12.5, lineHeight: 1.6, color: C.sub }}>
            <div style={{ marginBottom: 8 }}>
              <span style={{ color: C.moveText, fontWeight: 600 }}>The edges (of2): Co2.</span>{' '}
              Under ξ they move — <code>{D.home.of2.map((v) => (v < 0 ? '·' : v)).join(', ')}</code>{' '}
              → <code>{D.frame_xi.of2.map((v) => (v < 0 ? '·' : v)).join(', ')}</code>. of2 is fixed
              only by the symmetries that fix the frame.
            </div>
            <div>
              <span style={{ color: C.fixedText, fontWeight: 600 }}>The cycle (omega): Co0.</span> ω
              = {D.home.omega > 0 ? '+1' : D.home.omega} in <em>both</em> frames. The per-edge sign
              is gauge; the product around the closed triangle cancels it, so omega survives{' '}
              <em>every</em> frame — verified in the runtime over 2·10⁶ triangles, zero deviations.
            </div>
          </div>
        </div>
      </div>

      <div style={{ fontSize: 11, color: C.faint, lineHeight: 1.5, marginTop: 12 }}>
        The edge class is Co2 — fix the frame and it holds, change it and it can move. The
        triangle's omega is Co0: the gauge cancels on the cycle, and no point of view can touch it.
      </div>
    </div>
  );
}
