import React from 'react';

/**
 * The subobject classifier Ω of chapter 8 has three citizens, not two: a fact can
 * be present, absent, or unknown, and `unknown` is a first-class value of the
 * Heyting core, never an error or a thrown exception. This draws the order
 * (present above unknown above absent) and the meet/join behaviour that makes
 * `unknown` propagate instead of crashing.
 *
 * Static teaching figure of the logic itself (min for `and`, max for `or`, the
 * order-reversal for `not`), the standard three-valued semantics Yon's Heyting
 * core computes. No measured run.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-700, #4a4f57)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  present: '#1d9e75',
  unknown: '#d99a2b',
  absent: 'var(--ifm-color-emphasis-600, #606770)',
};
const mono = 'var(--ifm-font-family-monospace)';

export default function HeytingOmega() {
  const nodes = [
    { y: 26, label: 'present', sym: '⊤', color: C.present, gloss: 'the fact holds' },
    { y: 96, label: 'unknown', sym: '?', color: C.unknown, gloss: 'a citizen, not an error' },
    { y: 166, label: 'absent', sym: '⊥', color: C.absent, gloss: 'the fact fails' },
  ];
  const cx = 120;
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 560, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 8 }}>
        <strong style={{ color: C.text }}>Ω has three citizens, not two.</strong> A fact is present,
        absent, or <strong style={{ color: C.unknown }}>unknown</strong>, and unknown is a value of the
        Heyting core, never a thrown error. It propagates.
      </div>
      <svg viewBox="0 0 540 210" style={{ width: '100%', maxWidth: 540 }} fontFamily={mono}>
        {/* the order lattice */}
        <line x1={cx} y1={40} x2={cx} y2={152} stroke={C.line} strokeWidth="1.5" />
        {nodes.map((n) => (
          <g key={n.label}>
            <circle cx={cx} cy={n.y} r="17" fill="var(--ifm-background-color, #fff)" stroke={n.color} strokeWidth="2" />
            <text x={cx} y={n.y + 5} textAnchor="middle" fontSize="15" fill={n.color}>{n.sym}</text>
            <text x={cx + 26} y={n.y - 1} fontSize="13" fill={n.color} fontWeight={600}>{n.label}</text>
            <text x={cx + 26} y={n.y + 13} fontSize="10.5" fill={C.faint} fontFamily="var(--ifm-font-family-base)">{n.gloss}</text>
          </g>
        ))}
        <text x={cx} y={16} textAnchor="middle" fontSize="9" fill={C.faint}>more true</text>

        {/* the propagation table */}
        <g fontFamily={mono} fontSize="11">
          <text x={300} y={30} fontSize="10.5" fill={C.sub} fontFamily="var(--ifm-font-family-base)" fontWeight={600}>
            unknown propagates:
          </text>
          {[
            ['unknown and present', '= unknown'],
            ['unknown and absent', '= absent'],
            ['unknown or present', '= present'],
            ['unknown or absent', '= unknown'],
            ['not unknown', '= unknown'],
          ].map(([lhs, rhs], k) => (
            <g key={k}>
              <text x={300} y={54 + k * 24} fill={C.sub}>{lhs}</text>
              <text x={470} y={54 + k * 24} fill={rhs.includes('unknown') ? C.unknown : C.text}>{rhs}</text>
            </g>
          ))}
        </g>
      </svg>
      <div style={{ fontSize: 12, color: C.faint, textAlign: 'center', marginTop: 2 }}>
        Where another language would throw on a missing fact, Yon returns <code>unknown</code> and keeps
        computing: <code>and</code> is the meet, <code>or</code> is the join, and unknown is carried, not raised.
      </div>
    </div>
  );
}
