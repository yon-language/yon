// ccc-equations-check REJECT: heyt_and with a literal True operand should
// have been folded -> [TOPOS-E0451]. Grounded in CCCEquationsCheck.cpp
// (HeytAndOp branch, lc/rc == HeytingValue::True).
module {
  func.func @f(%a: !topos.proposition) -> !topos.proposition {
    %t = topos.heyt true : !topos.proposition
    %r = topos.heyt_and %a, %t : !topos.proposition
    return %r : !topos.proposition
  }
}
