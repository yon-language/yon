// place-fusion IN: @P_a and @P_b are structurally identical places (same world,
// same with_effects flag, same field set). They fuse into the lex-smallest name
// @P_a; @P_b is erased and references rewritten. After the pass `@P_b` no longer
// appears and `@P_a` remains. Grounded in PlaceFusion.cpp (structural
// fingerprint excludes sym_name; canonical = lexicographically smallest name).
module {
  topos.world @W {
    topos.place @P_a in @W attributes {with_effects} {
      topos.field @x : f64
    }
    topos.place @P_b in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.move @m from @P_a to @P_b
}
