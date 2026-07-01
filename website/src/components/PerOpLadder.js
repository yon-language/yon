import React from 'react';

/**
 * "The gaps are the proof." Every per-operation cost on one log axis, cheapest to
 * dearest. The interesting thing is not any single bar but the distances: Arena.get
 * to Arena.same_orbit is the M24 orbit recomputation, made visible; the heap-cons
 * ops (List.cons, HashMap.set) sit above the inline ops (Vec.push, HashSet.add) by
 * exactly the content-addressing price they pay for structural sharing.
 *
 * HONESTY CONTRACT:
 *   - Every nanosecond is the real per-op figure from Appendix D, measured on an
 *     Apple M1 (regression/bench_perf + the in-process regression/bench/arena_ops,
 *     ds_ops, eq_constant twins). The five sub-nanosecond ops are marked "below
 *     floor": the subprocess harness cannot resolve them, and the suite says so
 *     rather than printing noise; the in-process eq_constant gate resolves equality
 *     at ~1 ns. Nothing here is invented or rounded up.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  grid: 'var(--ifm-color-emphasis-200, #ebedf0)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  fast: '#1d9e75',
  mid: '#4f8ff7',
  heavy: '#d99a2b',
};
const mono = 'var(--ifm-font-family-monospace)';

// (op, ns, kind). floor = below the subprocess harness floor (sub-ns), shown at the rail.
const OPS = [
  ['String.equal (1 or 32,768 chars)', 1, 'floor'],
  ['MerkleTree.equal', 0.6, 'floor'],
  ['VoyagerList.seal', 0.6, 'floor'],
  ['Vec.push', 0.7, 'floor'],
  ['Vec.get', 1.4, 'fast'],
  ['HashSet.contains', 6, 'fast'],
  ['HashMap.get', 7, 'fast'],
  ['List.head', 8, 'fast'],
  ['VoyagerList.open (Golay decode)', 10, 'fast'],
  ['Arena.get (lattice address)', 41, 'mid'],
  ['HashSet.add', 69, 'mid'],
  ['List.cons (hash-cons)', 70, 'mid'],
  ['Arena.put (certified, O(1))', 80, 'mid'],
  ['MerkleTree.node2 (dedup hit)', 138, 'heavy'],
  ['HashMap.set (grows with map)', 340, 'heavy'],
  ['Arena.same_orbit (M24 relation)', 1170, 'heavy'],
];

const X0 = 176, X1 = 344; // bar area
const lo = Math.log10(0.5), hi = Math.log10(1200);
const bx = (ns) => X0 + ((Math.log10(Math.max(ns, 0.5)) - lo) / (hi - lo)) * (X1 - X0);
const col = (k) => (k === 'heavy' ? C.heavy : k === 'mid' ? C.mid : C.fast);
const fmt = (ns) => (ns >= 1000 ? `${(ns / 1000).toFixed(2)} µs` : ns < 1 ? '<1 ns' : `${ns} ns`);

export default function PerOpLadder() {
  const rowH = 11.2;
  const H = 24 + OPS.length * rowH;
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 560, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 8 }}>
        <strong style={{ color: C.text }}>Per-operation cost, cheapest to dearest.</strong> Log axis, so
        each gap is a ratio. The jump from <code>Arena.get</code> to <code>Arena.same_orbit</code> is the
        M24 orbit recomputation; the hash-cons ops sit one step above the inline ops by the sharing price
        they pay. Apple M1.
      </div>

      <svg viewBox={`0 0 360 ${H}`} style={{ width: '100%', maxWidth: 460 }} fontFamily={mono}>
        {/* x gridlines: 1ns, 10ns, 100ns, 1us */}
        {[[1, '1 ns'], [10, '10 ns'], [100, '100 ns'], [1000, '1 µs']].map(([ns, lbl]) => (
          <g key={ns}>
            <line x1={bx(ns)} y1={16} x2={bx(ns)} y2={H - 6} stroke={C.grid} strokeWidth="1" />
            <text x={bx(ns)} y={12} textAnchor="middle" fontSize="7.5" fill={C.faint}>{lbl}</text>
          </g>
        ))}

        {OPS.map(([op, ns, kind], k) => {
          const y = 20 + k * rowH;
          const floor = kind === 'floor';
          return (
            <g key={op}>
              <text x={X0 - 6} y={y + rowH / 2 + 1} textAnchor="end" fontSize="8" fill={C.sub}>{op}</text>
              {floor ? (
                <g>
                  <rect x={X0} y={y + 1.5} width={bx(1) - X0} height={rowH - 3.5} rx="2" fill={C.rail} />
                  <text x={bx(1) + 4} y={y + rowH / 2 + 1.5} fontSize="7.5" fill={C.faint}>below floor (sub-ns)</text>
                </g>
              ) : (
                <g>
                  <rect x={X0} y={y + 1.5} width={Math.max(bx(ns) - X0, 1.5)} height={rowH - 3.5} rx="2" fill={col(kind)} />
                  <text x={Math.max(bx(ns), X0) + 4} y={y + rowH / 2 + 1.5} fontSize="7.5" fill={C.sub}>{fmt(ns)}</text>
                </g>
              )}
            </g>
          );
        })}
      </svg>
    </div>
  );
}
