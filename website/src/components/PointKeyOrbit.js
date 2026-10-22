import React from 'react';

/**
 * XRelMap keyed by LatticePoint — "store at a lattice address, know its kind." The
 * kind is the M24 orbit, a property of the point. Real run
 * (regression/book/jp/uc_xrel -> get=42, has=1, orbit(1536)==orbit(1280) is 1,
 *  orbit(1536)==orbit(16778752) is 0).
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-400, #a0a4ab)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  accent: 'var(--viz-accent)',
  accentText: 'var(--viz-accent-2)',
  green: 'var(--viz-green)',
  greenText: 'var(--viz-green)',
  red: 'var(--viz-red)',
  redText: 'var(--viz-red)',
  gold: 'var(--viz-gold)',
  goldText: 'var(--viz-gold)',
};
const mono = 'var(--ifm-font-family-monospace)';

// three lattice addresses; same kind = same M24 orbit (a real fact, uc_xrel)
const PTS = [
  { id: 1536, x: 70, y: 60, kind: 'A', val: 42 },
  { id: 1280, x: 180, y: 50, kind: 'A' },
  { id: 16778752, x: 300, y: 78, kind: 'B' },
];

export default function PointKeyOrbit() {
  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 600,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 12 }}>
        <strong style={{ color: C.text }}>A value at a lattice address — and its kind.</strong> An{' '}
        <code>XRelMap</code> keyed by <code>LatticePoint</code> finds a key by its index on the
        shell; two points in the same M24 orbit are the same kind. Real run (<code>uc_xrel</code>{' '}
        → <strong>42, 1, 0, 1, 0</strong>).
      </div>

      <svg viewBox="0 0 380 130" style={{ width: '100%', maxWidth: 380 }}>
        {/* faint lattice grid */}
        {[...Array(8)].map((_, i) => (
          <line
            key={'v' + i}
            x1={20 + i * 48}
            y1="14"
            x2={20 + i * 48}
            y2="116"
            stroke={C.line}
            strokeOpacity="0.4"
          />
        ))}
        {[...Array(3)].map((_, i) => (
          <line
            key={'h' + i}
            x1="20"
            y1={28 + i * 44}
            x2="356"
            y2={28 + i * 44}
            stroke={C.line}
            strokeOpacity="0.4"
          />
        ))}

        {PTS.map((p) => {
          const col = p.kind === 'A' ? C.accent : C.red;
          const tcol = p.kind === 'A' ? C.accentText : C.redText;
          return (
            <g key={p.id} fontFamily={mono}>
              <circle
                cx={p.x}
                cy={p.y}
                r="11"
                fill={p.kind === 'A' ? 'var(--viz-fill)' : 'var(--viz-fill-red)'}
                stroke={col}
                strokeWidth="1.5"
              />
              <text x={p.x} y={p.y - 16} textAnchor="middle" fontSize="10" fill={tcol}>
                {p.id}
              </text>
              {p.val && (
                <text x={p.x} y={p.y + 4} textAnchor="middle" fontSize="11" fill={tcol}>
                  {p.val}
                </text>
              )}
              <text x={p.x} y={p.y + 26} textAnchor="middle" fontSize="9" fill={C.faint}>
                kind {p.kind}
              </text>
            </g>
          );
        })}
      </svg>

      <div
        style={{
          display: 'flex',
          flexWrap: 'wrap',
          gap: '6px 16px',
          marginTop: 8,
          fontFamily: mono,
          fontSize: 12.5,
        }}
      >
        <span>
          <span style={{ color: C.greenText }}>orbit(1536) == orbit(1280)</span> — same kind
        </span>
        <span>
          <span style={{ color: C.redText }}>orbit(1536) ≠ orbit(16778752)</span> — different
        </span>
      </div>
    </div>
  );
}
