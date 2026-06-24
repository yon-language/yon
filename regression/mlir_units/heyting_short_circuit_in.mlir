// heyting-short-circuit IN: AND of two Heyting constants (true, false) is a
// constant-fold target. After the pass the topos.heyt_and op is rewritten to a
// bare topos.heyt constant (false), so `topos.heyt_and` no longer appears.
// Grounded in HeytingShortCircuit.cpp CanonicalizeHeytAnd (both-constant fold,
// AND(x,false)->false). Stays within the topos dialect (canonicalizer).
module {
  func.func @f() -> !topos.proposition {
    %a = topos.heyt true : !topos.proposition
    %b = topos.heyt false : !topos.proposition
    %r = topos.heyt_and %a, %b : !topos.proposition
    return %r : !topos.proposition
  }
}
