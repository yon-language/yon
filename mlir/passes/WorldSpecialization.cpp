//===- WorldSpecialization.cpp ------------------------*- C++ -*-===//

#include "passes/WorldSpecialization.h"
#include "TopDialect.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

struct WorldSpecializationPass
    : public PassWrapper<WorldSpecializationPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(WorldSpecializationPass)

  StringRef getArgument() const final { return "world-specialization"; }
  StringRef getDescription() const final {
    return "Mark places with static_world when module has a single world";
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();

    // Step 1: conta le WorldOp.
    SmallVector<WorldOp, 2> worlds;
    module.walk([&](WorldOp w) { worlds.push_back(w); });

    if (worlds.size() != 1) {
      // Multi-world: nessuna specializzazione applicabile.
      return;
    }

    StringRef worldName = worlds[0].getSymName();
    MLIRContext *ctx = &getContext();
    auto worldRef = FlatSymbolRefAttr::get(ctx, worldName);

    // Step 2: mark each PlaceOp with topos.static_world.
    unsigned marked = 0;
    module.walk([&](PlaceOp place) {
      // Skip if already marked (idempotent).
      if (place->hasAttr("topos.static_world")) return;
      place->setAttr("topos.static_world", worldRef);
      ++marked;
    });

    // Diagnostic minimale visibile in mlir-print-ir-after-all se richiesto.
    if (marked == 0) return;
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createWorldSpecializationPass() {
  return std::make_unique<WorldSpecializationPass>();
}

void registerWorldSpecializationPass() {
  PassRegistration<WorldSpecializationPass>();
}

} // namespace topos
} // namespace mlir
