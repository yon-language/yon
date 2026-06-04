//===- MoveComposition.cpp ----------------------------*- C++ -*-===//

#include "passes/MoveComposition.h"
#include "TopDialect.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/StringSet.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

// Identifica le move identity: source_place == target_place.
// MoveOp is a pure declaration (no body): every move where source and target
// coincide is identity by construction. If in the future we need "same place"
// moves with a non-identity Co_0 word (e.g. an internal permutation), an
// explicit `co0_word` attribute will have to be added. For now
// source==target => identity.
static bool isIdentityMove(MoveOp m) {
  return m.getSourcePlace() == m.getTargetPlace();
}

struct MoveCompositionPass
    : public PassWrapper<MoveCompositionPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(MoveCompositionPass)

  StringRef getArgument() const final { return "move-composition"; }
  StringRef getDescription() const final {
    return "Elide topos.apply_move calls to identity moves";
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();

    // Step 1: collect the names of the identity moves.
    llvm::StringSet<> identityMoves;
    module.walk([&](MoveOp m) {
      if (isIdentityMove(m)) {
        identityMoves.insert(m.getSymName());
      }
    });

    if (identityMoves.empty()) return;

    // Step 2: for each apply_move that references an identity move,
    // sostituisci con il source operand. Raccogliamo prima per
    // evitare invalidate-iterator.
    SmallVector<ApplyMoveOp, 8> toReplace;
    module.walk([&](ApplyMoveOp a) {
      if (identityMoves.contains(a.getMove())) {
        // To be safe we also check that the source and result types match.
        // For identity moves they should, but the dialect's current signature
        // verifies it via assemblyFormat (functional-type) — better to be
        // explicit.
        if (a.getSource().getType() == a.getResult().getType()) {
          toReplace.push_back(a);
        }
      }
    });

    OpBuilder builder(module.getContext());
    for (ApplyMoveOp a : toReplace) {
      a.getResult().replaceAllUsesWith(a.getSource());
      a->erase();
    }
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createMoveCompositionPass() {
  return std::make_unique<MoveCompositionPass>();
}

void registerMoveCompositionPass() {
  PassRegistration<MoveCompositionPass>();
}

} // namespace topos
} // namespace mlir
