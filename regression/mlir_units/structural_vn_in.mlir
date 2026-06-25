// structural-value-numbering IN: two structurally identical Pure ops
// (`topos.heyt_and %a, %b`) within one block compute the same value, so the
// second is collapsed onto the first and erased; the consumer (`topos.heyt_or`)
// is rewired to the surviving result. After the pass the second heyt_and is
// gone (only ONE `topos.heyt_and` remains) and the pass prints
// "collassate 1 operazioni" to stderr.
// Grounded in StructuralVN.cpp (isCollapsible: 1 result, 0 regions, Pure trait;
// computeOpFingerprint matches identical name+operands+attrs+result types;
// duplicate -> replaceAllUsesWith + erase; emits the stderr tally). heyt_and is
// Pure (TopOps.td Topos_HeytAndOp) and uses identical SSA operands %a, %b.
module {
  func.func @f() -> !topos.proposition {
    %a = topos.heyt true : !topos.proposition
    %b = topos.heyt false : !topos.proposition
    %r1 = topos.heyt_and %a, %b : !topos.proposition
    %r2 = topos.heyt_and %a, %b : !topos.proposition
    %o = topos.heyt_or %r1, %r2 : !topos.proposition
    return %o : !topos.proposition
  }
}
