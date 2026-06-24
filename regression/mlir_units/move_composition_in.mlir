// move-composition IN: @m is an IDENTITY move (source place == target place)
// and the apply_move has matching source/result section types, so the
// apply_move is elided and its uses replaced by the source value. After the
// pass `topos.apply_move` no longer appears; the `topos.move @m` declaration
// stays. Grounded in MoveComposition.cpp (identity = sourcePlace==targetPlace;
// erases apply_move when source/result types match).
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
  topos.move @m from @P to @P
  func.func @f() -> !topos.section<"P"> {
    %s = topos.section @P() : () -> !topos.section<"P">
    %r = topos.apply_move @m %s : (!topos.section<"P">) -> !topos.section<"P">
    return %r : !topos.section<"P">
  }
}
