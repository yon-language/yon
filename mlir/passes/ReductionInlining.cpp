//===- ReductionInlining.cpp --------------------------*- C++ -*-===//

#include "passes/ReductionInlining.h"
#include "TopDialect.h"

#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

// Verifica se la region di un with_handler contiene op_apply
// (eventualmente nested in altre strutture).
static bool containsOpApply(Region &region) {
  bool found = false;
  region.walk([&](OpApplyOp /*op*/) {
    found = true;
    return WalkResult::interrupt();
  });
  return found;
}

// Pattern: with_handler con body privo di op_apply -> inline del body.
// Il push/pop sarebbe stato no-op a runtime.
struct InlineEmptyHandler : public OpRewritePattern<WithHandlerOp> {
  using OpRewritePattern<WithHandlerOp>::OpRewritePattern;
  LogicalResult matchAndRewrite(WithHandlerOp op,
                                PatternRewriter &rewriter) const override {
    if (op.getBody().empty()) {
      rewriter.eraseOp(op);
      return success();
    }
    if (containsOpApply(op.getBody())) {
      return failure(); // there is op_apply, the handler is actually needed
    }

    // Inline del body al posto del with_handler.
    Block &srcBlock = op.getBody().front();
    Block *destBlock = op->getBlock();
    auto insertPt = op->getIterator();
    rewriter.inlineBlockBefore(&srcBlock, destBlock, insertPt);
    rewriter.eraseOp(op);
    return success();
  }
};

struct ReductionInliningPass
    : public PassWrapper<ReductionInliningPass, OperationPass<>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(ReductionInliningPass)

  StringRef getArgument() const final { return "reduction-inlining"; }
  StringRef getDescription() const final {
    return "Eliminate topos.with_handler with no op_apply users";
  }

  void runOnOperation() override {
    MLIRContext *ctx = &getContext();
    RewritePatternSet patterns(ctx);
    patterns.add<InlineEmptyHandler>(ctx);
    if (failed(applyPatternsAndFoldGreedily(getOperation(),
                                            std::move(patterns)))) {
      getOperation()->emitError("reduction-inlining pass failed");
      signalPassFailure();
    }
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createReductionInliningPass() {
  return std::make_unique<ReductionInliningPass>();
}

void registerReductionInliningPass() {
  PassRegistration<ReductionInliningPass>();
}

} // namespace topos
} // namespace mlir
