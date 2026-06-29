import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * Vec — "count the individuals, indexed." push keeps every entry (duplicates too);
 * get/set address by position. Real run
 * (regression/book/jp/uc_vec -> size 3, get(0)=1445, after set(1,9999) get(1)=9999).
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-400, #a0a4ab)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  accent: '#4f8ff7',
  accentText: '#2f6fd0',
  gold: '#d99a2b',
  goldText: '#b5790f',
};
const mono = 'var(--ifm-font-family-monospace)';
const BASE = [1445, 1280, 1445];

export default function HerdCount() {
  const { i, set, playing, setPlaying } = useAutoplay(2);
  const set1 = i === 1;
  const cells = set1 ? [1445, 9999, 1445] : BASE;

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 540,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>The honest head-count.</strong> Every animal is an entry,
        in order, indexed — the duplicate <code>1445</code> is kept (events, not kinds).{' '}
        <code>set</code>
        overwrites one slot. Real run (<code>uc_vec</code> → size <strong>3</strong>).
      </div>

      <svg viewBox="0 0 360 92" style={{ width: '100%', maxWidth: 360 }}>
        {cells.map((v, i) => {
          const x = 14 + i * 112;
          const changed = set1 && i === 1;
          const dup = !changed && v === 1445;
          return (
            <g key={i} fontFamily={mono}>
              <text x={x + 48} y={16} textAnchor="middle" fontSize="10" fill={C.faint}>
                index {i}
              </text>
              <rect
                x={x}
                y={24}
                width="96"
                height="42"
                rx="8"
                fill={changed ? 'rgba(217,154,43,0.12)' : 'rgba(79,143,247,0.07)'}
                stroke={changed ? C.gold : C.accent}
                strokeWidth={changed ? 2 : 1}
              />
              <text
                x={x + 48}
                y={51}
                textAnchor="middle"
                fontSize="17"
                fill={changed ? C.goldText : C.accentText}
              >
                {v}
              </text>
              {dup && (
                <text
                  x={x + 48}
                  y={82}
                  textAnchor="middle"
                  fontSize="9.5"
                  fontFamily="var(--ifm-font-family-base)"
                  fill={C.faint}
                >
                  duplicate, kept
                </text>
              )}
            </g>
          );
        })}
      </svg>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 }}>
        <span style={{ fontFamily: mono, fontSize: 13, color: C.sub }}>
          {set1 ? 'set(1, 9999) → get(1) = 9999' : 'get(0) = 1445'} · size 3
        </span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(set1 ? 0 : 1)} style={btn(C)}>
          {set1 ? '↩ undo set' : 'set(1, 9999) ▸'}
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
