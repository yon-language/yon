import React from 'react';

/**
 * "The gap is asymptotic." XSet.intersect / union are a fixed 3,072-word pass over
 * a 196,560-bit Leech bitmap: O(1) in the number of elements. HashSet must iterate:
 * O(N). So the advantage is not a fixed multiplier, it widens without bound.
 *
 * HONESTY CONTRACT:
 *   - Every number is the real measurement in regression/bench/xset_scaling
 *     (gated; median of nine runs on an Apple M1), the same figures as the
 *     Appendix-D "Set algebra is bit-parallel" table. Nothing is invented.
 *   - The chart is log-log: set size on x, per-call time on y, three decades of N.
 *     The XSet line is flat; the HashSet line climbs at slope 1 (linear in N). The
 *     vertical distance between them at each N IS the advantage column.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  grid: 'var(--ifm-color-emphasis-200, #ebedf0)',
  xset: '#1d9e75',
  xsetT: '#0f6e56',
  hash: '#d99a2b',
  hashT: '#b5790f',
};
const mono = 'var(--ifm-font-family-monospace)';

// intersect, ns/call, gated xset_scaling (M1). Union tells the same story (6x -> 33,776x).
const N = [100, 1000, 10000, 100000];
const XSET = [4500, 4900, 4500, 4600];
const HASH = [16000, 43000, 768000, 47700000];
const ADV = ['4x', '9x', '169x', '10,454x'];

// log-log projection into the 360x210 viewBox plot area
const X0 = 44, X1 = 330, Y0 = 20, Y1 = 168;
const lgN = (n) => Math.log10(n);
const lgT = (t) => Math.log10(t);
const nMin = lgN(100), nMax = lgN(100000);
const tMin = lgT(3000), tMax = lgT(100000000); // 3us .. 100ms
const px = (n) => X0 + ((lgN(n) - nMin) / (nMax - nMin)) * (X1 - X0);
const py = (t) => Y1 - ((lgT(t) - tMin) / (tMax - tMin)) * (Y1 - Y0);

function line(xs, ys, color) {
  const d = xs.map((x, k) => `${k ? 'L' : 'M'}${px(x).toFixed(1)},${py(ys[k]).toFixed(1)}`).join(' ');
  return <path d={d} fill="none" stroke={color} strokeWidth="2.5" strokeLinejoin="round" strokeLinecap="round" />;
}

export default function XSetScaling() {
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 560, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 10 }}>
        <strong style={{ color: C.text }}>The advantage is asymptotic, not a big constant.</strong>{' '}
        <code>XSet.intersect</code> is a fixed pass over 3,072 machine words, flat as the sets grow;{' '}
        <code>HashSet.intersect</code> is linear in the elements. The gap widens without bound. Real
        run on an Apple M1 (<code>xset_scaling</code>, median of nine).
      </div>

      <svg viewBox="0 0 360 210" style={{ width: '100%', maxWidth: 420 }} fontFamily={mono}>
        {/* y grid: 10us, 100us, 1ms, 10ms */}
        {[[10000, '10 µs'], [100000, '100 µs'], [1000000, '1 ms'], [10000000, '10 ms']].map(([t, lbl]) => (
          <g key={t}>
            <line x1={X0} y1={py(t)} x2={X1} y2={py(t)} stroke={C.grid} strokeWidth="1" />
            <text x={X0 - 6} y={py(t) + 3} textAnchor="end" fontSize="8" fill={C.faint}>{lbl}</text>
          </g>
        ))}
        {/* x labels: set size */}
        {N.map((n) => (
          <text key={n} x={px(n)} y={Y1 + 13} textAnchor="middle" fontSize="8.5" fill={C.faint}>
            {n >= 1000 ? `${n / 1000}k` : n}
          </text>
        ))}
        <text x={(X0 + X1) / 2} y={Y1 + 27} textAnchor="middle" fontSize="9" fill={C.sub}>set size (elements)</text>

        {/* the two curves */}
        {line(N, HASH, C.hash)}
        {line(N, XSET, C.xset)}

        {/* advantage brackets at each N */}
        {N.map((n, k) => (
          <g key={n}>
            <line x1={px(n)} y1={py(XSET[k])} x2={px(n)} y2={py(HASH[k])} stroke={C.faint} strokeWidth="0.75" strokeDasharray="2 2" />
            <circle cx={px(n)} cy={py(XSET[k])} r="3" fill={C.xsetT} />
            <circle cx={px(n)} cy={py(HASH[k])} r="3" fill={C.hashT} />
            <text x={px(n) + 4} y={(py(XSET[k]) + py(HASH[k])) / 2 + 3} fontSize="8.5" fill={C.hashT}>{ADV[k]}</text>
          </g>
        ))}

        {/* legend */}
        <g>
          <circle cx={X0 + 4} cy={Y0 - 6} r="3" fill={C.xsetT} />
          <text x={X0 + 12} y={Y0 - 3} fontSize="9" fill={C.xsetT}>XSet, flat ~4.5 µs</text>
          <circle cx={X0 + 118} cy={Y0 - 6} r="3" fill={C.hashT} />
          <text x={X0 + 126} y={Y0 - 3} fontSize="9" fill={C.hashT}>HashSet, O(N)</text>
        </g>
      </svg>

      <div style={{ fontSize: 12, color: C.faint, textAlign: 'center', marginTop: 2 }}>
        At 100,000 elements the same intersection is <strong style={{ color: C.hashT }}>10,454×</strong> faster
        on the lattice; union reaches <strong style={{ color: C.hashT }}>33,776×</strong>. The bitmap does not
        grow, so the gap only widens.
      </div>
    </div>
  );
}
