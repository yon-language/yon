import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * MerkleTree — "are two pedigrees identical, by content?" Two trees built from the
 * same leaves are equal; one differing leaf breaks it. Real run
 * (regression/book/jp/uc_merkle -> equal(t1,t2)=1, equal(t1,t3)=0).
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

const T1 = { leaves: [1445, 1280] };
const PAIRS = [
  { name: 't2', leaves: [1445, 1280], equal: true },
  { name: 't3', leaves: [1445, 9999], equal: false },
];

function Tree({ leaves, diffIdx, x }) {
  const rootX = x + 60,
    rootY = 26;
  const lx = [x + 22, x + 98],
    ly = 82;
  return (
    <g fontFamily={mono}>
      <line x1={rootX} y1={rootY + 14} x2={lx[0]} y2={ly - 14} stroke={C.line} />
      <line x1={rootX} y1={rootY + 14} x2={lx[1]} y2={ly - 14} stroke={C.line} />
      <g transform={`translate(${rootX - 26}, ${rootY - 13})`}>
        <rect width="52" height="26" rx="6" fill="rgba(79,143,247,0.10)" stroke={C.accent} />
        <text x="26" y="17" textAnchor="middle" fontSize="11" fill={C.accentText}>
          node2
        </text>
      </g>
      {leaves.map((g, i) => {
        const diff = i === diffIdx;
        return (
          <g key={i} transform={`translate(${lx[i] - 26}, ${ly - 13})`}>
            <rect
              width="52"
              height="26"
              rx="6"
              fill={diff ? 'rgba(224,96,77,0.10)' : 'transparent'}
              stroke={diff ? C.red : C.line}
            />
            <text x="26" y="17" textAnchor="middle" fontSize="12" fill={diff ? C.redText : C.text}>
              {g}
            </text>
          </g>
        );
      })}
    </g>
  );
}

export default function MerklePedigree() {
  const { i, set, playing, setPlaying } = useAutoplay(PAIRS.length);
  const other = PAIRS[i];
  const diffIdx = other.leaves.findIndex((g, k) => g !== T1.leaves[k]);

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 560,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 12 }}>
        <strong style={{ color: C.text }}>Equal by content, not by pointer.</strong> Two descent
        trees with the same leaves hash to the same value; one changed leaf breaks it. Real run (
        <code>uc_merkle</code> → <strong>1, 0</strong>).
      </div>

      <svg viewBox="0 0 360 110" style={{ width: '100%', maxWidth: 360 }}>
        <Tree leaves={T1.leaves} diffIdx={-1} x={10} />
        <text
          x="180"
          y="58"
          textAnchor="middle"
          fontSize="20"
          fill={other.equal ? C.greenText : C.redText}
        >
          {other.equal ? '=' : '≠'}
        </text>
        <Tree leaves={other.leaves} diffIdx={diffIdx} x={200} />
        <text x="70" y="105" textAnchor="middle" fontSize="10" fill={C.faint} fontFamily={mono}>
          t1
        </text>
        <text x="260" y="105" textAnchor="middle" fontSize="10" fill={C.faint} fontFamily={mono}>
          {other.name}
        </text>
      </svg>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 10 }}>
        <span style={{ fontFamily: mono, fontSize: 14 }}>
          equal(t1, {other.name}) →{' '}
          <strong style={{ color: other.equal ? C.greenText : C.redText }}>
            {other.equal ? 1 : 0}
          </strong>
        </span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(i + 1)} style={btn(C)}>
          Compare ▸
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
