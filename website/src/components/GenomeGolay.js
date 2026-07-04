import React, { useEffect, useState } from 'react';
import trace from '@site/src/data/jp-traces/genome_golay.json';

/**
 * "A gene through two flipped bits." Golay (24,12,8) error correction.
 *
 * HONESTY CONTRACT:
 *   - `trace.data` / `codeword` / `corrupted` / `recovered` are the REAL stdout of
 *     regression/book/jp/05_golay_codeword (toolchain/yonc; regenerate with
 *     website/scripts/build-jp-traces.py). The 24 bits and the two flips are DERIVED from
 *     those numbers (codeword bits; flips = codeword XOR corrupted). The decode is shown as
 *     resolution to the nearest legal codeword (NOT undo); the recovered value is Yon's.
 */

const C = {
  text: 'var(--ifm-font-color-base, #1c1e21)',
  sub: 'var(--ifm-color-emphasis-600, #606770)',
  faint: 'var(--ifm-color-emphasis-500, #8a8f98)',
  border: 'var(--ifm-color-emphasis-300, #dadde1)',
  bit0: 'var(--ifm-color-emphasis-200, #ebedf0)',
  bit1: 'var(--viz-accent)',
  bad: 'var(--viz-red)',
  badText: 'var(--viz-red)',
  good: 'var(--viz-green)',
  goodText: 'var(--viz-green)',
  accentText: 'var(--viz-accent-2)',
};

const N = trace.bits; // 24
const bit = (n, i) => Math.floor(n / Math.pow(2, N - 1 - i)) % 2; // display index i (0 = MSB)
const flips = [];
for (let i = 0; i < N; i++) if (bit(trace.codeword, i) !== bit(trace.corrupted, i)) flips.push(i);

const FRAMES = [
  {
    show: trace.codeword,
    mode: 'plain',
    value: trace.data,
    vlabel: 'gene',
    cap: 'A gene (a 12-bit number) sealed into a 24-bit Golay codeword. The legal codewords sit at least 8 bits apart, so up to three flipped bits still decode to one nearest word. (Three, because the minimum distance is 8 and ⌊(8−1)/2⌋ = 3.)',
  },
  {
    show: trace.corrupted,
    mode: 'corrupt',
    value: null,
    vlabel: 'gene',
    cap: 'Two bits flip, the kind of damage a bad join leaves. The word is no longer legal: it sits between the lawful ones. Two is inside the radius of three, so the original is still its single nearest legal codeword.',
  },
  {
    show: trace.codeword,
    mode: 'decode',
    value: trace.recovered,
    vlabel: 'recovered',
    cap:
      'Opening is decoding, not undo. Among every legal codeword, the damaged word is nearest to this one, the original, so it resolves there and the gene returns whole: ' +
      trace.recovered +
      '. (Past three flips it would resolve to the wrong word, silently. Here, two, the recovery is certain.)',
  },
];

const GROUPS = [
  [0, 8],
  [8, 16],
  [16, 24],
]; // three groups of 8 bits

export default function GenomeGolay() {
  const [frame, setFrame] = useState(0);
  const [playing, setPlaying] = useState(true);

  useEffect(() => {
    if (!playing) return undefined;
    if (frame >= FRAMES.length - 1) {
      setPlaying(false);
      return undefined;
    }
    const t = setTimeout(() => setFrame((f) => f + 1), 2800);
    return () => clearTimeout(t);
  }, [playing, frame]);

  const f = FRAMES[frame];

  const cell = (i) => {
    const b = bit(f.show, i);
    const flipped = flips.includes(i);
    const red = f.mode === 'corrupt' && flipped;
    const green = f.mode === 'decode' && flipped;
    const bg = red ? C.bad : green ? C.good : b ? C.bit1 : C.bit0;
    const fg = red || green ? '#fff' : b ? '#fff' : C.faint;
    const bd = red ? C.bad : green ? C.good : b ? C.bit1 : C.border;
    return (
      <div
        key={i}
        title={`bit ${N - 1 - i}${flipped ? ' (flipped)' : ''}`}
        style={{
          width: 18,
          height: 26,
          borderRadius: 4,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontFamily: 'var(--ifm-font-family-monospace)',
          fontSize: 12,
          fontWeight: 600,
          color: fg,
          background: bg,
          border: `1px solid ${bd}`,
          transition: 'all .45s ease',
        }}
      >
        {b}
      </div>
    );
  };

  return (
    <div
      style={{
        fontFamily: 'var(--ifm-font-family-base)',
        color: C.text,
        maxWidth: 760,
        margin: '1.5rem auto',
      }}
    >
      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, marginBottom: 14 }}>
        <strong style={{ color: C.text }}>A gene through two flipped bits.</strong>
        <br />
        <code>{trace.data}</code> (gene), <code>{trace.codeword}</code> (codeword),{' '}
        <code>{trace.corrupted}</code> (corrupted), <code>{trace.recovered}</code> (recovered) are
        Yon's real output (<code>{trace.source}</code>). The 24 bits and the two flips are derived
        from them.
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 18, marginBottom: 14 }}>
        <div style={{ minWidth: 110 }}>
          <div
            style={{
              fontSize: 10,
              textTransform: 'uppercase',
              letterSpacing: '.04em',
              color: C.sub,
            }}
          >
            {f.vlabel}
          </div>
          <div
            style={{
              fontFamily: 'var(--ifm-font-family-monospace)',
              fontSize: 34,
              fontWeight: 600,
              color: f.value == null ? C.faint : frame === 2 ? C.accentText : C.text,
              transition: 'color .4s',
            }}
          >
            {f.value == null ? '· · ·' : f.value}
          </div>
        </div>
        <div style={{ flex: 1 }}>
          <div
            style={{
              display: 'flex',
              justifyContent: 'space-between',
              fontSize: 9.5,
              color: C.faint,
              marginBottom: 5,
              fontFamily: 'var(--ifm-font-family-monospace)',
            }}
          >
            <span>bit 23 (MSB)</span>
            <span>
              {f.mode === 'corrupt' && (
                <span style={{ color: C.badText }}>2 flipped&nbsp;&nbsp;</span>
              )}
              {f.mode === 'decode' && (
                <span style={{ color: C.goodText }}>2 corrected&nbsp;&nbsp;</span>
              )}
              bit 0 (LSB)
            </span>
          </div>
          <div style={{ display: 'flex', gap: 14 }}>
            {GROUPS.map(([a, z], g) => (
              <div key={g} style={{ display: 'flex', gap: 3 }}>
                {Array.from({ length: z - a }, (_, k) => cell(a + k))}
              </div>
            ))}
          </div>
        </div>
      </div>

      <div style={{ fontSize: 13, color: C.sub, lineHeight: 1.5, minHeight: 56, marginBottom: 12 }}>
        {f.cap}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button onClick={() => setPlaying((p) => !p)} style={btn(C)}>
          {playing ? '⏸ Pause' : '⏵ Play'}
        </button>
        <button
          onClick={() => {
            setPlaying(false);
            setFrame((x) => (x + 1) % FRAMES.length);
          }}
          style={btn(C)}
        >
          Step ▸
        </button>
        <div style={{ display: 'flex', gap: 7, marginLeft: 4 }}>
          {FRAMES.map((_, k) => (
            <span
              key={k}
              onClick={() => {
                setPlaying(false);
                setFrame(k);
              }}
              style={{
                width: 9,
                height: 9,
                borderRadius: '50%',
                cursor: 'pointer',
                background: k === frame ? C.bit1 : C.border,
                transition: 'background .2s',
              }}
            />
          ))}
        </div>
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
