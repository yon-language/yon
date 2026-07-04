import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * HashSet — "is this exact genome on file?" The FNV hash dedups by byte-compare:
 * the same genome twice counts once. Numbers are a real Yon run
 * (regression/book/jp/uc_hashset -> 4 distinct).
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-400, #a0a4ab)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  accent: 'var(--viz-accent)',
  accentText: 'var(--viz-accent-2)',
  red: 'var(--viz-red)',
};
const mono = 'var(--ifm-font-family-monospace)';
const ADDS = [1445, 1445, 2361, 100, 200]; // uc_hashset: the add sequence

export default function HashIdentity() {
  const { i, set, playing, setPlaying } = useAutoplay(ADDS.length + 1);
  const n = i; // how many adds applied
  const applied = ADDS.slice(0, n);
  const seen = [];
  const fates = applied.map((g) => {
    const dup = seen.includes(g);
    if (!dup) seen.push(g);
    return dup ? 'dup' : 'new';
  });
  const size = seen.length;

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 640,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>The hash dedups by content.</strong> Each genome is added;
        the second <code>1445</code> compares equal byte-for-byte and is dropped. The count is a
        real run (<code>uc_hashset</code> → <strong>4</strong>).
      </div>

      <div style={{ display: 'flex', gap: 10, marginBottom: 14, flexWrap: 'wrap' }}>
        {ADDS.map((g, i) => {
          const on = i < n;
          const dup = on && fates[i] === 'dup';
          return (
            <div
              key={i}
              style={{
                fontFamily: mono,
                fontSize: 14,
                padding: '5px 11px',
                borderRadius: 7,
                border: `1px solid ${dup ? C.red : C.line}`,
                background: on
                  ? dup
                    ? 'var(--viz-fill-red)'
                    : 'var(--viz-fill)'
                  : 'transparent',
                color: on ? (dup ? C.red : C.accentText) : C.faint,
                textDecoration: dup ? 'line-through' : 'none',
                opacity: on ? 1 : 0.35,
                transition: 'all .3s',
              }}
            >
              {g}
            </div>
          );
        })}
      </div>

      <svg viewBox="0 0 420 96" style={{ width: '100%', maxWidth: 420 }}>
        <rect x="1" y="1" width="418" height="94" rx="10" fill="none" stroke={C.line} />
        <text x="14" y="22" fontSize="10" fill={C.faint} fontFamily={mono} letterSpacing="0.5">
          HashSet — distinct genomes
        </text>
        {seen.map((g, i) => (
          <g key={i} transform={`translate(${20 + i * 98}, 38)`}>
            <rect width="86" height="38" rx="7" fill="var(--viz-fill)" stroke={C.accent} />
            <text
              x="43"
              y="24"
              textAnchor="middle"
              fontSize="15"
              fontFamily={mono}
              fill={C.accentText}
            >
              {g}
            </text>
          </g>
        ))}
      </svg>

      <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginTop: 12 }}>
        <div style={{ fontFamily: mono, fontSize: 22, fontWeight: 600, color: C.accentText }}>
          size {size}
        </div>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(n + 1)} style={btn(C)}>
          {n >= ADDS.length ? '↻ Reset' : 'Add next ▸'}
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
