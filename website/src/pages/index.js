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
          <Link className={styles.arrowlink} to="/book/future-work">Future work <Arrow /></Link>
          <a className={styles.arrowlink} href="https://github.com/yon-language/yon">Source: OCaml, MLIR, C <Arrow /></a>
        </div>
      </div>
    </section>
  );
}

function Sets() {
  return (
    <section className={`${styles.section} ${styles.sectionAlt}`}>
      <div className={styles.sectionIn}>
        <span className={styles.kicker}>Sets</span>
        <h2 className={styles.h2}>A set is 24 KB of geometry.</h2>
        <p className={styles.lede} style={{maxWidth: '64ch'}}>
          An <strong>XSet</strong> is a subset of the 196,560 minimal vectors of the Leech lattice, stored as a
          fixed <strong>196,560-bit bitmap</strong>: 3,072 64-bit words, about 24&nbsp;KB, the same size whether
          the set holds one element or all of them. Membership is one bit test, <strong>O(1)</strong>. Union and
          intersection are a bitwise OR and AND over those 3,072 words, a fixed pass independent of how many
          elements each set holds; size is a popcount. A minimal perfect hash places each minimal vector at its
          bit with no table of its own and <strong>zero collisions</strong>, verified exhaustively over all
          196,560 (<code>runtime/test_mphf.c</code>).
        </p>
        <p className={styles.lede} style={{maxWidth: '64ch'}}>
          A general-purpose hash set matches the O(1) membership, but not the constant-time set algebra: there,
          union and intersection cost time proportional to the sets. Here they are a fixed 3,072-word pass with
          no per-element work.
        </p>
      </div>
    </section>
  );
}

function Orbits() {
  return (
    <section className={styles.section}>
      <div className={styles.sectionIn}>
        <div className={styles.panel}>
          <span className={styles.kicker}>Symmetry</span>
          <h2 className={styles.h2}>Opt in to identity up to symmetry.</h2>
          <p className={styles.lede}>
            Ordinary allocation addresses a value by its exact content. On top of that, Yon offers
            <strong> opt-in orbital canonicalization</strong>. The Leech lattice carries an exceptional symmetry
            group, the Conway group Co<sub>0</sub>, containing the Mathieu group M<sub>24</sub> acting on the 24
            coordinates of the Golay code. Two values that differ only by such a symmetry lie in the same orbit.
            A collection can be asked to identify each value with the canonical representative of its orbit, so
            symmetry-equivalent contents collapse to one slot: <code>HashSet.orbital_add</code>,
            <code> HashMap.orbital_set</code>, and the orbital variants of XSet and the rest. It is a choice you
            make per collection, where symmetry-equivalence is the identity you want; the canonical form is
            computed through the same mmgroup machinery as the rest of the Leech engine.
          </p>
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
        <Sets />
        <Orbits />
        <Topos />
        <Execution />
      </main>
    </Layout>
  );
}
