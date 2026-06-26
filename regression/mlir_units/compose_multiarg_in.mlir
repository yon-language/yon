// compose-reductions with a MULTI-INPUT `right` component (red->green for the
// LowerToposExtensions generalization). The composition `C = left o right`
// here is `R2 o R1` where `right` = R1 has TWO inputs and one result, and
// `left` = R2 is unary. Pre-fix the pass rejected this with [TOPOS-E0803]
// ("each component reduction must be unary"); post-fix it composes:
// `@C__reduce(%a, %b) = R2(R1(%a, %b))`, taking ALL of right's inputs and
// returning left's result, and erases the topos.compose_reductions op.
//
// The pass resolves each component by the `<name>__reduce` func.func that
// MaterializeReduceOp would have emitted; here we provide them directly.
module {
  // right: 2 inputs -> 1 result (the multi-argument component, now allowed).
  func.func @R1__reduce(%a: f64, %b: f64) -> f64 {
    %s = arith.addf %a, %b : f64
    return %s : f64
  }
  // left: unary; its single input == right's single result (f64).
  func.func @R2__reduce(%x: f64) -> f64 {
    return %x : f64
  }
  topos.compose_reductions @C = @R2 compose @R1
}
