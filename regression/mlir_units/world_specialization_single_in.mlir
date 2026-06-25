// world-specialization SINGLE: the module has exactly ONE topos.world, so the
// pass marks every topos.place with a `topos.static_world` attribute pointing
// at that world. After the pass `topos.static_world` appears on @P.
// Grounded in WorldSpecialization.cpp (worlds.size()==1 -> setAttr
// "topos.static_world" = FlatSymbolRefAttr(worldName) on each PlaceOp).
module {
  topos.world @W {
    topos.place @P in @W attributes {with_effects} {
      topos.field @x : f64
    }
  }
}
