//===- WorldSpecialization.h ------------------------------*- C++ -*-===//
//
// Pass: identifies single-world modules (a single topos.world) and marks the
// topos.place with the attribute `static_world` for consumption by downstream
// passes. When the module has exactly one WorldOp, cross-world routing at
// runtime is not necessary.
//
// Observable output: each PlaceOp gains an attribute
// `topos.static_world = @<world_name>`. Future passes can use this mark to skip
// world residency checks.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_WORLD_SPECIALIZATION_H
#define TOPOS_WORLD_SPECIALIZATION_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createWorldSpecializationPass();
void registerWorldSpecializationPass();

} // namespace topos
} // namespace mlir

#endif
