// topos-giraud-check REJECT: world @W has a valid (1-block) body but ZERO
// topos.place -> [TOPOS-E0501] (Giraud: a world needs a small generating
// family; an empty world cannot serve). WorldOp is SizedRegion<1>+NoTerminator,
// so an empty `{ }` parses as 0 blocks and trips the op verifier BEFORE the
// pass; the generic form with an explicit empty block ^bb0 gives exactly one
// placeless block, which is what the pass is meant to reject.
module {
  "topos.world"() ({
  ^bb0:
  }) {sym_name = "W"} : () -> ()
}
