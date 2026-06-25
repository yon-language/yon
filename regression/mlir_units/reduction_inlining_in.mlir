// reduction-inlining IN: a topos.with_handler whose body contains NO
// topos.op_apply is a runtime no-op (the push/pop of the handler is never
// observed), so the pass inlines the body in place and erases the
// with_handler. After the pass NO `topos.with_handler` op remains; the inner
// op (here a pure topos.heyt constant) survives as the inlined body.
// Grounded in ReductionInlining.cpp InlineEmptyHandler (matches when
// getBody() has no OpApplyOp -> inlineBlockBefore + eraseOp) and TopOps.td
// Topos_WithHandlerOp (assemblyFormat: $reduction (`of` $of_place)?
// attr-dict-with-keyword $body ; SizedRegion<1>, SingleBlock, NoTerminator).
module {
  func.func @f() {
    topos.with_handler @R {
      %a = topos.heyt true : !topos.proposition
    }
    return
  }
}
