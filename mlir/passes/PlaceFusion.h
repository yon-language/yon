//===- PlaceFusion.h --------------------------------------*- C++ -*-===//
//
// Pass: fuses structurally equivalent topos.place in the same world. Two places
// are equivalent if they have:
//   - the same fields (name, type, order)
//   - the same operations (name, arg_types, result_type)
//   - the same cells (name, dimension)
//   - the same attributes (with_effects)
// They are NON-equivalent if they have `over` (slice category) — they are kept
// separate so as not to lose categorical semantics.
//
// When two places are equivalent, we choose a canonical one (the first by
// ordered sym_name) and rewrite:
//   - all !topos.section<"P_dup"> -> !topos.section<"P_canon">
//   - all FlatSymbolRefAttr pointing to P_dup -> P_canon
//     (in topos.op_apply: instance type;
//      in topos.move: source_place/target_place;
//      in topos.reduce: of_place;
//      in topos.topology: of_place;
//      in topos.pullback/pushout: f, g — if they reference a place, but these
//      normally reference moves, not places.)
//
// The duplicate PlaceOps are erased at the end.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_PLACE_FUSION_H
#define TOPOS_PLACE_FUSION_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createPlaceFusionPass();
void registerPlaceFusionPass();

} // namespace topos
} // namespace mlir

#endif
