import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * Arena — "store at a lattice address, know its kind, fuse lineages." The kind is the
 * M24 orbit; a fusion is recorded with a Conway-group certificate. Real run
 * (regression/book/jp/uc_arena -> get=42, same_orbit(1536,1280)=1,
 *  same_orbit(1536,16778752)=0, fusion_count=1).
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

// three lattice addresses; same kind = same M24 orbit (a real fact, uc_arena)
const PTS = [
  { id: 1536, x: 70, y: 60, kind: 'A', val: 42 },
  { id: 1280, x: 180, y: 50, kind: 'A' },
  { id: 16778752, x: 300, y: 78, kind: 'B' },
];

export default function ArenaOrbit() {
  const { i, set, playing, setPlaying } = useAutoplay(2);
  const fused = i === 1;
  const a = PTS[0],
    b = PTS[1];

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
        <strong style={{ color: C.text }}>A value at a lattice address — and its kind.</strong> Two
        points in the same M24 orbit are the same kind; <code>fuse</code> records a bred lineage
        with a Conway-group certificate. Real run (<code>uc_arena</code> →{' '}
        <strong>42, 1, 0, 1</strong>).
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

        {fused && (
          <g>
            <path
              d={`M${a.x} ${a.y} Q ${(a.x + b.x) / 2} ${Math.min(a.y, b.y) - 28} ${b.x} ${b.y}`}
              fill="none"
              stroke={C.gold}
              strokeWidth="2"
              strokeDasharray="3 3"
            />
            <text
              x={(a.x + b.x) / 2}
              y={Math.min(a.y, b.y) - 32}
              textAnchor="middle"
              fontSize="9.5"
              fontFamily={mono}
              fill={C.goldText}
            >
              fuse ✓
            </text>
          </g>
        )}

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
          <span style={{ color: C.greenText }}>same_orbit(1536, 1280) = 1</span> — same kind
        </span>
        <span>
          <span style={{ color: C.redText }}>same_orbit(1536, 16778752) = 0</span> — different
        </span>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 10 }}>
        <span style={{ fontFamily: mono, fontSize: 13, color: C.sub }}>
          fusion_count(1536) = {fused ? 1 : 0}
        </span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(fused ? 0 : 1)} style={btn(C)}>
          {fused ? '↩ undo' : 'fuse(1536, 1280) ▸'}
        </button>
      </div>
    </div>
  );
}

function btn(c) {
  return {
    fontFamily: 'var(--ifm-font-family-base)',
    fontSize: 13,
    padding: '6px 14px',
    borderRadius: 8,
    border: `0.5px solid ${c.line}`,
    background: 'transparent',
    color: c.text,
    cursor: 'pointer',
  };
}
