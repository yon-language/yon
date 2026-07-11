//===- HeytingShortCircuit.cpp ----------------------------*- C++ -*-===//

#include "passes/HeytingShortCircuit.h"
#include "TopDialect.h"

#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

// Helper: extracts the HeytingValue from a Value if it is defined by a HeytOp.
// Returns std::nullopt if it is not a constant.
static std::optional<HeytingValue> matchHeytConstant(Value v) {
  if (auto def = v.getDefiningOp<HeytOp>()) {
    return def.getValue();
  }
  return std::nullopt;
}

// Helper: crea una HeytOp costante.
static Value createHeytConst(PatternRewriter &rewriter, Location loc,
                             HeytingValue val) {
  return rewriter.create<HeytOp>(loc, val);
}

//===----------------------------------------------------------------------===//
// AND patterns
//===----------------------------------------------------------------------===//

// AND(x, x) -> x       (idempotence)
// AND(x, T) -> x        AND(T, x) -> x       (AND identity)
// AND(x, F) -> F        AND(F, x) -> F       (annihilator F)
// AND(c1, c2) -> fold   (entrambe costanti)
struct CanonicalizeHeytAnd : public OpRewritePattern<HeytAndOp> {
  using OpRewritePattern<HeytAndOp>::OpRewritePattern;
  LogicalResult matchAndRewrite(HeytAndOp op,
                                PatternRewriter &rewriter) const override {
    Value lhs = op.getLhs();
    Value rhs = op.getRhs();

    // Idempotenza: AND(x, x) -> x
    if (lhs == rhs) {
      rewriter.replaceOp(op, lhs);
      return success();
    }

    auto lhsConst = matchHeytConstant(lhs);
    auto rhsConst = matchHeytConstant(rhs);

    // Fold completo: entrambe costanti.
    if (lhsConst && rhsConst) {
      HeytingValue result;
      // Table: F dominates; T is neutral; U follows its own semantics.
      if (*lhsConst == HeytingValue::False || *rhsConst == HeytingValue::False)
        result = HeytingValue::False;
      else if (*lhsConst == HeytingValue::True)
        result = *rhsConst;
      else if (*rhsConst == HeytingValue::True)
        result = *lhsConst;
      else
        result = HeytingValue::Unknown;
      rewriter.replaceOp(op, createHeytConst(rewriter, op.getLoc(), result));
      return success();
    }

    // Annichilatore F: AND(x, F) -> F, AND(F, x) -> F
    if (lhsConst == HeytingValue::False || rhsConst == HeytingValue::False) {
      rewriter.replaceOp(op,
          createHeytConst(rewriter, op.getLoc(), HeytingValue::False));
      return success();
    }

    // Identity: AND(x, T) -> x, AND(T, x) -> x
    if (rhsConst == HeytingValue::True) {
      rewriter.replaceOp(op, lhs);
      return success();
    }
    if (lhsConst == HeytingValue::True) {
      rewriter.replaceOp(op, rhs);
      return success();
    }

    return failure();
  }
};

//===----------------------------------------------------------------------===//
// OR patterns
//===----------------------------------------------------------------------===//

struct CanonicalizeHeytOr : public OpRewritePattern<HeytOrOp> {
  using OpRewritePattern<HeytOrOp>::OpRewritePattern;
  LogicalResult matchAndRewrite(HeytOrOp op,
                                PatternRewriter &rewriter) const override {
    Value lhs = op.getLhs();
    Value rhs = op.getRhs();

    if (lhs == rhs) {
      rewriter.replaceOp(op, lhs);
      return success();
    }

    auto lhsConst = matchHeytConstant(lhs);
    auto rhsConst = matchHeytConstant(rhs);

    if (lhsConst && rhsConst) {
      HeytingValue result;
      if (*lhsConst == HeytingValue::True || *rhsConst == HeytingValue::True)
        result = HeytingValue::True;
      else if (*lhsConst == HeytingValue::False)
        result = *rhsConst;
      else if (*rhsConst == HeytingValue::False)
        result = *lhsConst;
      else
        result = HeytingValue::Unknown;
      rewriter.replaceOp(op, createHeytConst(rewriter, op.getLoc(), result));
      return success();
    }

    // Annichilatore T: OR(x, T) -> T, OR(T, x) -> T
    if (lhsConst == HeytingValue::True || rhsConst == HeytingValue::True) {
      rewriter.replaceOp(op,
          createHeytConst(rewriter, op.getLoc(), HeytingValue::True));
      return success();
    }

    // Identity: OR(x, F) -> x, OR(F, x) -> x
    if (rhsConst == HeytingValue::False) {
      rewriter.replaceOp(op, lhs);
      return success();
    }
    if (lhsConst == HeytingValue::False) {
      rewriter.replaceOp(op, rhs);
      return success();
    }

    return failure();
  }
};

//===----------------------------------------------------------------------===//
// NOT patterns
//===----------------------------------------------------------------------===//

// NOT(NOT(x)) -> x
// NOT(c) -> fold (T->F, F->T, U->U)
struct CanonicalizeHeytNot : public OpRewritePattern<HeytNotOp> {
  using OpRewritePattern<HeytNotOp>::OpRewritePattern;
  LogicalResult matchAndRewrite(HeytNotOp op,
                                PatternRewriter &rewriter) const override {
    Value operand = op.getOperand();

    // NB: NO double-negation elimination here. In a Heyting algebra
    // neg neg x >= x but neg neg x != x in general (e.g. neg neg unknown =
    // present > unknown), so NOT(NOT(x)) -> x is UNSOUND. It was removed when
    // the connectives were corrected from Kleene to the Gödel G3 Heyting
    // algebra.

    // Fold di costante: NOT(c) = c -> bot (regular Heyting negation).
    if (auto c = matchHeytConstant(operand)) {
      HeytingValue result;
      switch (*c) {
      case HeytingValue::True:    result = HeytingValue::False;   break;
      case HeytingValue::False:   result = HeytingValue::True;    break;
      // neg unknown = unknown -> bot = absent (False), NOT unknown: the
      // negation is regular, not involutive.
      case HeytingValue::Unknown: result = HeytingValue::False;   break;
      }
      rewriter.replaceOp(op, createHeytConst(rewriter, op.getLoc(), result));
      return success();
    }

    return failure();
  }
};

//===----------------------------------------------------------------------===//
// IMPLIES patterns
//===----------------------------------------------------------------------===//
// IMPLIES(F, x) = T      (ex falso quodlibet, tri-valued)
// IMPLIES(x, T) = T
// IMPLIES(T, x) = x
// IMPLIES(c1, c2) = fold via tabella standard intuizionistica tri-valued

struct CanonicalizeHeytImplies : public OpRewritePattern<HeytImpliesOp> {
  using OpRewritePattern<HeytImpliesOp>::OpRewritePattern;
  LogicalResult matchAndRewrite(HeytImpliesOp op,
                                PatternRewriter &rewriter) const override {
    Value lhs = op.getLhs();
    Value rhs = op.getRhs();

    // IMPLIES(x, x) = T (reflexivity)
    if (lhs == rhs) {
      rewriter.replaceOp(op,
          createHeytConst(rewriter, op.getLoc(), HeytingValue::True));
      return success();
    }

    auto lhsConst = matchHeytConstant(lhs);
    auto rhsConst = matchHeytConstant(rhs);

    if (lhsConst && rhsConst) {
      HeytingValue result;
      // Tabella IMPLIES tri-valued (Gödel G3 Heyting residual):
      //   a -> b = T  if a <= b (on absent < unknown < present), else b
      //   T -> T = T,  T -> F = F,  T -> U = U
      //   F -> ? = T  (ex falso)
      //   U -> T = T,  U -> U = T  (a -> a = top),  U -> F = F
      if (*lhsConst == HeytingValue::False)
        result = HeytingValue::True;
      else if (*rhsConst == HeytingValue::True)
        result = HeytingValue::True;
      else if (*lhsConst == HeytingValue::True)
        result = *rhsConst;
      else { // lhs = U : U -> b = (b = F) ? F : T
        if (*rhsConst == HeytingValue::False) result = HeytingValue::False;
        else                                   result = HeytingValue::True;
      }
      rewriter.replaceOp(op, createHeytConst(rewriter, op.getLoc(), result));
      return success();
    }

    // IMPLIES(F, x) = T always.
    if (lhsConst == HeytingValue::False) {
      rewriter.replaceOp(op,
          createHeytConst(rewriter, op.getLoc(), HeytingValue::True));
      return success();
    }

    // IMPLIES(x, T) = T always.
    if (rhsConst == HeytingValue::True) {
      rewriter.replaceOp(op,
          createHeytConst(rewriter, op.getLoc(), HeytingValue::True));
      return success();
    }

    // IMPLIES(T, x) = x
    if (lhsConst == HeytingValue::True) {
      rewriter.replaceOp(op, rhs);
      return success();
    }

    return failure();
  }
};

//===----------------------------------------------------------------------===//
// Pass
//===----------------------------------------------------------------------===//

struct HeytingShortCircuitPass
    : public PassWrapper<HeytingShortCircuitPass, OperationPass<>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(HeytingShortCircuitPass)

  StringRef getArgument() const final { return "heyting-short-circuit"; }
  StringRef getDescription() const final {
    return "Canonicalize Heyting tri-valued ops via algebraic identities";
  }

  void runOnOperation() override {
    Operation *op = getOperation();
    MLIRContext *ctx = &getContext();
    RewritePatternSet patterns(ctx);
    patterns.add<CanonicalizeHeytAnd,
                 CanonicalizeHeytOr,
                 CanonicalizeHeytNot,
                 CanonicalizeHeytImplies>(ctx);
    if (failed(applyPatternsAndFoldGreedily(op, std::move(patterns)))) {
      op->emitError("heyting-short-circuit pass failed");
      signalPassFailure();
    }
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createHeytingShortCircuitPass() {
  return std::make_unique<HeytingShortCircuitPass>();
}

void registerHeytingShortCircuitPass() {
  PassRegistration<HeytingShortCircuitPass>();
}

} // namespace topos
} // namespace mlir
