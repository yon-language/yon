import React from 'react';

/**
 * The content-addressed heap of chapter 12: a value's address is its content. On
 * allocation the bytes are hashed (FNV-1a) and a collision is settled by a direct
 * byte compare, so identical content returns the existing slot and distinct
 * content never aliases. Two equal strings are one slot, however they were built,
 * and equality becomes one integer comparison on the address: O(1), by construction.
 *
 * Static teaching figure. The dedup and the O(1)-equality claim are the measured
 * behaviour of Appendix D (String.equal is flat at about 1 ns from 1 to 32,768
 * characters); this only draws the mechanism.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-700, #4a4f57)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  same: '#1d9e75',
  other: '#4f8ff7',
  slot: 'var(--ifm-color-emphasis-200, #ebedf0)',
};
const mono = 'var(--ifm-font-family-monospace)';

export default function ContentAddress() {
  // three literals: two identical, one distinct
  const lits = [
    { label: '"ciao"', y: 30, slot: 0, color: C.same },
    { label: '"ciao"', y: 74, slot: 0, color: C.same },
    { label: '"mondo"', y: 118, slot: 1, color: C.other },
  ];
  const slots = [
    { y: 52, label: 'slot 0x1f', body: '"ciao"', color: C.same },
    { y: 118, label: 'slot 0x40', body: '"mondo"', color: C.other },
  ];
  const litX = 92, slotX = 300;
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 560, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 8 }}>
        <strong style={{ color: C.text }}>The address of a value is its content.</strong> Allocation
        hashes the bytes; identical content returns the existing slot. Two equal strings are one slot,
        so <strong>same content means same slot</strong>.
      </div>
      <svg viewBox="0 0 540 168" style={{ width: '100%', maxWidth: 540 }} fontFamily={mono}>
        {/* literals */}
        {lits.map((l, k) => (
          <g key={k}>
            <rect x={litX - 44} y={l.y - 13} width="88" height="26" rx="5" fill="var(--ifm-background-color, #fff)" stroke={l.color} strokeWidth="1.4" />
            <text x={litX} y={l.y + 4} textAnchor="middle" fontSize="12" fill={l.color}>{l.label}</text>
            {/* hash arrow to its slot */}
            <line x1={litX + 46} y1={l.y} x2={slotX - 60} y2={slots[l.slot].y}
                  stroke={l.color} strokeWidth="1.4" markerEnd="url(#ca-head)" opacity="0.85" />
          </g>
        ))}
        <defs>
          <marker id="ca-head" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
            <path d="M0 0 L10 5 L0 10 z" fill={C.faint} />
          </marker>
        </defs>
        <text x={litX} y={150} textAnchor="middle" fontSize="9" fill={C.faint} fontFamily="var(--ifm-font-family-base)">three literals</text>
        <text x={200} y={12} textAnchor="middle" fontSize="9.5" fill={C.faint} fontFamily="var(--ifm-font-family-base)">FNV-1a + byte compare</text>

        {/* slots */}
        {slots.map((s, k) => (
          <g key={k}>
            <rect x={slotX - 58} y={s.y - 15} width="150" height="30" rx="5" fill={C.slot} stroke={s.color} strokeWidth="1.4" />
            <text x={slotX - 50} y={s.y - 3} fontSize="8.5" fill={C.faint}>{s.label}</text>
            <text x={slotX - 50} y={s.y + 10} fontSize="11" fill={s.color}>{s.body}</text>
          </g>
        ))}
        <text x={slotX + 16} y={150} textAnchor="middle" fontSize="9" fill={C.faint} fontFamily="var(--ifm-font-family-base)">two slots (the heap)</text>
      </svg>
      <div style={{ fontSize: 12, color: C.faint, textAlign: 'center', marginTop: 2 }}>
        Equality of two values is then one integer test on the address, not a walk over the bytes:
        <strong style={{ color: C.same }}> O(1) structural equality</strong>, the same at 1 byte or 32 KB.
      </div>
    </div>
  );
}
