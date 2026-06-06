import React from 'react';
import Layout from '@theme/Layout';
import Link from '@docusaurus/Link';
import YonMotif from '@site/src/components/YonMotif';
import styles from './index.module.css';

const Arrow = () => (
  <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <path d="M3 8h10M9 4l4 4-4 4" />
  </svg>
);

function Hero() {
  return (
    <header className={styles.hero}>
      <YonMotif className={styles.motif} />
      <div className={styles.heroIn}>
        <div className={styles.eyebrow}><span className={styles.kicker}>The Topos of Programming</span></div>
        <h1 className={styles.title}>Yon</h1>
        <p className={styles.line}>A <span className={styles.hl}>topos-oriented</span> programming language.</p>
        <div className={styles.cta}>
          <Link className={`${styles.btn} ${styles.btnGold}`} to="/syntax-reference">Syntax Reference <Arrow /></Link>
          <Link className={`${styles.btn} ${styles.btnGhost}`} to="/book/benchmarks">Benchmarks <Arrow /></Link>
        </div>
        <div className={styles.meta}>
          <span>Native via MLIR &amp; LLVM</span>
          <span>No garbage collector</span>
          <span>AGPL</span>
        </div>
      </div>
    </header>
  );
}

function Heap() {
  return (
    <section className={styles.section}>
      <div className={styles.sectionIn}>
        <div className={styles.grid2}>
          <div>
            <span className={styles.kicker}>The heap</span>
            <h2 className={styles.h2}>The address of a value is its content.</h2>
            <p className={styles.lede}>
              Yon allocates into <strong>xleech2</strong>, a content-addressed heap whose geometry is the
              Leech lattice Λ<sub>24</sub>: exactly <strong>196,560 slots</strong> per heap. Allocation hashes
              the bytes; identical content returns the existing slot, so <strong>same content ⇔ same slot</strong>.
              Equality of arbitrarily large values is one number comparison: <strong>O(1) structural equality</strong>,
              by construction.
            </p>
            <div className={styles.stat}>
              <b>String.equal</b>: ~17 ns at 1 char and at 32,768 chars. Three orders of magnitude of size,
              the same per-comparison time.
              <Link className={styles.statLink} to="/book/benchmarks">Benchmarks</Link>
            </div>
          </div>
          <div>
            <div className={styles.code}>
              <div className={styles.codeBar}>
                <span className={styles.dots}><i></i><i></i><i></i></span>
                <span>hello.yon</span>
              </div>
              <pre>
<span className={styles.kw}>fun</span> <span className={styles.fn}>main</span>(): <span className={styles.ty}>number</span> {'{'}{'\n'}
{'  '}<span className={styles.kw}>be</span> greeting <span className={styles.kw}>holds</span> <span className={styles.st}>"ciao, mondo"</span>   <span className={styles.cm}>// interned on the heap</span>{'\n'}
{'  '}<span className={styles.kw}>be</span> _ <span className={styles.kw}>holds</span> <span className={styles.ty}>String</span>.<span className={styles.fn}>print</span>(greeting){'\n'}
{'  '}<span className={styles.kw}>return</span> <span className={styles.nu}>0</span>{'\n'}
{'}'}
              </pre>
              <div className={styles.codeOut}>
                <span><span className={styles.pmt}>$</span> yonc hello.yon -o hello &amp;&amp; ./hello</span>
                <span className={styles.res}>ciao, mondo</span>
              </div>
            </div>
            <p className={styles.caption}>
              Every string literal is a section of the builtin <code>String</code> place, interned on that same
              heap, so two equal strings are one slot, however they were built.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}

function Topos() {
  return (
    <section className={`${styles.section} ${styles.sectionAlt}`}>
      <div className={styles.sectionIn}>
        <div className={styles.panel}>
          <span className={styles.kicker}>The paradigm</span>
          <h2 className={styles.h2}>Worlds are categories. Behaviour is arrows.</h2>
          <p className={styles.lede}>
            In Topos-Oriented Programming a <strong>world</strong> is a category, a <strong>place</strong> is an
            object in it, and a value is a <strong>section</strong>: immutable, identified by its content. All
            behaviour lives in <strong>arrows</strong>. Identity is the exception, requested only where you need
            it. Logic is internal: truth is the subobject classifier Ω, and <code>unknown</code> is a citizen of
            the Heyting core, not an error. From the Yoneda lemma, a thing is determined by its relations; the
            type checker, optimizer, and allocator act on that.
          </p>
          <Link className={styles.arrowlink} to="/book/topos-oriented-programming">Read “Topos-Oriented Programming” <Arrow /></Link>
        </div>
      </div>
    </section>
  );
}

const ABSENT = [
  ['No garbage collector', 'Slots are stable for the life of the process; the heap grows with distinct content only.'],
  ['No threads', 'The unit of concurrency is the process. Spaces talk over a shared-memory wire.'],
  ['No exceptions', 'Failure is data: a place, a declaration, or a process exit, never a thrown stack.'],
  ['No typeclasses', 'Arrows are the interface: a place’s presheaf of observations.'],
];

function Execution() {
  return (
    <section className={styles.section}>
      <div className={styles.sectionIn}>
        <span className={styles.kicker}>Execution model</span>
        <h2 className={styles.h2}>What Yon does without.</h2>
        <p className={styles.lede} style={{maxWidth: '60ch'}}>
          Identity is explicit. Concurrency is the process. Failure is a value. The interface to a place is its
          arrows. Four mechanisms common elsewhere are absent:
        </p>
        <div className={styles.absents}>
          {ABSENT.map(([h, p]) => (<div key={h}><h4>{h}</h4><p>{p}</p></div>))}
        </div>
        <div className={styles.links}>
          <Link className={styles.arrowlink} to="/book/limits">The limits of 1.0 <Arrow /></Link>
          <a className={styles.arrowlink} href="https://github.com/yon-language/yon">Source: OCaml, MLIR, C <Arrow /></a>
        </div>
      </div>
    </section>
  );
}

export default function Home() {
  return (
    <Layout title="The Topos of Programming"
            description="A topos-oriented programming language. Native via MLIR and LLVM, with a content-addressed heap on the Leech lattice.">
      <main className={styles.page}>
        <Hero />
        <Heap />
        <Topos />
        <Execution />
      </main>
    </Layout>
  );
}
