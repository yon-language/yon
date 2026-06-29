import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * HashMap — "tag each genome with a species id." A real Yon run
 * (regression/book/jp/uc_hashmap -> get(1445)=1, has(9999)=0, size=2).
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-400, #a0a4ab)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  accent: '#4f8ff7',
  accentText: '#2f6fd0',
  green: '#3fae6b',
  greenText: '#2f8a52',
  red: '#e0604d',
  redText: '#c0432f',
};
const mono = 'var(--ifm-font-family-monospace)';
const ROWS = [
  { k: 1445, v: 1, sp: 'Velociraptor' },
  { k: 1280, v: 2, sp: 'Tyrannosaurus' },
];
const QUERIES = [
  { k: 1445, hit: true },
  { k: 9999, hit: false },
];

export default function HashMapTag() {
  const { i, set, playing, setPlaying } = useAutoplay(QUERIES.length);
  const q = QUERIES[i];
  const row = ROWS.find((r) => r.k === q.k);

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 560,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>A tag for every genome.</strong> The map keys a species id
        by genome, any key type, O(1). A hit returns the tag; a miss returns nothing. Real run (
        <code>uc_hashmap</code> → <strong>1, 0, 2</strong>).
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 16 }}>
        {ROWS.map((r) => {
          const lit = q.hit && r.k === q.k;
          return (
            <div
              key={r.k}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 0,
                fontFamily: mono,
                fontSize: 14,
                border: `1px solid ${lit ? C.green : C.line}`,
                borderRadius: 8,
                overflow: 'hidden',
                background: lit ? 'rgba(63,174,107,0.08)' : 'transparent',
                transition: 'all .3s',
              }}
            >
              <div style={{ padding: '8px 14px', minWidth: 70, color: C.accentText }}>{r.k}</div>
              <div style={{ color: C.faint, padding: '0 6px' }}>→</div>
              <div style={{ padding: '8px 14px', color: lit ? C.greenText : C.text }}>{r.v}</div>
              <div style={{ flex: 1 }} />
              <div
                style={{
                  padding: '8px 14px',
                  fontFamily: 'var(--ifm-font-family-base)',
                  fontSize: 12.5,
                  color: C.sub,
                }}
              >
                {r.sp}
              </div>
            </div>
          );
        })}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <span style={{ fontFamily: mono, fontSize: 14 }}>
          get(<span style={{ color: C.accentText }}>{q.k}</span>)
        </span>
        <span style={{ color: C.faint }}>→</span>
        {q.hit ? (
          <span style={{ fontFamily: mono, fontSize: 16, fontWeight: 600, color: C.greenText }}>
            {row.v}
          </span>
        ) : (
          <span style={{ fontFamily: mono, fontSize: 14, color: C.redText }}>
            miss — not in the set
          </span>
        )}
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(i + 1)} style={btn(C)}>
          Next query ▸
        </button>
      </div>
      <div style={{ fontFamily: mono, fontSize: 12.5, color: C.sub, marginTop: 10 }}>size = 2</div>
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
