import React, { useState } from 'react';

/**
 * ThreeLenses — Chapter 1 interactive.
 * One dinosaur, three departmental lenses (Science / Security / Legal).
 * Teaches the quotient/view idea: the Legal lens works on the park "up to
 * cohort", so individual identity is not hidden but *not expressible*.
 *
 * Docusaurus usage (MDX):
 *   import ThreeLenses from '@site/src/components/ThreeLenses';
 *   <ThreeLenses />
 *
 * Plain React, no required props, uses Infima CSS variables for light/dark.
 */

const FIELDS = [
  { key: 'species', label: 'species', science: true, security: true, legal: true },
  { key: 'cohort', label: 'cohort', science: true, security: true, legal: true, invariant: true },
  { key: 'position', label: 'position', science: true, security: true, legal: false },
  {
    key: 'biometrics',
    label: 'heart_rate / biometrics',
    science: true,
    security: false,
    legal: false,
  },
  { key: 'containment', label: 'containment_status', science: false, security: true, legal: false },
  {
    key: 'individual_id',
    label: 'individual_id',
    science: true,
    security: true,
    legal: 'quotiented',
  },
];

const LENSES = [
  {
    id: 'science',
    name: 'Science',
    note: 'Sees the animal in full: genome, biometrics, position.',
  },
  {
    id: 'security',
    name: 'Security',
    note: 'Sees position, containment, identity — never the biometrics.',
  },
  {
    id: 'legal',
    name: 'Legal',
    note: 'Works in PublicPark = Park / cohort. Identity is not hidden — it cannot be named.',
  },
];

export default function ThreeLenses() {
  const [lens, setLens] = useState('legal');
  const active = LENSES.find((l) => l.id === lens);

  const cell = (f) => {
    const v = f[lens];
    if (v === true) return { text: f.invariant ? 'visible · invariant' : 'visible', tone: 'ok' };
    if (v === 'quotiented') return { text: 'quotiented away — not expressible', tone: 'quot' };
    return { text: 'not in this lens', tone: 'no' };
  };

  const tone = {
    ok: 'var(--ifm-color-success)',
    no: 'var(--ifm-color-emphasis-500)',
    quot: 'var(--ifm-color-warning-dark)',
  };

  return (
    <div
      style={{
        border: '1px solid var(--ifm-color-emphasis-300)',
        borderRadius: 12,
        padding: '1rem 1.25rem',
        margin: '1.5rem 0',
      }}
    >
      <div style={{ display: 'flex', gap: 8, marginBottom: 12, flexWrap: 'wrap' }}>
        {LENSES.map((l) => (
          <button
            key={l.id}
            onClick={() => setLens(l.id)}
            style={{
              padding: '6px 14px',
              borderRadius: 8,
              cursor: 'pointer',
              border: '1px solid var(--ifm-color-emphasis-300)',
              background: lens === l.id ? 'var(--ifm-color-primary)' : 'transparent',
              color: lens === l.id ? 'var(--ifm-color-white)' : 'var(--ifm-font-color-base)',
              fontWeight: 500,
            }}
          >
            {l.name}
          </button>
        ))}
      </div>

      <p style={{ margin: '0 0 12px', color: 'var(--ifm-color-content-secondary)', fontSize: 14 }}>
        <strong>{active.name} lens.</strong> {active.note}
      </p>

      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14 }}>
        <tbody>
          {FIELDS.map((f) => {
            const c = cell(f);
            return (
              <tr key={f.key} style={{ borderTop: '1px solid var(--ifm-color-emphasis-200)' }}>
                <td style={{ padding: '6px 8px', fontFamily: 'var(--ifm-font-family-monospace)' }}>
                  {f.label}
                </td>
                <td
                  style={{
                    padding: '6px 8px',
                    textAlign: 'right',
                    color: tone[c.tone],
                    fontWeight: 500,
                  }}
                >
                  {c.text}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      <p style={{ margin: '12px 0 0', fontSize: 13, color: 'var(--ifm-color-content-secondary)' }}>
        The Legal lens is a view on <code>PublicPark = Park / cohort</code>. A view that tried to
        <code> show id = individual_id</code> would not factor through the quotient — it does not
        compile.
      </p>
    </div>
  );
}
