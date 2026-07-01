import React from 'react';

/**
 * The filesystem IS the category. A Yon project on disk maps one-to-one onto the
 * categorical structure: the world is the yon.toml declaration, a space is a
 * directory, a place is a file, and each arrow is a file that names a morphism.
 * This is the restaurant of chapter 7, shown as it actually sits on disk.
 *
 * Static teaching figure, no measured data: it draws the file tree of the gated
 * `restaurant` project and reads each node categorically. Every file shown is a
 * real file of a project that compiles (yoner_emit_mlir exit 0).
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-700, #4a4f57)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  dir: '#4f8ff7',
  file: '#1d9e75',
  toml: '#d99a2b',
  arrow: '#9b5de5',
};
const mono = 'var(--ifm-font-family-monospace)';

// [indent, glyph, name, kindColor, reading]
const ROWS = [
  [0, '', 'restaurant/', C.sub, 'the project'],
  [1, '├─', 'yon.toml', C.toml, 'the WORLD: [world.Restaurant], its objects and spaces, declared once'],
  [1, '├─', 'Entry.yon', C.file, 'the entry place: holds main'],
  [1, '├─', 'sala/', C.dir, 'a SPACE: the dining room, a directory, a category'],
  [2, '│  ├─', 'Order.yon', C.file, 'a PLACE: one order, a file, an object of the world'],
  [2, '│  ├─', 'Bill.yon', C.arrow, 'a VIEW: observe an order, read-only'],
  [2, '│  ├─', 'ToKitchen.yon', C.arrow, 'a MOVE: carry the order across to the kitchen'],
  [2, '│  └─', 'Tally.yon', C.arrow, 'a REDUCTION: what the order’s operations mean'],
  [1, '└─', 'cucina/', C.dir, 'a SPACE: the kitchen line, a second directory'],
  [2, '   ├─', 'Ticket.yon', C.file, 'a PLACE: the kitchen copy of the order'],
  [2, '   └─', 'Line.yon', C.arrow, 'a GEOMORPH: the adjunction that links sala and cucina'],
];

export default function ProjectStructure() {
  const rowH = 26;
  const H = 24 + ROWS.length * rowH;
  const midX = 210;
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 620, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 10 }}>
        <strong style={{ color: C.text }}>The filesystem is the category.</strong> A world is a{' '}
        <code>yon.toml</code> declaration, a space is a directory, a place is a file, and each arrow is a
        file that names a morphism. The restaurant, as it sits on disk.
      </div>
      <svg viewBox={`0 0 620 ${H}`} style={{ width: '100%' }} fontFamily={mono}>
        {ROWS.map(([indent, glyph, name, color, reading], k) => {
          const y = 18 + k * rowH;
          return (
            <g key={name}>
              <text x={8 + indent * 4} y={y + 4} fontSize="12.5" fill={C.faint}>{glyph}</text>
              <text x={8 + indent * 4 + 22} y={y + 4} fontSize="12.5" fill={color} fontWeight={indent < 2 ? 600 : 500}>
                {name}
              </text>
              <line x1={midX} y1={y} x2={midX + 12} y2={y} stroke={C.line} strokeWidth="1" />
              <text x={midX + 18} y={y + 4} fontSize="10.5" fill={C.sub} fontFamily="var(--ifm-font-family-base)">
                {reading}
              </text>
            </g>
          );
        })}
      </svg>
      <div style={{ fontSize: 12, color: C.faint, textAlign: 'center', marginTop: 2 }}>
        No inline <code>world &#123;&#125;</code> block, no <code>place X in W</code>: the layout carries the
        structure, and the compiler reads it back.
      </div>
    </div>
  );
}
