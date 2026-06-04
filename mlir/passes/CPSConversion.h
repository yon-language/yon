//===- CPSConversion.h (with captures) --------------------*- C++ -*-===//
//
// Pass: CPS conversion for chains of topos.apply_move.
//
// An earlier version tried to inline the intermediate values inside a
// scope_with_yield IsolatedFromAbove without captures, violating the trait.
// This version uses the `captures` mechanism added to ScopeWithYieldOp:
//
//   %a : !topos.section<"A">     (defined outside the scope)
//   %y = topos.apply_move @M1 %a : (...) -> ...
//   %z = topos.apply_move @M2 %y : (...) -> ...
//   %w = topos.apply_move @M3 %z : (...) -> ...
//
// diventa:
//
//   %w_promoted = topos.scope_with_yield (%a : !topos.section<"A">)
//                                         -> !topos.section<"D"> {
//   ^bb0(%cap_a: !topos.section<"A">):
//     %y_inner = topos.apply_move @M1 %cap_a : ...
//     %z_inner = topos.apply_move @M2 %y_inner : ...
//     %w_inner = topos.apply_move @M3 %z_inner : ...
//     topos.scope_yield %w_inner : !topos.section<"D">
//   }
//
// The transformation encapsulates a chain inside a single scope with captures,
// rather than creating N nested scopes. Concrete advantages:
//
//   (1) Arena lifetime: the single arena of the scope covers the whole chain.
//       The intermediate sections %y, %z, %w_inner live and die in the same
//       arena -> no intermediate promotion, no cross-arena copy. Only the final
//       %w is promoted.
//
//   (2) Optimization: the downstream lowering can apply a sequential
//       arena-bump-pointer optimization: each apply_move is a cursor increment.
//
//   (3) Makes the continuation explicit: chain -> a single "atomic continuation
//       block", easier to analyze for later passes (cluster collapse, place
//       fusion).
//
// The transformation applies only to chains with these requirements:
//
//   (a) >= 2 consecutive apply_move in the same block
//   (b) each intermediate result used only by the next apply
//   (c) the final result is either returned (func.return) or used after the
//       chain in the same block
//   (d) the initial source (%a) is a function argument or a value defined
//       before the chain in the block
//
// Non-conforming cases are left unchanged (conservative).
//
// Marker: attribute `topos.cps_converted` on the FuncOps touched.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_CPS_CONVERSION_H
#define TOPOS_CPS_CONVERSION_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createCPSConversionPass();
void registerCPSConversionPass();

} // namespace topos
} // namespace mlir

#endif
