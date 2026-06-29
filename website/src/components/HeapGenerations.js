import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';
import raw from '@site/src/data/bench-raw.json';

/**
 * "The heap that maps itself a generation at a time." The content-addressed (FNV) heap
 * holds one generation of 196,560 slots; distinct content past a generation chains into a
 * successor, so interning is unbounded. Identical content dedups to a single slot.
 *
 * HONESTY CONTRACT:
 *   - The per-intern nanoseconds are the REAL medians of regression/bench/heap_expand,
 *     read from website/src/data/bench-raw.json (written by regression/test_benchmarks.py
 *     on every gated run): distinct ~284 ns/intern (flat as it chains, amortized O(1)),
 *     identical content ~95 ns (dedup to one slot). Measured on an Apple M1.
 *   - 196,560 is the type-2 generation size (a theorem, not a tuning knob). The resident
 *     memory figures (8 MB same / 175 MB distinct for two million interns) are the
 *     /usr/bin/time -l measurement quoted in Appendix D. The generation blocks below are a
 *     schematic; the counts (ceil(interns / 196,560)) and the timings are real.
 */

const GEN = 196560;
const HE = (raw.heap_expand && raw.heap_expand.median) || [1000000, 210, 284, 95];
const NS_DISTINCT = HE[2];
const NS_SAME = HE[3];

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-400, #a0a4ab)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  accent: '#4f8ff7',
  accentText: '#2f6fd0',
  gold: '#d99a2b',
  goldText: '#b5790f',
  green: '#3fa45b',
  greenText: '#2f7d45',
};
const mono = 'var(--ifm-font-family-monospace)';

// states: three growing distinct-intern counts (filling + chaining generations), then
// the same-content collapse to one slot.
const STATES = [
  { mode: 'distinct', interns: 196560 },
  { mode: 'distinct', interns: 589680 },
  { mode: 'distinct', interns: 982800 },
  { mode: 'same', interns: 2000000 },
];
const NGEN = 5;

export default function HeapGenerations() {
  const { i, set, playing, setPlaying } = useAutoplay(STATES.length, 1900);
  const st = STATES[i];
  const same = st.mode === 'same';
  const gens = same ? 1 : Math.ceil(st.interns / GEN);
  const perIntern = same ? NS_SAME : NS_DISTINCT;
  const memMB = same ? 8 : Math.round((st.interns * 87) / 1e6);
  const lastFill = same ? 1 / GEN : (st.interns - (gens - 1) * GEN) / GEN;

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
        <strong style={{ color: C.text }}>One generation at a time.</strong> The
        content-addressed heap maps {GEN.toLocaleString()} slots per generation; distinct content
        chains into a new one when a generation fills, identical content dedups to a single slot.{' '}
        {same
          ? 'Two million identical interns cost one slot.'
          : `${st.interns.toLocaleString()} distinct interns fill ${gens} generation${gens > 1 ? 's' : ''}.`}{' '}
        Real run (<code>heap_expand</code>).
      </div>

      <svg viewBox="0 0 360 132" style={{ width: '100%', maxWidth: 360 }}>
        {Array.from({ length: NGEN }).map((_, g) => {
          const x = 8 + g * 70;
          const active = !same && g < gens;
          const fill = !same && g < gens ? (g === gens - 1 ? lastFill : 1) : 0;
          return (
            <g key={g} fontFamily={mono}>
              <rect
                x={x}
                y={20}
                width="62"
                height="46"
                rx="7"
                fill="transparent"
                stroke={active ? C.accent : C.line}
                strokeWidth={active ? 1 : 0.8}
                strokeDasharray={!same && g >= gens ? '3 3' : 'none'}
                style={{ transition: 'stroke 0.4s ease' }}
              />
              {/* fill level inside the generation */}
              <rect
                x={x + 3}
                y={63 - Math.round(40 * fill)}
                width="56"
                height={Math.round(40 * fill)}
                rx="3"
                fill="rgba(79,143,247,0.16)"
                style={{ transition: 'all 0.5s ease' }}
              />
              <text x={x + 31} y={15} textAnchor="middle" fontSize="8.5" fill={C.faint}>
                gen {g}
              </text>
              {/* chain arrow to the next active generation */}
              {!same && g < gens - 1 && (
                <path
                  d={`M${x + 62} 43 L${x + 70} 43`}
                  stroke={C.accent}
                  strokeWidth="1.5"
                  style={{ transition: 'stroke 0.4s ease' }}
                />
              )}
            </g>
          );
        })}

        {/* the single dedup slot, shown in the same-content state */}
        {same && (
          <g fontFamily={mono}>
            <rect x={8} y={28} width="16" height="16" rx="3" fill="rgba(63,164,91,0.22)" stroke={C.green} strokeWidth="1" />
            <text x={30} y={40} fontSize="10.5" fill={C.greenText}>
              one slot, every write deduplicated
            </text>
          </g>
        )}

        <text x={8} y={92} fontSize="13" fill={C.text} fontFamily={mono}>
          {perIntern} ns / intern
        </text>
        <text
          x={352}
          y={92}
          textAnchor="end"
          fontSize="13"
          fill={same ? C.greenText : C.accentText}
          fontFamily={mono}
        >
          {memMB} MB resident
        </text>
        <text x={8} y={112} fontSize="9.5" fill={C.faint} fontFamily="var(--ifm-font-family-base)">
          {same
            ? 'identical content: one address, no growth, no GC'
            : 'distinct content: ~flat per-intern as it chains (amortized O(1)), no GC'}
        </text>
        <text x={8} y={126} fontSize="9.5" fill={C.faint} fontFamily="var(--ifm-font-family-base)">
          {same ? '2,000,000 interns' : `${gens} generation${gens > 1 ? 's' : ''} mapped on demand`}
        </text>
      </svg>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 }}>
        <span style={{ fontFamily: mono, fontSize: 13, color: C.sub }}>
          {same ? 'same content' : `${st.interns.toLocaleString()} distinct`}
        </span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set((i + 1) % STATES.length)} style={btn(C)}>
          next &#9656;
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
