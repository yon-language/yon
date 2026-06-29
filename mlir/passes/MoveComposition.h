//===- MoveComposition.h ----------------------------------*- C++ -*-===//
//
// Pass: erases identity topos.apply_move, where the declared move is from @P
// to @P (the lowering would render it as a trivial identity function that
// returns its input). In that case, we replace apply_move %src with %src directly.
//
// Strategy:
//   1. Walk the module, identify all identity topos.move:
//      source_place == target_place (MoveOp has no body).
//   2. For each topos.apply_move that references an identity move, replace_op
//      with the source operand.
//
// An identity move is a degenerate case but actually generatable by the
// frontend (e.g. when a Yon program declares a trivial move for documentation
// or for compatibility with a future interface).
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_MOVE_COMPOSITION_H
#define TOPOS_MOVE_COMPOSITION_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createMoveCompositionPass();
void registerMoveCompositionPass();

} // namespace topos
} // namespace mlir

#endif
