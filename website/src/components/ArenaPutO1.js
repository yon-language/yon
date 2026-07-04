import React from 'react';

/**
 * "The 31 µs was a measurement artifact, named and removed." Arena.put is a
 * perfect-hash index plus four slot writes: O(1) in the fill. An earlier run read
 * ~31 µs and looked super-linear; two stacked method faults (a non-twin baseline,
 * and a one-time 200 ms mmgroup init smeared over a small N) made a flat cost look
 * like a curve. Measured in-process against an exact Leech.point twin, with
 * min-over-reps to drop the init, it is flat.
 *
 * HONESTY CONTRACT:
 *   - The four per-op figures are the real gated numbers in regression/bench/arena_ops
 *     (Apple M1): 65, 75, 79, 81 ns at N = 2k, 5k, 10k, 20k. The 31 µs is the earlier
 *     artifact, shown ghosted to make the correction visible, not a current reading.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  ok: 'var(--viz-green)',
  okT: 'var(--viz-green)',
  ghost: 'var(--ifm-color-emphasis-400, #a0a4ab)',
};
const mono = 'var(--ifm-font-family-monospace)';

const N = ['2,000', '5,000', '10,000', '20,000'];
const NS = [65, 75, 79, 81];

export default function ArenaPutO1() {
  const X0 = 60, X1 = 250, top = 26, rowH = 24;
  const scale = 150; // ns -> px, so ~80ns is a modest bar; the artifact is off the chart
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 460, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 8 }}>
        <strong style={{ color: C.text }}>O(1), and the number that said otherwise.</strong>{' '}
        <code>Arena.put</code> is flat in the fill: a perfect-hash index and four writes, no resize, no
        probing. Apple M1 (<code>arena_ops</code>).
      </div>

      <svg viewBox={`0 0 300 ${top + N.length * rowH + 26}`} style={{ width: '100%', maxWidth: 360 }} fontFamily={mono}>
        {/* the ghosted artifact band */}
        <rect x={X0} y={6} width={X1 - X0 + 34} height={N.length * rowH + 8} rx="5" fill="none" stroke={C.rail} strokeWidth="1" />
        <text x={X1 + 30} y={16} textAnchor="end" fontSize="8" fill={C.ghost}>
          earlier artifact: ~31 µs (a non-twin baseline + one-time init, removed)
        </text>

        {N.map((n, k) => {
          const y = top + k * rowH;
          const w = Math.max((NS[k] / 1000) * scale + 24, 26);
          return (
            <g key={n}>
              <text x={X0 - 6} y={y + rowH / 2 + 1} textAnchor="end" fontSize="9" fill={C.sub}>N = {n}</text>
              <rect x={X0} y={y + 3} width={w} height={rowH - 8} rx="3" fill={C.ok} />
              <text x={X0 + w + 5} y={y + rowH / 2 + 1} fontSize="9" fill={C.okT}>{NS[k]} ns</text>
            </g>
          );
        })}

        <text x={X0} y={top + N.length * rowH + 16} fontSize="9.5" fill={C.faint}>
          flat ~80 ns across a 10× range of fill: constant, not a curve
        </text>
      </svg>
    </div>
  );
}
