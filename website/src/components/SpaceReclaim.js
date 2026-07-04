import React from 'react';

/**
 * "A Space's heap arena over a run." Schematic of the region-reclaim mechanism:
 * the arena grows as sections are allocated into the Space, and at `drop X` (or the
 * automatic last-use reclaim the compiler inserts) the WHOLE arena is released in one
 * move via madvise(MADV_DONTNEED), the mapping staying valid.
 *
 * HONESTY CONTRACT:
 *   - This is a SCHEMATIC of the mechanism, not a measurement. The shape (monotone
 *     growth, then a single step down to the baseline at the drop) is the real
 *     behaviour: reclaim is whole-arena in one call, never per-object. The exact
 *     megabytes are illustrative. On Linux MADV_DONTNEED frees the pages eagerly; on
 *     macOS it is lazy, but either way the pages are marked reclaimable and the
 *     Space's live bytes return to the baseline.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  fill: 'var(--viz-fill)',
  stroke: 'var(--viz-accent)',
  gold: 'var(--viz-gold)',
};
const mono = 'var(--ifm-font-family-monospace)';

export default function SpaceReclaim() {
  // steps of a run: each `new`/write grows the Space arena; `drop` releases it.
  const W = 640;
  const H = 260;
  const padL = 44;
  const padR = 16;
  const padT = 18;
  const padB = 46;
  const plotW = W - padL - padR;
  const plotH = H - padT - padB;

  // arena live-bytes at each step (schematic MB): grows, then drops to baseline.
  const pts = [0, 4, 4, 9, 9, 15, 15, 22, 22, 22];
  const dropIdx = 8; // the step where `drop X` fires (between index 7 and 8)
  const maxY = 24;
  const n = pts.length;

  const x = (i) => padL + (plotW * i) / (n - 1);
  const y = (v) => padT + plotH - (plotH * v) / maxY;

  // area path up to the drop, then the cliff, then the baseline tail
  let d = `M ${x(0)} ${y(pts[0])}`;
  for (let i = 1; i < n; i++) d += ` L ${x(i)} ${y(pts[i])}`;
  const area = `${d} L ${x(n - 1)} ${y(0)} L ${x(0)} ${y(0)} Z`;

  const yTicks = [0, 8, 16, 24];

  return (
    <figure style={{ margin: '1.4rem 0' }}>
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img"
           aria-label="A Space's heap arena over a run: it grows as sections are added, then drops to the baseline at drop X.">
        {/* y grid + labels */}
        {yTicks.map((t) => (
          <g key={t}>
            <line x1={padL} y1={y(t)} x2={W - padR} y2={y(t)}
                  stroke={C.rail} strokeWidth="1" />
            <text x={padL - 8} y={y(t) + 3} textAnchor="end"
                  fontSize="10" fill={C.sub} fontFamily={mono}>{t}</text>
          </g>
        ))}
        <text x={12} y={padT + 6} fontSize="10" fill={C.sub} fontFamily={mono}
              transform={`rotate(-90 12 ${padT + plotH / 2})`}>MB live</text>

        {/* filled area + line */}
        <path d={area} fill={C.fill} />
        <path d={d} fill="none" stroke={C.stroke} strokeWidth="2"
              strokeLinejoin="round" strokeLinecap="round" />

        {/* the drop cliff marker */}
        <line x1={x(dropIdx)} y1={padT} x2={x(dropIdx)} y2={padT + plotH}
              stroke={C.gold} strokeWidth="1.4" strokeDasharray="4 3" />
        <text x={x(dropIdx)} y={padT - 4} textAnchor="middle" fontSize="11"
              fill={C.gold} fontFamily={mono} fontWeight="600">drop X</text>

        {/* x labels */}
        <text x={x(0)} y={H - padB + 18} textAnchor="start" fontSize="10"
              fill={C.sub} fontFamily={mono}>new / write into X …</text>
        <text x={x(n - 1)} y={H - padB + 18} textAnchor="end" fontSize="10"
              fill={C.sub} fontFamily={mono}>baseline</text>
        <line x1={padL} y1={padT + plotH} x2={W - padR} y2={padT + plotH}
              stroke={C.line} strokeWidth="1" />
      </svg>
      <figcaption style={{ fontSize: '0.85rem', color: C.sub, marginTop: '0.5rem' }}>
        A Space's heap arena over a run (schematic). It grows as sections are allocated
        into the Space; at <code>drop X</code>, or the automatic reclaim the compiler
        inserts at the Space's last use, the whole arena is released in one call
        (<code>madvise(MADV_DONTNEED)</code>), the mapping left valid. The reclaim is
        whole-arena, never per-object; the megabytes are illustrative, the shape is not.
      </figcaption>
    </figure>
  );
}
