import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * XSet — "what do two paddocks share?" Each paddock is a 196,560-bit bitmap over the
 * lattice; intersect is a bit-AND, union a bit-OR. Real Yon run
 * (regression/book/jp/uc_b_sets -> |A|=3, |B|=3, |A∩B|=2, |A∪B|=4).
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
};
const mono = 'var(--ifm-font-family-monospace)';
const COLS = [7, 11, 63, 99]; // the lattice points used (uc_b_sets)
const A = [7, 11, 63];
const B = [11, 63, 99];

export default function XSetBitmap() {
  const { i, set, playing, setPlaying } = useAutoplay(2);
  const op = i === 0 ? 'and' : 'or'; // 'and' = intersect, 'or' = union
  const inA = (p) => A.includes(p);
  const inB = (p) => B.includes(p);
  const res = (p) => (op === 'and' ? inA(p) && inB(p) : inA(p) || inB(p));
  const count = COLS.filter(res).length; // 2 (and) / 4 (or)

  const cell = (on, color) => ({
    width: 30,
    height: 22,
    borderRadius: 5,
    border: `1px solid ${on ? color : C.line}`,
    background: on ? `${color}22` : 'transparent',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    fontFamily: mono,
    fontSize: 11,
    color: on ? color : C.faint,
  });
  const Row = ({ label, test, color }) => (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 5 }}>
      <div style={{ width: 92, fontSize: 12, color: C.sub, textAlign: 'right' }}>{label}</div>
      {COLS.map((p) => (
        <div key={p} style={cell(test(p), color)}>
          {test(p) ? '1' : '·'}
        </div>
      ))}
    </div>
  );

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 460,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>Set algebra is bit algebra.</strong> Each paddock is a
        bitmap over the lattice points; what they share is a bit-AND, all of them a bit-OR — one
        machine word at a time. Real run (<code>uc_b_sets</code> → <strong>3, 3, 2, 4</strong>).
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 8, marginLeft: 100 }}>
        {COLS.map((p) => (
          <div
            key={p}
            style={{
              width: 30,
              textAlign: 'center',
              fontFamily: mono,
              fontSize: 10,
              color: C.faint,
            }}
          >
            {p}
          </div>
        ))}
      </div>
      <Row label="paddock A" test={inA} color={C.accent} />
      <Row label="paddock B" test={inB} color={C.accent} />
      <div style={{ borderTop: `1px dashed ${C.line}`, margin: '8px 0 8px 100px' }} />
      <Row label={op === 'and' ? 'A ∩ B (AND)' : 'A ∪ B (OR)'} test={res} color={C.green} />

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 12 }}>
        <div style={{ fontFamily: mono, fontSize: 15, color: C.greenText }}>
          size = <strong>{count}</strong>
        </div>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(op === 'and' ? 1 : 0)} style={btn(C)}>
          {op === 'and' ? 'show ∪ union ▸' : 'show ∩ shared ▸'}
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
