import React from 'react';
import CodeBlock from '@theme/CodeBlock';
import styles from './CodeWindow.module.css';

/**
 * The landing-page code window (dots bar, filename, highlighted code,
 * optional shell output) as a reusable component for the docs.
 *
 * Highlighting comes from the site's Prism `yon` grammar through the
 * standard Docusaurus CodeBlock, so book snippets and the landing share
 * one source of truth for colors.
 *
 * Usage (MDX):
 *   <CodeWindow file="kw_paths.yon" run="yonc kw_paths.yon -o p && ./p"
 *               out={["(exit 42)"]}>
 *   {`fun main(): Number { return 42 }`}
 *   </CodeWindow>
 */
export default function CodeWindow({ file, run, out, children }) {
  return (
    <div className={styles.code}>
      <div className={styles.codeBar}>
        <span className={styles.dots}>
          <i></i>
          <i></i>
          <i></i>
        </span>
        <span>{file}</span>
      </div>
      <CodeBlock language="yon" className={`${styles.body} yon-in-window`}>
        {children}
      </CodeBlock>
      {(run || out) && (
        <div className={styles.codeOut}>
          {run && (
            <span>
              <span className={styles.pmt}>$</span> {run}
            </span>
          )}
          {(out || []).map((line, i) => (
            <span key={i} className={styles.res}>
              {line}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}
