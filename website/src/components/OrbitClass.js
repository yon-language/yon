import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * XRelSet / XRelMap — "one of this kind?" Keys on the orbit CLASS (here the sign
 * orbit: a point and its antipode are one class), not the exact point. Insert with
 * one representative, recall with another. Real run
 * (regression/book/jp/14_xrel_contract -> get(1536)=100, get(16778752)=100 same
 *  class, get(1280)=miss different class).
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
};
const mono = 'var(--ifm-font-family-monospace)';

// sign-orbit classes: 1536 ~ 16778752 (antipode); 1280 is its own class.
const QUERIES = [
  { k: 1536, cls: 0, hit: true, note: 'the key itself' },
  { k: 16778752, cls: 0, hit: true, note: 'the antipode — same class' },
  { k: 1280, cls: 1, hit: false, note: 'a different class' },
];

export default function OrbitClass() {
  const { i, set, playing, setPlaying } = useAutoplay(QUERIES.length);
  const q = QUERIES[i];

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
        <strong style={{ color: C.text }}>A map keyed by kind, not by specimen.</strong> Insert the
        value at one point; recall it from any point in the same orbit class. The{' '}
        <code>add_ref</code> you call first fixes the frame the class is computed against —{' '}
        <code>XRelMap</code> is Co2, relative to it. Real run (<code>14_xrel_contract</code> →{' '}
        <strong>100, 100, miss</strong>).
      </div>

      <svg viewBox="0 0 420 132" style={{ width: '100%', maxWidth: 420 }}>
        {/* class 0 bucket: 1536 + antipode 16778752, holds value 100 */}
        <rect
          x="10"
          y="16"
          width="248"
          height="100"
          rx="12"
          fill="var(--viz-fill)"
          stroke={C.accent}
          strokeDasharray="4 3"
        />
        <text x="22" y="34" fontSize="10" fontFamily={mono} fill={C.accentText}>
          orbit class 0 · value 100
        </text>
        {[
          { k: 1536, x: 80, y: 76 },
          { k: 16778752, x: 190, y: 70 },
        ].map((p) => {
          const lit = q.cls === 0 && q.k === p.k;
          return (
            <g key={p.k} fontFamily={mono}>
              <circle
                cx={p.x}
                cy={p.y}
                r="12"
                fill={lit ? 'var(--viz-fill-green)' : 'var(--viz-fill)'}
                stroke={lit ? C.green : C.accent}
                strokeWidth={lit ? 2.5 : 1.5}
              />
              <text x={p.x} y={p.y + 30} textAnchor="middle" fontSize="10" fill={C.accentText}>
                {p.k}
              </text>
            </g>
          );
        })}

        {/* class 1 bucket: 1280 */}
        <rect
          x="270"
          y="16"
          width="140"
          height="100"
          rx="12"
          fill="var(--viz-fill-red)"
          stroke={C.red}
          strokeDasharray="4 3"
        />
        <text x="282" y="34" fontSize="10" fontFamily={mono} fill={C.redText}>
          orbit class 1
        </text>
        {(() => {
          const lit = q.cls === 1;
          return (
            <g fontFamily={mono}>
              <circle
                cx="340"
                cy="74"
                r="12"
                fill={lit ? 'var(--viz-fill-red)' : 'transparent'}
                stroke={C.red}
                strokeWidth={lit ? 2.5 : 1.5}
              />
              <text x="340" y="104" textAnchor="middle" fontSize="10" fill={C.redText}>
                1280
              </text>
            </g>
          );
        })()}
      </svg>

      <div
        style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 8, flexWrap: 'wrap' }}
      >
        <span style={{ fontFamily: mono, fontSize: 14 }}>
          get(<span style={{ color: q.hit ? C.accentText : C.redText }}>{q.k}</span>)
        </span>
        <span style={{ color: C.faint }}>→</span>
        {q.hit ? (
          <span style={{ fontFamily: mono, fontSize: 16, fontWeight: 600, color: C.greenText }}>
            100
          </span>
        ) : (
          <span style={{ fontFamily: mono, fontSize: 14, color: C.redText }}>miss</span>
        )}
        <span style={{ fontSize: 12.5, color: C.sub }}>— {q.note}</span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(i + 1)} style={btn(C)}>
          Next lookup ▸
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
