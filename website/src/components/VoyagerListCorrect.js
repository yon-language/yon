import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';

/**
 * VoyagerList — a list whose every element is sealed in a Golay codeword and
 * auto-corrected on read. Corrupt three bits of an element and `get` still returns
 * the original. Real Yon run (regression/book/jp/uc_golay -> get(0) = 1445 after
 * corrupt_at(0, 3)). Distinct from the 2.2 codeword view: here the unit is the LIST.
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
  bad: '#e0604d',
  badText: '#c0432f',
};
const mono = 'var(--ifm-font-family-monospace)';
const GENES = [1445, 1280, 2361]; // a VoyagerList of genes, each sealed

export default function VoyagerListCorrect() {
  const { i, set, playing, setPlaying } = useAutoplay(2);
  const damaged = i % 2 === 0; // element 0 corrupted by 3 bits

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
        <strong style={{ color: C.text }}>A list that heals on read.</strong> Every element is
        sealed in a Golay codeword; flip up to three bits of one and <code>get</code> still returns
        it whole — the correction is per element, on access. Real run (<code>uc_golay</code> →{' '}
        <strong>1445</strong>).
      </div>

      <svg viewBox="0 0 480 96" style={{ width: '100%', maxWidth: 480 }}>
        {GENES.map((g, i) => {
          const x = 12 + i * 156;
          const hit = i === 0 && damaged;
          return (
            <g key={i} fontFamily={mono}>
              <text x={x + 70} y={14} textAnchor="middle" fontSize="10" fill={C.faint}>
                index {i}
              </text>
              <rect
                x={x}
                y={22}
                width="140"
                height="40"
                rx="8"
                fill={hit ? 'rgba(224,96,77,0.08)' : 'rgba(79,143,247,0.06)'}
                stroke={hit ? C.bad : C.accent}
                strokeWidth={hit ? 2 : 1}
              />
              {/* 8-bit damage strip to suggest the sealed codeword */}
              {[...Array(8)].map((_, b) => (
                <rect
                  key={b}
                  x={x + 10 + b * 15}
                  y={30}
                  width="11"
                  height="7"
                  rx="1.5"
                  fill={hit && (b === 1 || b === 4 || b === 6) ? C.bad : C.accent}
                  opacity={hit && (b === 1 || b === 4 || b === 6) ? 0.9 : 0.28}
                />
              ))}
              <text
                x={x + 70}
                y={54}
                textAnchor="middle"
                fontSize="15"
                fill={hit ? C.badText : C.accentText}
              >
                {g}
              </text>
              {hit && (
                <text
                  x={x + 70}
                  y={80}
                  textAnchor="middle"
                  fontSize="9.5"
                  fontFamily="var(--ifm-font-family-base)"
                  fill={C.badText}
                >
                  3 bits flipped
                </text>
              )}
            </g>
          );
        })}
      </svg>

      <div
        style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 8, flexWrap: 'wrap' }}
      >
        <span style={{ fontFamily: mono, fontSize: 14 }}>
          get(list, 0) → <strong style={{ color: C.greenText }}>1445</strong>
        </span>
        <span style={{ fontSize: 12, color: C.sub }}>
          {damaged ? 'decoded to the nearest legal codeword' : 'undamaged'}
        </span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set(damaged ? 1 : 0)} style={btn(C)}>
          {damaged ? '↩ heal' : 'corrupt 3 bits ▸'}
        </button>
      </div>
      <div style={{ fontSize: 11, color: C.faint, lineHeight: 1.5, marginTop: 10 }}>
        Inside the radius of three, recovery is certain. Past three the list decodes to a different
        legal gene, silently — the mutation of the chapter before. The list is safe only inside the
        radius.
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
