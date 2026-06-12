//===- StructuralVN.h - structural value numbering -------------*- C++ -*-===//
//
// Pass: structure-guided global value numbering (a structural CSE).
// Two Pure operations with the same name, the same operands (by SSA identity),
// the same attributes and the same result types compute the same value: the
// second and later ones are replaced by the first (canonical) one, and erased.
// This eliminates the redundant recomputations.
//
// Primary target: topos.field_load from the same section on the same field,
// but the pass is general over any Pure op without side effects and without
// regions.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_STRUCTURAL_VN_H
#define TOPOS_STRUCTURAL_VN_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createStructuralVNPass();
void registerStructuralVNPass();

} // namespace topos
} // namespace mlir

#endif
