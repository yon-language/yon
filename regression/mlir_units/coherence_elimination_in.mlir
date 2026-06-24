// coherence-elimination IN: a topos.coherence whose result is unused is dead
// and gets erased. After the pass `topos.coherence` no longer appears.
// Grounded in CoherenceElimination.cpp (erases a coherence/path op when
// use_empty()). Operands are plain f64 arith constants.
module {
  func.func @f() {
    %a = arith.constant 1.0 : f64
    %b = arith.constant 2.0 : f64
    %c = topos.coherence %a, %b : (f64, f64) -> !topos.cell<2, "phi">
    return
  }
}
