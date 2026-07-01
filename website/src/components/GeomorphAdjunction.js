import React from 'react';

/**
 * A geomorph is an adjunction between two sites. In the restaurant, the sala and
 * the cucina are two spaces, and what an Order is in the dining room corresponds
 * to what a Ticket is in the kitchen. The geomorph is the adjoint pair that carries
 * each side to the other: `push` sends an order to its ticket, `pull` brings a
 * ticket back to its order. The two are linked, `push` left-adjoint to `pull`.
 *
 * Static teaching figure. It draws the two spaces of the gated `restaurant` project
 * and the adjoint pair of `cucina/Line.yon`, which compiles (emit exit 0).
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-700, #4a4f57)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  sala: '#4f8ff7',
  salaT: '#2f6fd0',
  cucina: '#d99a2b',
  cucinaT: '#b5790f',
  push: '#1d9e75',
  pull: '#9b5de5',
};
const mono = 'var(--ifm-font-family-monospace)';

export default function GeomorphAdjunction() {
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 540, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 8 }}>
        <strong style={{ color: C.text }}>A geomorph is an adjunction between two sites.</strong> An
        Order in the sala corresponds to a Ticket in the cucina; the adjoint pair carries each to the
        other. <code>push</code> is left-adjoint to <code>pull</code>.
      </div>

      <svg viewBox="0 0 440 190" style={{ width: '100%', maxWidth: 440 }} fontFamily={mono}>
        {/* arrowheads */}
        <defs>
          <marker id="ah-push" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M0 0 L10 5 L0 10 z" fill={C.push} />
          </marker>
          <marker id="ah-pull" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M0 0 L10 5 L0 10 z" fill={C.pull} />
          </marker>
        </defs>

        {/* space frames */}
        <rect x="16" y="40" width="150" height="110" rx="10" fill="rgba(79,143,247,0.06)" stroke={C.sala} strokeWidth="1" />
        <text x="91" y="32" textAnchor="middle" fontSize="11" fill={C.salaT}>sala/ (a space)</text>
        <rect x="274" y="40" width="150" height="110" rx="10" fill="rgba(217,154,43,0.07)" stroke={C.cucina} strokeWidth="1" />
        <text x="349" y="32" textAnchor="middle" fontSize="11" fill={C.cucinaT}>cucina/ (a space)</text>

        {/* the two places */}
        <rect x="46" y="82" width="90" height="30" rx="6" fill="var(--ifm-background-color, #fff)" stroke={C.sala} strokeWidth="1.5" />
        <text x="91" y="101" textAnchor="middle" fontSize="12" fill={C.salaT}>Order</text>
        <rect x="304" y="82" width="90" height="30" rx="6" fill="var(--ifm-background-color, #fff)" stroke={C.cucina} strokeWidth="1.5" />
        <text x="349" y="101" textAnchor="middle" fontSize="12" fill={C.cucinaT}>Ticket</text>

        {/* push: Order -> Ticket (top curve) */}
        <path d="M138 82 C 200 52, 240 52, 302 82" fill="none" stroke={C.push} strokeWidth="2" markerEnd="url(#ah-push)" />
        <text x="220" y="52" textAnchor="middle" fontSize="11" fill={C.push}>push</text>

        {/* pull: Ticket -> Order (bottom curve) */}
        <path d="M302 112 C 240 142, 200 142, 138 112" fill="none" stroke={C.pull} strokeWidth="2" markerEnd="url(#ah-pull)" />
        <text x="220" y="150" textAnchor="middle" fontSize="11" fill={C.pull}>pull</text>

        {/* the adjunction symbol */}
        <text x="220" y="101" textAnchor="middle" fontSize="15" fill={C.faint}>push ⊣ pull</text>
      </svg>

      <div style={{ fontSize: 12, color: C.faint, textAlign: 'center', marginTop: 2 }}>
        Not one arrow but a linked pair: everything <code>push</code> carries into the kitchen,{' '}
        <code>pull</code> can bring back, and the adjunction is the law that keeps them consistent.
      </div>
    </div>
  );
}
