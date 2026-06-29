import { useState, useEffect } from 'react';

/**
 * Shared auto-play driver for the field-guide viz, matching the house pattern
 * (LeechShells / Mutation / XTowerDial step through states on a timer). Cycles the
 * current step 0..steps-1 on an interval; manual interaction pauses. The visual
 * smoothness is each component's own CSS transitions.
 */
export default function useAutoplay(steps, interval = 1700) {
  const [i, setRaw] = useState(0);
  const [playing, setPlaying] = useState(true);
  useEffect(() => {
    if (!playing) return undefined;
    const t = setTimeout(() => setRaw((x) => (x + 1) % steps), interval);
    return () => clearTimeout(t);
  }, [playing, i, steps, interval]);
  const set = (v) => {
    setPlaying(false);
    setRaw(((v % steps) + steps) % steps);
  };
  return { i, set, playing, setPlaying };
}

// A small shared Play/Pause button style + label helper.
export function playLabel(playing) {
  return playing ? '⏸ Pause' : '⏵ Play';
}
