/* Yon · live Yoneda motif (React port of motif.js).
   Arrows converging on an absent object, over a lattice dot-field.
   Renders an inline SVG into a div; arrows draw in once on mount. */
import React, { useEffect, useRef } from 'react';

const SVGNS = 'http://www.w3.org/2000/svg';

function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}
function el(n, a) {
  const e = document.createElementNS(SVGNS, n);
  for (const k in a) e.setAttribute(k, a[k]);
  return e;
}

function renderMotif(container, opts) {
  opts = opts || {};
  const density = opts.density == null ? 0.95 : opts.density;
  const accent = opts.accent || '#E8A33D';
  const enso = opts.enso !== false;
  const goldTips = opts.goldTips !== false;
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const W = 1200,
    H = 820;
  const C = { x: 852, y: 404 },
    R = 170;
  const rand = rng(20240606);

  if (!document.getElementById('yon-motif-kf')) {
    const st = document.createElement('style');
    st.id = 'yon-motif-kf';
    st.textContent =
      '@keyframes yon-draw{to{stroke-dashoffset:0}}@keyframes yon-fade{to{opacity:1}}';
    document.head.appendChild(st);
  }

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, fill: 'none' });
  svg.setAttribute('aria-hidden', 'true');
  container.innerHTML = '';
  container.appendChild(svg);

  const gField = el('g', {}),
    gArrows = el('g', {}),
    gHeads = el('g', {});

  const dots = [];
  const N = Math.round(64 + density * 64);
  let guard = 0;
  while (dots.length < N && guard++ < N * 6) {
    const x = rand() * (W - 40) + 20,
      y = rand() * (H - 40) + 20;
    if (Math.hypot(x - C.x, y - C.y) < R + 14) continue;
    dots.push({ x, y });
  }
  for (let i = 0; i < dots.length; i++) {
    for (let j = i + 1; j < dots.length; j++) {
      const d = Math.hypot(dots[i].x - dots[j].x, dots[i].y - dots[j].y);
      if (d < 96 && rand() < 0.22) {
        gField.appendChild(
          el('line', {
            x1: dots[i].x,
            y1: dots[i].y,
            x2: dots[j].x,
            y2: dots[j].y,
            stroke: '#6A5FC0',
            'stroke-width': 1,
            'stroke-opacity': 0.12,
          }),
        );
      }
    }
  }
  dots.forEach((d) => {
    gField.appendChild(
      el('circle', {
        cx: d.x,
        cy: d.y,
        r: 1.2 + rand() * 1.7,
        fill: '#A59ED7',
        'fill-opacity': (0.16 + rand() * 0.34).toFixed(2),
      }),
    );
  });

  if (enso) {
    const a0 = -1.15,
      a1 = Math.PI * 2 - 0.5;
    const sx = C.x + R * Math.cos(a0),
      sy = C.y + R * Math.sin(a0);
    const ex = C.x + R * Math.cos(a1),
      ey = C.y + R * Math.sin(a1);
    gField.appendChild(
      el('path', {
        d: `M ${sx} ${sy} A ${R} ${R} 0 1 1 ${ex} ${ey}`,
        stroke: '#6A5FC0',
        'stroke-width': 1.4,
        'stroke-opacity': 0.4,
        'stroke-linecap': 'round',
      }),
    );
  }

  const arrows = [];
  const M = Math.round(32 + density * 16);
  const X_MIN = 466;
  for (let i = 0; i < M; i++) {
    const fromRight = rand() < 0.16;
    let ang;
    if (fromRight) ang = -0.5 + rand() * 1.0;
    else ang = 0.5 + rand() * (Math.PI * 2 - 1.0);
    const u = { x: Math.cos(ang), y: Math.sin(ang) };
    const perp = { x: -u.y, y: u.x };
    const Tend = { x: C.x + (R + 9) * u.x, y: C.y + (R + 9) * u.y };
    let reach = R + 130 + rand() * 470;
    if (u.x < -0.06) reach = Math.min(reach, (X_MIN - C.x) / u.x);
    reach = Math.max(reach, R + 110);
    const lateral = (rand() - 0.5) * 44;
    const S = { x: C.x + u.x * reach + perp.x * lateral, y: C.y + u.y * reach + perp.y * lateral };
    const c2 = { x: Tend.x + u.x * (54 + rand() * 30), y: Tend.y + u.y * (54 + rand() * 30) };
    const bowSign = u.y >= 0 ? 1 : -1;
    const bow = (reach - R) * (0.07 + rand() * 0.05) * bowSign;
    const c1 = {
      x: S.x - u.x * (reach - R) * 0.42 + perp.x * bow,
      y: S.y - u.y * (reach - R) * 0.42 + perp.y * bow,
    };
    arrows.push({ S, c1, c2, Tend, u, gold: goldTips && rand() < 0.14 });
  }

  const drawables = [];
  arrows.forEach((a, idx) => {
    const path = el('path', {
      d: `M ${a.S.x.toFixed(1)} ${a.S.y.toFixed(1)} C ${a.c1.x.toFixed(1)} ${a.c1.y.toFixed(1)} ${a.c2.x.toFixed(1)} ${a.c2.y.toFixed(1)} ${a.Tend.x.toFixed(1)} ${a.Tend.y.toFixed(1)}`,
      stroke: a.gold ? accent : '#9991d6',
      'stroke-width': a.gold ? 1.5 : 1.1,
      'stroke-opacity': a.gold ? 0.85 : (0.32 + rand() * 0.24).toFixed(2),
      'stroke-linecap': 'round',
    });
    gArrows.appendChild(path);
    const back = { x: -a.u.x, y: -a.u.y };
    const perp = { x: -a.u.y, y: a.u.x };
    const tip = { x: a.Tend.x + back.x * 2, y: a.Tend.y + back.y * 2 };
    const baseLen = 11,
      wing = 5;
    const b = { x: tip.x - back.x * baseLen, y: tip.y - back.y * baseLen };
    const p1 = `${(b.x + perp.x * wing).toFixed(1)} ${(b.y + perp.y * wing).toFixed(1)}`;
    const p2 = `${(b.x - perp.x * wing).toFixed(1)} ${(b.y - perp.y * wing).toFixed(1)}`;
    const head = el('path', {
      d: `M ${tip.x.toFixed(1)} ${tip.y.toFixed(1)} L ${p1} M ${tip.x.toFixed(1)} ${tip.y.toFixed(1)} L ${p2}`,
      stroke: a.gold ? accent : '#cfc8f5',
      'stroke-width': 1.5,
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      'stroke-opacity': a.gold ? 0.95 : 0.7,
    });
    gHeads.appendChild(head);
    drawables.push({ path, head, idx });
  });

  svg.appendChild(gField);
  svg.appendChild(gArrows);
  svg.appendChild(gHeads);

  drawables.forEach(({ path, head, idx }) => {
    if (reduced) return;
    const len = path.getTotalLength();
    const delay = 120 + idx * 30;
    path.style.strokeDasharray = len;
    path.style.strokeDashoffset = len;
    head.style.opacity = 0;
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        path.style.transition = `stroke-dashoffset 1.0s cubic-bezier(.22,.61,.36,1) ${delay}ms`;
        path.style.strokeDashoffset = '0';
        head.style.transition = `opacity .4s ease ${delay + 720}ms`;
        head.style.opacity = '1';
      }),
    );
    setTimeout(() => {
      path.style.strokeDashoffset = '0';
      head.style.opacity = '1';
    }, delay + 1250);
  });

  const sq = el('g', { 'stroke-linecap': 'round' });
  const x0 = 70,
    y0 = 612,
    s = 86;
  sq.appendChild(
    el('path', {
      d: `M ${x0 + 10} ${y0} L ${x0 + s} ${y0} L ${x0 + s} ${y0 + s} L ${x0} ${y0 + s} L ${x0} ${y0 + 12}`,
      stroke: '#6A5FC0',
      'stroke-width': 1.4,
      'stroke-opacity': 0.5,
    }),
  );
  sq.appendChild(
    el('path', {
      d: `M ${x0 + 8} ${y0 + 8} L ${x0 + 20} ${y0 + 8} M ${x0 + 8} ${y0 + 8} L ${x0 + 8} ${y0 + 20}`,
      stroke: '#A59ED7',
      'stroke-width': 1.4,
      'stroke-opacity': 0.6,
    }),
  );
  svg.appendChild(sq);
}

export default function YonMotif({ className }) {
  const ref = useRef(null);
  useEffect(() => {
    if (ref.current) renderMotif(ref.current, {});
  }, []);
  return <div ref={ref} className={className} aria-hidden="true" />;
}
