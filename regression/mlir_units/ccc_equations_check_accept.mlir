// ccc-equations-check ACCEPT: heyt_and of two DISTINCT, non-constant
// proposition values (block args) is already in normal form, so none of the
// CCC-equation diagnostics fire. Grounded in CCCEquationsCheck.cpp
// (matchHeytConst only matches topos.heyt constants; sameValue compares SSA).
module {
  func.func @f(%a: !topos.proposition, %b: !topos.proposition) -> !topos.proposition {
    %r = topos.heyt_and %a, %b : !topos.proposition
    return %r : !topos.proposition
  }
}
