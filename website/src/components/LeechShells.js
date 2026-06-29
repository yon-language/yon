import React, { useEffect, useRef, useState } from 'react';
import * as d3 from 'd3';
import trace from '@site/src/data/jp-traces/leech_shells.json';

/**
 * "The shells of the Leech lattice." Each count is the EXACT number of lattice points at a
 * given norm, a theorem checked in frontend/test_leech_theta.ml (re-derived every build).
 * The numbers are Yon's (proven); the rings are an illustration of the shells they count.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-400, #a0a4ab)',
  ring: 'var(--ifm-color-emphasis-300, #dadde1)',
  border: 'var(--ifm-color-emphasis-300, #dadde1)',
  accent: '#4f8ff7',
  accentText: '#2f6fd0',
  gold: '#d99a2b',
  goldText: '#b5790f',
};

const S = trace.shells;
const R = [30, 54, 80, 108, 138]; // ring radii, growing
const fmt = d3.format(',');

export default function LeechShells() {
  const [step, setStep] = useState(0); // how many shells revealed (1..S.length)
  const [playing, setPlaying] = useState(true);
  const numRef = useRef(null);
  const prevCount = useRef(0);

  // tween the big count to the current shell's count
  useEffect(() => {
    const el = numRef.current;
    if (!el || step < 1) return;
    const target = S[step - 1].count;
    const from = prevCount.current;
    d3.select(el)
      .transition()
      .duration(900)
      .ease(d3.easeCubicOut)
      .tween('n', () => {
        const i = d3.interpolateNumber(from, target);
        return (t) => {
          el.textContent = fmt(Math.round(i(t)));
        };
      });
    prevCount.current = target;
  }, [step]);

  useEffect(() => {
    if (!playing) return undefined;
    if (step >= S.length) {
      setPlaying(false);
      return undefined;
    }
    const t = setTimeout(() => setStep((s) => s + 1), 1900);
    return () => clearTimeout(t);
  }, [playing, step]);

  const cur = step >= 1 ? S[step - 1] : null;
  const isKiss = cur && cur.label === 'kissing';

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 720,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>The shells of the Leech lattice.</strong> Around every
        point, the number of others at each distance is an exact integer, a theorem Yon re-derives
        every build (<code>{trace.source}</code>).
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 24, flexWrap: 'wrap' }}>
        <svg viewBox="0 0 300 300" style={{ width: 250, height: 250, flexShrink: 0 }}>
          {R.map((r, i) => {
            const on = i < step;
            const isCur = i === step - 1;
            return (
              <circle
                key={i}
                cx="150"
                cy="150"
                r={r}
                fill="none"
                stroke={isCur ? (S[i].label === 'kissing' ? C.gold : C.accent) : C.ring}
                strokeWidth={isCur ? 2.5 : 1}
                style={{ opacity: on ? 1 : 0.18, transition: 'opacity .6s ease, stroke .4s ease' }}
              />
            );
          })}
          <circle cx="150" cy="150" r="4" fill={C.accentText} />
          {cur && (
            <text
              x="150"
              y="150"
              textAnchor="middle"
              dy="-8"
              fontSize="10"
              fill={C.faint}
              fontFamily="var(--ifm-font-family-monospace)"
            >
              norm {cur.norm}
            </text>
          )}
        </svg>

        <div style={{ flex: 1, minWidth: 240 }}>
          <div
            style={{
              fontSize: 11,
              textTransform: 'uppercase',
              letterSpacing: '.04em',
              color: C.sub,
            }}
          >
            {cur ? `points at norm ${cur.norm}` : 'press play'}
          </div>
          <div
            ref={numRef}
            style={{
              fontFamily: 'var(--ifm-font-family-monospace)',
              fontWeight: 600,
              fontSize: 'clamp(28px, 7vw, 44px)',
              lineHeight: 1.1,
              color: isKiss ? C.goldText : C.accentText,
            }}
          >
            {cur ? fmt(cur.count) : '0'}
          </div>
          {isKiss && (
            <div style={{ fontSize: 12.5, color: C.goldText, marginTop: 4 }}>
              the <strong>kissing number</strong> in 24 dimensions. In 3 dimensions, it is 12.
            </div>
          )}
          {cur && !isKiss && (
            <div style={{ fontSize: 12.5, color: C.sub, marginTop: 4 }}>
              shell {cur.norm}, vastly larger than the last, and still an exact integer.
            </div>
          )}

          <div style={{ marginTop: 14, display: 'flex', flexDirection: 'column', gap: 3 }}>
            {S.map((s, i) => (
              <div
                key={i}
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  fontFamily: 'var(--ifm-font-family-monospace)',
                  fontSize: 12,
                  padding: '2px 8px',
                  borderRadius: 5,
                  background:
                    i === step - 1
                      ? s.label === 'kissing'
                        ? 'rgba(217,154,43,0.12)'
                        : 'rgba(79,143,247,0.10)'
                      : 'transparent',
                  color: i < step ? C.text : C.faint,
                  transition: 'all .3s',
                }}
              >
                <span>
                  norm {s.norm}
                  {s.label === 'kissing' ? '  (kissing)' : ''}
                </span>
                <span>{i < step ? fmt(s.count) : '·'}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 16 }}>
        <button
          onClick={() => {
            if (step >= S.length) setStep(0);
            setPlaying((p) => !p);
          }}
          style={btn(C)}
        >
          {playing ? '⏸ Pause' : step >= S.length ? '↻ Replay' : '⏵ Play'}
        </button>
        <button
          onClick={() => {
            setPlaying(false);
            setStep((s) => (s % S.length) + 1);
          }}
          style={btn(C)}
        >
          Shell ▸
        </button>
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
