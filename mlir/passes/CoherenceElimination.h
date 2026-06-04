//===- CoherenceElimination.h -----------------------------*- C++ -*-===//
//
// Pass: erases topos.coherence and topos.path that have no semantic runtime
// effect. They are type evidence already consumed by the type checker. A
// structural forward DCE:
//
//   - coherence/path with no uses -> erase
//   - coherence/path whose witness is used only by dead coherence/path ->
//     recursive erase (fixpoint)
//
// The elimination is safe because:
//   - both ops are Pure (no side effects)
//   - the !topos.cell types are erased in the lowering in any case
//   - the semantic value of equivalence was already verified by the OCaml type
//     checker before the MLIR emit
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_COHERENCE_ELIMINATION_H
#define TOPOS_COHERENCE_ELIMINATION_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createCoherenceEliminationPass();
void registerCoherenceEliminationPass();

} // namespace topos
} // namespace mlir

#endif
