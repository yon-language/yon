import React from 'react';
import useAutoplay, { playLabel } from './_autoplay';
import data from '@site/src/data/bench-spawn.json';

/**
 * "Multicore, for free." `spawn in N parallel { ... }` forks N isolated OS-process
 * replicas over a shared-memory collection; each runs the same fixed CPU-bound task.
 *
 * HONESTY CONTRACT:
 *   - Every wall-time and speedup is the REAL measurement in
 *     regression/book/jp/bench/spawn_scaling-1c44e79-20260629.json (gated by
 *     regression/test_spawn_scaling.py, which skips where fork+SHM are unavailable).
 *     Measured on an 8-core Apple M1; the milliseconds are this machine's, the shape
 *     (flat to the core count, then rising) is the property. Nothing here is invented.
 *   - The cores below are a schematic of the 8-core M1 (4 performance + 4 efficiency).
 *     A replica is drawn on a core; past 8 replicas the cores carry two, the picture of
 *     oversubscription that the rising wall-time records.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-400, #a0a4ab)',
  line: 'var(--ifm-color-emphasis-300, #dadde1)',
  rail: 'var(--ifm-color-emphasis-200, #ebedf0)',
  perf: '#4f8ff7',
  perfText: '#2f6fd0',
  eff: '#1d9e75',
  effText: '#0f6e56',
  hot: '#d99a2b',
  hotText: '#b5790f',
};
const mono = 'var(--ifm-font-family-monospace)';

export default function ParallelScaling() {
  const steps = data.Ns.length;
  const { i, set, playing, setPlaying } = useAutoplay(steps);
  const N = data.Ns[i];
  const wall = data.wall_ms[i];
  const speedup = data.speedup[i];
  const cores = data.cores_total;
  const over = N > cores;
  const maxWall = Math.max(...data.wall_ms);

  // replicas-per-core for this N (1 each up to `cores`, then a second wave)
  const perCore = (c) => (c < N ? 1 : 0) + (c + cores < N ? 1 : 0);

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 540,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>Multicore, for free.</strong>{' '}
        <code>spawn in {N} parallel</code> forks {N} process {N === 1 ? 'replica' : 'replicas'} over
        shared memory. Up to the 8 cores, {N}&times; the work finishes in nearly the same wall-clock;
        past them, replicas oversubscribe and the clock rises. Real run on an 8-core M1 (
        <code>spawn_scaling</code>).
      </div>

      <svg viewBox="0 0 360 150" style={{ width: '100%', maxWidth: 360 }}>
        {/* 8 cores, 4 performance + 4 efficiency */}
        {Array.from({ length: cores }).map((_, c) => {
          const x = 8 + c * 43;
          const isPerf = c < data.cores_performance;
          const load = perCore(c);
          const busy = load > 0;
          const base = isPerf ? C.perf : C.eff;
          const baseText = isPerf ? C.perfText : C.effText;
          return (
            <g key={c} fontFamily={mono}>
              <rect
                x={x}
                y={20}
                width="36"
                height="44"
                rx="7"
                fill={busy ? (load > 1 ? 'rgba(217,154,43,0.14)' : 'rgba(79,143,247,0.09)') : 'transparent'}
                stroke={load > 1 ? C.hot : busy ? base : C.line}
                strokeWidth={load > 1 ? 2 : 1}
                style={{ transition: 'all 0.4s ease' }}
              />
              <text x={x + 18} y={15} textAnchor="middle" fontSize="8.5" fill={C.faint}>
                {isPerf ? 'P' : 'E'}
              </text>
              {/* replica dots stacked on the core */}
              {Array.from({ length: load }).map((__, r) => (
                <circle
                  key={r}
                  cx={x + 18}
                  cy={34 + r * 17}
                  r="6"
                  fill={load > 1 ? C.hotText : baseText}
                  style={{ transition: 'all 0.4s ease' }}
                />
              ))}
            </g>
          );
        })}

        {/* wall-time bar */}
        <text x={8} y={88} fontSize="9.5" fill={C.faint} fontFamily={mono}>
          wall-clock
        </text>
        <rect x={8} y={94} width="344" height="14" rx="7" fill={C.rail} />
        <rect
          x={8}
          y={94}
          width={Math.round((wall / maxWall) * 344)}
          height="14"
          rx="7"
          fill={over ? C.hot : C.perf}
          style={{ transition: 'width 0.5s ease, fill 0.4s ease' }}
        />
        <text x={8} y={128} fontSize="13" fill={C.text} fontFamily={mono}>
          N = {N}
        </text>
        <text x={120} y={128} fontSize="13" fill={C.sub} fontFamily={mono}>
          {wall} ms
        </text>
        <text
          x={352}
          y={128}
          textAnchor="end"
          fontSize="14"
          fill={over ? C.hotText : C.perfText}
          fontFamily={mono}
        >
          {speedup.toFixed(1)}&times; speedup
        </text>
        <text x={8} y={145} fontSize="9.5" fill={C.faint} fontFamily="var(--ifm-font-family-base)">
          {over
            ? `${N} replicas on ${cores} cores: oversubscribed, the clock rises`
            : `${N}× the work, ~1× the time`}
        </text>
      </svg>

      <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 }}>
        <span style={{ fontFamily: mono, fontSize: 13, color: C.sub }}>
          spawn in {N} parallel
        </span>
        <div style={{ flex: 1 }} />
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playLabel(playing)}
        </button>
        <button onClick={() => set((i + 1) % steps)} style={btn(C)}>
          N = {data.Ns[(i + 1) % steps]} &#9656;
        </button>
      </div>
    </div>
  );
}

function btn(c) {
  return {
    fontFamily: 'var(--ifm-font-family-base)',
    fontSize: 13,
    padding: '6px 14px',
    borderRadius: 8,
    border: `0.5px solid ${c.line}`,
    background: 'transparent',
    color: c.text,
    cursor: 'pointer',
  };
}
