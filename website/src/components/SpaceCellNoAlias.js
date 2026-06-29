import React, { useEffect, useRef, useState, useCallback } from 'react';
import * as d3 from 'd3';
import trace from '@site/src/data/jp-traces/space_cell_no_alias.json';

/**
 * "The clipboard and the pen" — why `x = 5` leaves `y` at 3.
 *
 * HONESTY CONTRACT (do not break):
 *   - The NUMBERS come from `trace.printed` / `trace.steps`, which is the real stdout
 *     of regression/book/jp/probe_no_alias compiled and run by toolchain/yonc
 *     (regenerate with website/scripts/build-jp-traces.py). Yon emits, React replays.
 *   - The cells, wires, copy and prose below are an ILLUSTRATION of *why*, not a Yon
 *     trace. Labelled as such. The no-aliasing guarantee is PROVEN in the lexer
 *     (no address-of operator), not emitted as data.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  surface: 'var(--ifm-color-emphasis-100, #f5f6f7)',
  border: 'var(--ifm-color-emphasis-300, #dadde1)',
  cellBg: 'var(--ifm-background-surface-color, #ffffff)',
  accent: '#4f8ff7',
  accentText: '#2f6fd0',
  accentBg: 'rgba(79,143,247,0.12)',
};

// Four frames. State (cell, y) is taken from the real trace; the store frame is
// shown twice (the second is the "reveal"). The prose is our illustration.
const NARR = [
  {
    sem: 'Paddock 7 enters the world holding 3 raptors.',
    sil: 'g_space_cells[0] = 3   (one cell, the live count)',
    why: 'x is the tracker. It owns no number of its own; it reads the pen each time it is named.',
  },
  {
    sem: 'The control room writes the count down: 3.',
    sil: 'y = 3   (the value, copied off the cell)',
    why: 'The clipboard took the number, not the pen. No wire is made, and in Yon there is none to make.',
  },
  {
    sem: 'A raptor hatches. Rebuild the world so the pen now holds 5.',
    sil: 'g_space_cells[0].value = 5   (one store)',
    why: 'Nothing else watches this cell. The clipboard copied the value, never the pen, so the store cannot reach it. The compiler earned the store by making the alias unconstructable.',
  },
  {
    sem: 'The pen holds 5. The clipboard still reads 3. Two numbers that never joined.',
    sil: 'one store touched the pen; the clipboard’s 3 was never in a cell',
    why: 'In C you could not tell, from the clipboard alone, whether it was a copy or a wire to the pen: the choice is yours and hidden. In Yon there is no wire to build, so it is always a copy. The gap between the report and the pen is Hammond’s whole gap, and Yon makes it impossible to mistake one for the other. Trusting the stale copy stays human.',
  },
];

const STEPS = trace.steps; // [bind, snapshot, store]
const FRAME_STATE = [STEPS[0], STEPS[1], STEPS[2], STEPS[2]];
const SRC = STEPS.map((s) => s.src);
// the printed values, with which frame first reveals each
const STRIP = [
  { l: 'x', v: STEPS[0].cell, at: 0 },
  { l: 'y', v: STEPS[1].y, at: 1 },
  { l: 'x', v: STEPS[2].cell, at: 2 },
  { l: 'y', v: STEPS[2].y, at: 2 },
];

export default function SpaceCellNoAlias() {
  const svgRef = useRef(null);
  const [frame, setFrame] = useState(0);
  const [playing, setPlaying] = useState(true);
  const prev = useRef(0);

  const animate = useCallback((i, withMotion) => {
    const svg = svgRef.current;
    if (!svg) return;
    const st = FRAME_STATE[i];
    const sel = (id) => d3.select(svg.querySelector(`[data-id="${id}"]`));

    // cell value (tween on a store)
    const cellEl = svg.querySelector('[data-id="cellVal"]');
    if (cellEl) {
      const from = +cellEl.textContent || st.cell;
      if (withMotion && i === 2 && from !== st.cell) {
        d3.select(cellEl)
          .transition()
          .duration(450)
          .tween('t', function () {
            const ip = d3.interpolateRound(from, st.cell);
            return (k) => {
              cellEl.textContent = ip(k);
            };
          });
      } else {
        cellEl.textContent = st.cell;
      }
    }
    sel('cellVal').style('fill', i === 3 ? C.accentText : C.text);

    // clipboard
    sel('yGroup')
      .transition()
      .duration(380)
      .style('opacity', st.y == null ? 0 : 1);
    if (st.y != null) {
      const yv = svg.querySelector('[data-id="yVal"]');
      if (yv) yv.textContent = st.y;
    }
    sel('nowire')
      .transition()
      .duration(380)
      .style('opacity', i >= 1 ? 1 : 0);

    // copy pellet on the snapshot frame
    if (withMotion && i === 1) {
      sel('pellet')
        .interrupt()
        .style('opacity', 1)
        .style('transform', 'translate(0px,0px)')
        .transition()
        .duration(640)
        .ease(d3.easeCubicInOut)
        .style('transform', 'translate(262px,0px)')
        .transition()
        .duration(160)
        .style('opacity', 0);
    } else {
      sel('pellet').style('opacity', 0).style('transform', 'translate(0px,0px)');
    }
    // pulse on the store frame
    if (withMotion && i === 2) {
      sel('pulse')
        .interrupt()
        .style('opacity', 0.9)
        .style('transform', 'scale(1)')
        .transition()
        .duration(620)
        .style('opacity', 0)
        .style('transform', 'scale(1.1)');
    }
  }, []);

  useEffect(() => {
    const withMotion = frame !== prev.current || frame === 0;
    animate(frame, withMotion);
    prev.current = frame;
  }, [frame, animate]);

  useEffect(() => {
    if (!playing) return undefined;
    if (frame >= NARR.length - 1) {
      setPlaying(false);
      return undefined;
    }
    const t = setTimeout(() => setFrame((f) => f + 1), 2300);
    return () => clearTimeout(t);
  }, [playing, frame]);

  const n = NARR[frame];

  const dot = (active) => ({
    width: 9,
    height: 9,
    borderRadius: '50%',
    cursor: 'pointer',
    background: active ? C.accent : C.border,
    transition: 'background .2s',
  });

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 780,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>
          A raptor hatches in Paddock 7. The control-room clipboard does not follow.
        </strong>
        <br />
        The numbers <code>{trace.printed.join(' · ')}</code> are what Yon actually printed (
        <code>{trace.source}</code>, gated on the Mac), replayed here. The pen, the clipboard and
        the wires illustrate why.
      </div>

      <svg
        ref={svgRef}
        viewBox="0 0 700 218"
        style={{ width: '100%', height: 'auto', display: 'block' }}
      >
        {/* tracker x */}
        <g>
          <rect
            x="26"
            y="78"
            width="94"
            height="60"
            rx="12"
            style={{ fill: C.accentBg, stroke: C.accent }}
            strokeWidth="1"
          />
          <text
            x="73"
            y="104"
            textAnchor="middle"
            fontFamily="var(--ifm-font-family-monospace)"
            fontSize="16"
            fontWeight="600"
            style={{ fill: C.accentText }}
          >
            x
          </text>
          <text x="73" y="122" textAnchor="middle" fontSize="10" style={{ fill: C.accentText }}>
            the tracker
          </text>
        </g>
        <line x1="120" y1="108" x2="268" y2="108" style={{ stroke: C.accent }} strokeWidth="2.5" />

        {/* the cell = Paddock 7 live count */}
        <text
          x="356"
          y="56"
          textAnchor="middle"
          fontFamily="var(--ifm-font-family-monospace)"
          fontSize="11"
          style={{ fill: C.faint }}
        >
          Paddock 7 · live count · g_space_cells[0]
        </text>
        <rect
          x="270"
          y="70"
          width="172"
          height="78"
          rx="14"
          style={{ fill: C.surface, stroke: C.border }}
          strokeWidth="1"
        />
        <text
          data-id="cellVal"
          x="356"
          y="122"
          textAnchor="middle"
          fontFamily="var(--ifm-font-family-monospace)"
          fontSize="38"
          fontWeight="600"
          style={{ fill: C.text }}
        >
          {STEPS[0].cell}
        </text>
        <rect
          data-id="pulse"
          x="270"
          y="70"
          width="172"
          height="78"
          rx="14"
          fill="none"
          style={{ stroke: C.accent, opacity: 0, transformOrigin: '356px 109px' }}
          strokeWidth="3"
        />

        {/* absent wire */}
        <g data-id="nowire" style={{ opacity: 0 }}>
          <line
            x1="442"
            y1="108"
            x2="556"
            y2="108"
            style={{ stroke: C.faint, opacity: 0.5 }}
            strokeWidth="2"
            strokeDasharray="5 6"
          />
          <text x="499" y="96" textAnchor="middle" fontSize="10.5" style={{ fill: C.faint }}>
            no wire
          </text>
          <line x1="489" y1="102" x2="509" y2="114" style={{ stroke: C.faint }} strokeWidth="1.6" />
          <line x1="509" y1="102" x2="489" y2="114" style={{ stroke: C.faint }} strokeWidth="1.6" />
        </g>

        {/* clipboard y */}
        <g data-id="yGroup" style={{ opacity: 0 }}>
          <rect
            x="558"
            y="72"
            width="116"
            height="78"
            rx="10"
            style={{ fill: C.cellBg, stroke: C.border }}
            strokeWidth="1"
          />
          <text x="616" y="96" textAnchor="middle" fontSize="10" style={{ fill: C.faint }}>
            clipboard (y)
          </text>
          <text
            data-id="yVal"
            x="616"
            y="132"
            textAnchor="middle"
            fontFamily="var(--ifm-font-family-monospace)"
            fontSize="28"
            fontWeight="600"
            style={{ fill: C.text }}
          >
            {STEPS[1].y}
          </text>
        </g>

        {/* copy pellet */}
        <g data-id="pellet" style={{ opacity: 0 }}>
          <circle
            cx="356"
            cy="108"
            r="15"
            style={{ fill: C.accentBg, stroke: C.accent }}
            strokeWidth="1"
          />
          <text
            x="356"
            y="113"
            textAnchor="middle"
            fontFamily="var(--ifm-font-family-monospace)"
            fontSize="14"
            fontWeight="700"
            style={{ fill: C.accentText }}
          >
            {STEPS[1].y}
          </text>
        </g>
      </svg>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '6px 0 16px' }}>
        <span
          style={{
            fontSize: 11,
            color: C.sub,
            fontFamily: 'var(--ifm-font-family-monospace)',
            whiteSpace: 'nowrap',
          }}
        >
          Yon printed →
        </span>
        <div style={{ display: 'flex', gap: 8 }}>
          {STRIP.map((t, k) => {
            const shown = t.at <= frame || frame === 3;
            const active = t.at === frame || (frame === 3 && k >= 2);
            return (
              <div
                key={k}
                style={{
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  minWidth: 28,
                  padding: '3px 7px',
                  borderRadius: 6,
                  border: `0.5px solid ${active ? C.accent : C.border}`,
                  background: active ? C.accentBg : 'transparent',
                  opacity: shown ? 1 : 0.25,
                  transition: 'all .3s',
                }}
              >
                <span
                  style={{
                    fontFamily: 'var(--ifm-font-family-monospace)',
                    fontSize: 9,
                    color: C.sub,
                  }}
                >
                  {t.l}
                </span>
                <span
                  style={{
                    fontFamily: 'var(--ifm-font-family-monospace)',
                    fontSize: 17,
                    fontWeight: 600,
                    color: C.text,
                  }}
                >
                  {t.v}
                </span>
              </div>
            );
          })}
        </div>
      </div>

      <div
        style={{
          display: 'grid',
          gridTemplateColumns: '0.8fr 1.2fr',
          gap: 14,
          alignItems: 'start',
        }}
      >
        <div style={{ background: C.surface, borderRadius: 8, padding: '12px 14px' }}>
          <div style={{ fontSize: 11, color: C.sub, marginBottom: 8 }}>source</div>
          <pre
            style={{
              margin: 0,
              fontFamily: 'var(--ifm-font-family-monospace)',
              fontSize: 13.5,
              lineHeight: 1.7,
              background: 'none',
              padding: 0,
            }}
          >
            {SRC.map((l, k) => (
              <span
                key={k}
                style={{
                  display: 'block',
                  padding: '1px 6px',
                  borderRadius: 5,
                  background: k === Math.min(frame, 2) ? C.accentBg : 'transparent',
                  color: k === Math.min(frame, 2) ? C.accentText : C.text,
                  fontWeight: k === Math.min(frame, 2) ? 600 : 400,
                }}
              >
                {l}
              </span>
            ))}
          </pre>
        </div>
        <div>
          <Line label="semantics" body={n.sem} color={C} mono={false} />
          <Line label="silicon" body={n.sil} color={C} mono />
          <div
            style={{
              background: C.accentBg,
              borderLeft: `2px solid ${C.accent}`,
              borderRadius: 8,
              padding: '9px 12px',
            }}
          >
            <div
              style={{
                fontSize: 10,
                textTransform: 'uppercase',
                letterSpacing: '.04em',
                color: C.accentText,
                opacity: 0.85,
              }}
            >
              why it&rsquo;s allowed
            </div>
            <div style={{ fontSize: 12, lineHeight: 1.45, marginTop: 2, color: C.accentText }}>
              {n.why}
            </div>
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 14 }}>
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playing ? '⏸ Pause' : '⏵ Play'}
        </button>
        <button
          onClick={() => {
            setPlaying(false);
            setFrame((f) => (f + 1) % NARR.length);
          }}
          style={btn(C)}
        >
          Step ▸
        </button>
        <div style={{ display: 'flex', gap: 7, marginLeft: 4 }}>
          {NARR.map((_, k) => (
            <span
              key={k}
              onClick={() => {
                setPlaying(false);
                setFrame(k);
              }}
              style={dot(k === frame)}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

function Line({ label, body, color, mono }) {
  return (
    <div style={{ marginBottom: 9 }}>
      <div
        style={{
          fontSize: 10,
          textTransform: 'uppercase',
          letterSpacing: '.04em',
          color: color.sub,
        }}
      >
        {label}
      </div>
      <div
        style={{
          fontSize: mono ? 12 : 13,
          lineHeight: 1.4,
          marginTop: 2,
          minHeight: 18,
          fontFamily: mono ? 'var(--ifm-font-family-monospace)' : 'inherit',
          color: mono ? color.accentText : color.text,
        }}
      >
        {body}
      </div>
    </div>
  );
}

function btn(color) {
  return {
    fontFamily: 'var(--ifm-font-family-base)',
    fontSize: 13,
    padding: '6px 14px',
    borderRadius: 8,
    border: `0.5px solid ${color.border}`,
    background: 'transparent',
    color: color.text,
    cursor: 'pointer',
  };
}
