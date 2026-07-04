import React, { useEffect, useState } from 'react';
import trace from '@site/src/data/jp-traces/mutation.json';

/**
 * "The mutation." Golay (24,12,8) corrects up to 3 flipped bits. Past the radius it
 * does not error: it either DETECTS (returns a refuse-to-guess flag) or, worse,
 * SILENTLY decodes to a different valid gene. Real Yon output
 * (regression/book/jp/11_mutation): gene 1445, open(corrupt(cw, k)) for k=1..6 =
 * 1445,1445,1445, FLAG, 2361, FLAG. The silent one (k=5 -> 2361) is the mutation
 * that gets into the park. Genes are illustrative numbers.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  border: 'var(--ifm-color-emphasis-300, #dadde1)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  good: 'var(--viz-green)',
  goodT: 'var(--viz-green)',
  det: 'var(--viz-gold)',
  detT: 'var(--viz-gold)',
  mut: 'var(--viz-red)',
  mutT: 'var(--viz-red)',
};
const COL = { corrected: [C.good, C.goodT], detected: [C.det, C.detT], mutated: [C.mut, C.mutT] };
const STEPS = trace.steps;
const label = (s) =>
  s.kind === 'corrected'
    ? `recovered ${trace.gene}`
    : s.kind === 'detected'
      ? 'detected — refused'
      : `mutated → ${s.out}`;

export default function Mutation() {
  const [i, setI] = useState(0);
  const [playing, setPlaying] = useState(true);

  useEffect(() => {
    if (!playing) return undefined;
    if (i >= STEPS.length - 1) {
      setPlaying(false);
      return undefined;
    }
    const t = setTimeout(() => setI((x) => x + 1), 1600);
    return () => clearTimeout(t);
  }, [playing, i]);

  const s = STEPS[i];
  const [bg, fg] = COL[s.kind];

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 680,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>The mutation.</strong> Gene <code>{trace.gene}</code>,
        sealed in a Golay codeword, opened back through <code>k</code> flipped bits (
        <code>{trace.source}</code>). Up to the radius ({trace.radius}) it heals. Past it, the
        correction either <strong style={{ color: C.detT }}>detects</strong> and refuses, or{' '}
        <strong style={{ color: C.mutT }}>silently mutates</strong> to a different valid gene.
      </div>

      {/* the k strip */}
      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        {STEPS.map((st, k) => {
          const [b] = COL[st.kind];
          const on = k === i;
          return (
            <button
              key={k}
              onClick={() => {
                setPlaying(false);
                setI(k);
              }}
              style={{
                flex: 1,
                padding: '8px 0',
                borderRadius: 8,
                cursor: 'pointer',
                border: `1.5px solid ${on ? b : C.border}`,
                background: on ? b : 'transparent',
                color: on ? '#fff' : C.sub,
                fontFamily: 'var(--ifm-font-family-base)',
                fontSize: 12,
                fontWeight: on ? 700 : 500,
                transition: 'all .2s',
              }}
            >
              {st.k} bit{st.k > 1 ? 's' : ''}
            </button>
          );
        })}
      </div>

      {/* focused result */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 20,
          padding: '16px 18px',
          borderRadius: 10,
          background: `${bg}14`,
          border: `1px solid ${bg}55`,
        }}
      >
        <div style={{ flexShrink: 0 }}>
          <div
            style={{
              fontSize: 10.5,
              textTransform: 'uppercase',
              letterSpacing: '.05em',
              color: C.faint,
            }}
          >
            {trace.gene} ↦ codeword ↦ {s.k} flipped ↦ open
          </div>
          <div
            style={{
              fontFamily: 'var(--ifm-font-family-monospace)',
              fontWeight: 700,
              fontSize: 'clamp(26px, 6vw, 40px)',
              lineHeight: 1.1,
              color: fg,
            }}
          >
            {s.kind === 'detected' ? 'FLAG' : s.out}
          </div>
        </div>
        <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5 }}>
          <strong style={{ color: fg }}>{label(s)}.</strong>{' '}
          {s.kind === 'corrected' && 'Inside the radius: the net holds, the gene returns whole.'}
          {s.kind === 'detected' &&
            'Past the radius, but the system knows it is corrupt and will not guess. A loud failure — you are warned.'}
          {s.kind === 'mutated' &&
            'Past the radius, and no flag: a different but lawful gene, handed back as if nothing happened. The silent failure — the one that gets into the park.'}
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 14 }}>
        <button
          onClick={() => {
            if (i >= STEPS.length - 1) setI(0);
            setPlaying((p) => !p);
          }}
          style={btn(C)}
        >
          {playing ? '⏸ Pause' : i >= STEPS.length - 1 ? '↻ Replay' : '⏵ Play'}
        </button>
        <span style={{ fontSize: 11.5, color: C.faint }}>
          ≤{trace.radius} corrected · {trace.radius + 1} & {trace.radius + 3} detected ·{' '}
          {trace.radius + 2} silently mutated to {trace.mutant}
        </span>
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
    border: `0.5px solid ${c.border}`,
    background: 'transparent',
    color: c.text,
    cursor: 'pointer',
  };
}
