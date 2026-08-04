import React from 'react';

/**
 * The Rosetta of chapter 6: Yon's data model is categorical, and the category
 * lives on disk. Three columns, one row per level: the categorical notion, the
 * Yon word for it, and the thing it is on the filesystem. None of world / space
 * / place is a surface keyword; the project layout carries the structure.
 *
 * Static teaching figure, no measured data. The disk column is the restaurant
 * project of chapters 6 and 7, which compiles (yonc exit 0).
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-700, #4a4f57)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  head: 'var(--ifm-color-emphasis-600, #606770)',
  cat: 'var(--viz-accent)',
  yon: 'var(--viz-accent)',
  disk: 'var(--viz-green)',
};
const mono = 'var(--ifm-font-family-monospace)';

// [category, yon, on-disk]
const ROWS = [
  ['a category (a site)', 'world', '[world.Restaurant] in yon.toml'],
  ['(where objects live)', 'space', 'a directory: sala/'],
  ['an object', 'place', 'a file: sala/Order.yon'],
  ['an element', 'section', 'a value: .-> Order { … }'],
];

export default function OntologyMap() {
  const cols = ['In category theory', 'In Yon', 'On disk'];
  const colX = [16, 210, 372];
  const colColor = [C.cat, C.yon, C.disk];
  const rowH = 34;
  const H = 44 + ROWS.length * rowH;
  return (
    <div style={{ fontFamily: 'var(--ifm-font-family-base)', color: C.text, maxWidth: 620, margin: '1.5rem auto' }}>
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 8 }}>
        <strong style={{ color: C.text }}>The category lives on disk.</strong> A world is a category, a
        place is an object, a section is an element. None of them is a keyword you write: the project
        layout is the ontology, and the compiler reads it back.
      </div>
      <svg viewBox={`0 0 620 ${H}`} style={{ width: '100%' }} fontFamily="var(--ifm-font-family-base)">
        {cols.map((c, i) => (
          <text key={c} x={colX[i]} y={20} fontSize="11" fill={C.head} fontWeight={600}>{c}</text>
        ))}
        <line x1={16} y1={30} x2={604} y2={30} stroke={C.line} strokeWidth="1" />
        {ROWS.map((row, k) => {
          const y = 44 + k * rowH;
          return (
            <g key={k}>
              {row.map((cell, i) => (
                <text key={i} x={colX[i]} y={y} fontSize={i === 1 ? 14 : 12}
                      fill={i === 1 ? colColor[i] : C.sub}
                      fontFamily={i === 2 ? mono : 'var(--ifm-font-family-base)'}
                      fontWeight={i === 1 ? 600 : 400}>
                  {cell}
                </text>
              ))}
              {/* arrows between columns */}
              <text x={186} y={y} fontSize="12" fill={C.faint}>→</text>
              <text x={352} y={y} fontSize="12" fill={C.faint}>→</text>
            </g>
          );
        })}
      </svg>
    </div>
  );
}
