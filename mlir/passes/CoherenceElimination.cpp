//===- CoherenceElimination.cpp -----------------------*- C++ -*-===//

#include "passes/CoherenceElimination.h"
#include "TopDialect.h"

#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

// Erase coherence/path with no uses. The greedy driver with this pattern
// iterates to the fixpoint, eliminating cascades. If some coherence
// with uses, it stays in the module (it will be erased in lowering if its
// consumers disappear).
struct EraseDeadCoherence : public OpRewritePattern<CoherenceOp> {
  using OpRewritePattern<CoherenceOp>::OpRewritePattern;
  LogicalResult matchAndRewrite(CoherenceOp op,
                                PatternRewriter &rewriter) const override {
    if (!op->use_empty()) return failure();
    rewriter.eraseOp(op);
    return success();
  }
};

struct EraseDeadPath : public OpRewritePattern<PathOp> {
  using OpRewritePattern<PathOp>::OpRewritePattern;
  LogicalResult matchAndRewrite(PathOp op,
                                PatternRewriter &rewriter) const override {
    if (!op->use_empty()) return failure();
    rewriter.eraseOp(op);
    return success();
  }
};

struct CoherenceEliminationPass
    : public PassWrapper<CoherenceEliminationPass, OperationPass<>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(CoherenceEliminationPass)

  StringRef getArgument() const final { return "coherence-elimination"; }
  StringRef getDescription() const final {
    return "Eliminate dead topos.coherence and topos.path";
  }

  void runOnOperation() override {
    MLIRContext *ctx = &getContext();
    RewritePatternSet patterns(ctx);
    patterns.add<EraseDeadCoherence, EraseDeadPath>(ctx);
    if (failed(applyPatternsAndFoldGreedily(getOperation(),
                                            std::move(patterns)))) {
      getOperation()->emitError("coherence-elimination pass failed");
      signalPassFailure();
    }
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createCoherenceEliminationPass() {
  return std::make_unique<CoherenceEliminationPass>();
}

void registerCoherenceEliminationPass() {
  PassRegistration<CoherenceEliminationPass>();
}

} // namespace topos
} // namespace mlir
