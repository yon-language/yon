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

function Banner() {
  return (
    <div style={{
      borderBottom: '1px solid rgba(212,175,55,0.35)',
      background: 'rgba(212,175,55,0.06)',
      padding: '11px 20px',
      textAlign: 'center',
      fontSize: '0.9rem',
      lineHeight: 1.55,
    }}>
      <strong>Active development — 1.1 lands soon.</strong> Yon is mid-refactor on
      the road to <strong>1.1</strong>: a handful of known errors are still being
      corrected, so an example, a doc page, or an API name may be briefly out of step
      with the compiler — rough edges are expected. The source and the benchmarks are
      public; what these pages describe is what compiles and runs today.
    </div>
  );
}

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
              Yon allocates into <strong>xleech2</strong>, a <strong>content-addressed</strong> heap. Allocation
              hashes the bytes; identical content returns the existing slot, and a hash collision is settled by a
              direct byte comparison, so distinct content never aliases and <strong>same content ⇔ same slot</strong>.
              Equality of arbitrarily large values is then one integer comparison: <strong>O(1) structural
              equality</strong>, by construction. The work is done by content-addressing, not by lattice geometry.
              The Leech lattice enters as a deliberate bound: a heap holds at most <strong>196,560 slots</strong>,
              the count of minimal vectors of Λ<sub>24</sub> — a fixed, bounded-state capacity that fails loudly at
              the limit instead of degrading silently. Where the lattice is actually load-bearing is in the
              structures below — sets and error correction — and in the Arena, whose Co<sub>0</sub>/M<sub>24</sub> orbit
              operations recognize contents equal up to the lattice's symmetry group.
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
    <section className={styles.section}>
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

function ClosedArrows() {
  return (
    <section className={styles.section}>
      <div className={styles.sectionIn}>
        <div className={styles.panel}>
          <span className={styles.kicker}>The discipline</span>
          <h2 className={styles.h2}>An arrow carries only what its type says.</h2>
          <p className={styles.lede}>
            A morphism — a <code>move</code>, a <code>functor</code>, a <code>view</code> — is
            <strong> closed</strong>: its body may use its own parameters and top-level definitions, and nothing
            else. Capturing a local from the surrounding scope is a compile-time error, not a runtime surprise.
            The reason is the border: an arrow is bound, composed, and applied elsewhere — possibly on the far
            side of a <strong>Space</strong> boundary, in another address space — where a captured local would
            have nothing to point at. So the only thing that crosses between Spaces is a closed arrow applied to
            transported data. A plain <code>fun</code> is the opposite by design: a value combinator captures
            freely, at any nesting depth, because it lives and dies on the spot.
          </p>
          <Link className={styles.arrowlink} to="/book/arrows#arrows-are-closed">Read “Arrows are closed” <Arrow /></Link>
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
    <section className={`${styles.section} ${styles.sectionAlt}`}>
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

function Voyager() {
  return (
    <section className={`${styles.section} ${styles.sectionAlt}`}>
      <div className={styles.sectionIn}>
        <div className={styles.panel}>
          <span className={styles.kicker}>Error correction</span>
          <h2 className={styles.h2}>A list that survives bit-flips.</h2>
          <p className={styles.lede}>
            A <strong>VoyagerList</strong> stores each 12-bit payload as a 24-bit codeword of the binary
            <strong> Golay code (24,&nbsp;12,&nbsp;8)</strong> — the code the Voyager probes used to send images
            home across the solar system. Encoding and syndrome decoding run through the real mmgroup
            <code> mat24</code> tables, not a re-implementation. The code has minimum distance 8, so any
            <strong> three</strong> flipped bits in a codeword are detected and corrected on read. The Golay code
            is not decoration here: it is the combinatorial object the Leech lattice is built from, so the same
            engine that addresses sets also hardens storage against corruption.
          </p>
        </div>
      </div>
    </section>
  );
}

export default function Home() {
  return (
    <Layout title="The Topos of Programming"
            description="A topos-oriented programming language. Native via MLIR and LLVM, with a content-addressed heap and Leech-lattice sets and error correction.">
      <main className={styles.page}>
        <Banner />
        <Hero />
        <Heap />
        <Sets />
        <Voyager />
        <Topos />
        <ClosedArrows />
        <Execution />
      </main>
    </Layout>
  );
}
