import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * List — "the descent chain." A functional cons-list: cons prepends the newest
 * generation, head is newest, tail the ancestors. Real run
 * (regression/book/jp/uc_list -> length 3, head 1445, parent 1280, founder 1207).
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
const CHAIN = [
  { g: 1445, role: 'head — newest hatchling' },
  { g: 1280, role: 'its parent' },
  { g: 1207, role: 'the founder' },
];

export default function DescentChain() {
  const { i, set, playing, setPlaying } = useAutoplay(2);
  const rev = i === 1;
  const nodes = rev ? [...CHAIN].reverse() : CHAIN;

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 600,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>A lineage you grow from the front.</strong>{' '}
        <code>cons</code> prepends the newest generation; <code>head</code> is the newest,{' '}
        <code>tail</code> the ancestors behind it. Real run (<code>uc_list</code> → length{' '}
        <strong>3</strong>, head <strong>1445</strong>).
      </div>

      <svg viewBox="0 0 520 86" style={{ width: '100%', maxWidth: 520 }}>
        {nodes.map((nd, i) => {
          const x = 12 + i * 168;
          const isHead = !rev && i === 0;
          const isFounder = nd.g === 1207;
          const col = isHead ? C.accent : isFounder ? C.gold : C.line;
          const txt = isHead ? C.accentText : isFounder ? C.goldText : C.text;
          return (
            <g key={nd.g} fontFamily={mono}>
              {i < nodes.length - 1 && (
                <g>
                  <line x1={x + 132} y1={40} x2={x + 162} y2={40} stroke={C.faint} />
                  <polygon points={`${x + 162},40 ${x + 154},36 ${x + 154},44`} fill={C.faint} />
                </g>
              )}
              <rect
                x={x}
                y={22}
                width="132"
                height="36"
                rx="8"
                fill={
                  isHead
                    ? 'rgba(79,143,247,0.10)'
                    : isFounder
                      ? 'rgba(217,154,43,0.10)'
                      : 'transparent'
                }
                stroke={col}
                strokeWidth={isHead ? 2 : 1}
              />
              <text x={x + 66} y={45} textAnchor="middle" fontSize="16" fill={txt}>
                {nd.g}
              </text>
              <text
                x={x + 66}
                y={74}
                textAnchor="middle"
                fontSize="9.5"
                fontFamily="var(--ifm-font-family-base)"
                fill={C.faint}
              >
                {nd.role.split(' — ')[0]}
              </text>
            </g>
          );
        })}
      </svg>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 }}>
        <span style={{ fontFamily: mono, fontSize: 13, color: C.sub }}>
          {rev ? 'reverse → founder-first' : 'cons order → newest-first'}
        </span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(rev ? 0 : 1)} style={btn(C)}>
          {rev ? '↩ cons order' : '⇄ reverse'}
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
