//===- CPSConversion.cpp ------------------------------*- C++ -*-===//

#include "passes/CPSConversion.h"
#include "TopDialect.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/SmallVector.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

// Identifies an "apply_move chain" in `block`. The chain starts at the first
// apply_move that is NOT already part of an identified chain (tracked via the
// processed set, managed by the caller). It extends while the next op is
// another apply_move that uses exclusively the previous one's result.
//
// Returns the ordered chain. Length >= 2 because a chain of 1 is a single apply
// that CPS does not help.
static SmallVector<ApplyMoveOp> findChain(
    Block &block,
    const llvm::DenseSet<Operation*> &processed) {

  SmallVector<ApplyMoveOp> chain;

  for (Operation &op : block) {
    auto first = dyn_cast<ApplyMoveOp>(&op);
    if (!first) continue;
    if (processed.contains(&op)) continue;

    SmallVector<ApplyMoveOp> candidate;
    candidate.push_back(first);

    ApplyMoveOp last = first;
    Operation *nextOp = last->getNextNode();
    while (nextOp) {
      auto am = dyn_cast<ApplyMoveOp>(nextOp);
      if (!am) break;
      if (processed.contains(nextOp)) break;
      if (am.getSource() != last.getResult()) break;
      // The intermediate result must have ONLY one use (am itself), otherwise
      // we cannot confine it to the scope.
      if (!last.getResult().hasOneUse()) break;
      candidate.push_back(am);
      last = am;
      nextOp = last->getNextNode();
    }

    if (candidate.size() >= 2) {
      return candidate;
    }
  }

  return chain;  // empty
}

// Trasforma la chain in:
//
//   %final_outside = topos.scope_with_yield (%source : srcTy)
//                                            -> finalTy {
//   ^bb0(%cap_source: srcTy):
//     %y1 = topos.apply_move @M1 %cap_source : ...
//     %y2 = topos.apply_move @M2 %y1 : ...
//     ...
//     %yn = topos.apply_move @Mn %y_{n-1} : ...
//     topos.scope_yield %yn : finalTy
//   }
//
// All original uses of %yn (= chain.back().getResult()) in the block are
// redirected to %final_outside.
static void cpsConvertChain(OpBuilder &builder,
                              const SmallVector<ApplyMoveOp> &chain) {
  ApplyMoveOp first = chain.front();
  ApplyMoveOp last = chain.back();

  Value origSource = first.getSource();
  Type sourceTy = origSource.getType();
  Type finalTy = last.getResult().getType();
  Location loc = first.getLoc();

  // Crea lo scope_with_yield prima di first apply.
  builder.setInsertionPoint(first);

  auto scope = builder.create<ScopeWithYieldOp>(
      loc, TypeRange{finalTy}, ValueRange{origSource});

  // Body region with a block that has one argument (for the capture).
  Block &body = scope.getBody().emplaceBlock();
  body.addArgument(sourceTy, loc);
  Value capturedSource = body.getArgument(0);

  builder.setInsertionPointToEnd(&body);

  // Clone (actually move) each apply_move into the body, remapping the source
  // argument of the first from %origSource to %capturedSource; the intermediate
  // values stay valid because MoveOp result -> next MoveOp source.
  IRMapping mapping;
  mapping.map(origSource, capturedSource);

  Value lastResultInScope;
  for (ApplyMoveOp am : chain) {
    // Clone the op, remapping the source.
    Operation *cloned = builder.clone(*am.getOperation(), mapping);
    auto newApply = cast<ApplyMoveOp>(cloned);
    // Mappa il vecchio result -> nuovo result (per il prossimo iter).
    mapping.map(am.getResult(), newApply.getResult());
    lastResultInScope = newApply.getResult();
  }

  // Yielda l'ultimo result.
  builder.create<ScopeYieldOp>(loc, lastResultInScope);

  // Reindirizza tutti gli usi del result originale di last.
  last.getResult().replaceAllUsesWith(scope.getResult(0));

  // Cancella le apply_move originali.
  for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
    (*it)->erase();
  }
}

struct CPSConversionPass
    : public PassWrapper<CPSConversionPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(CPSConversionPass)

  StringRef getArgument() const final { return "topos-cps-conversion"; }
  StringRef getDescription() const final {
    return "CPS conversion of apply_move chains into scope_with_yield";
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();
    OpBuilder builder(module.getContext());

    SmallVector<func::FuncOp> targets;
    module.walk([&](func::FuncOp fn) {
      if (!fn->hasAttr("topos.cps_converted") && !fn.empty())
        targets.push_back(fn);
    });

    int totalConverted = 0;
    for (func::FuncOp fn : targets) {
      bool anyChain = false;
      llvm::DenseSet<Operation*> processed;

      // Iterate until no more chains are found. Chains in different blocks are
      // independent; the same block may have several non-adjacent chains that
      // we handle one at a time.
      for (int iter = 0; iter < 256; ++iter) {
        SmallVector<ApplyMoveOp> chain;
        for (Block &block : fn.getBody()) {
          chain = findChain(block, processed);
          if (!chain.empty()) break;
        }
        if (chain.empty()) break;

        // Mark the applies we are converting as processed BEFORE the
        // conversion (for safety in case of re-walk).
        for (ApplyMoveOp am : chain) {
          processed.insert(am.getOperation());
        }

        cpsConvertChain(builder, chain);
        anyChain = true;
        ++totalConverted;
      }

      if (anyChain) {
        fn->setAttr("topos.cps_converted",
                    UnitAttr::get(module.getContext()));
      }
    }

    (void)totalConverted;
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createCPSConversionPass() {
  return std::make_unique<CPSConversionPass>();
}

void registerCPSConversionPass() {
  PassRegistration<CPSConversionPass>();
}

} // namespace topos
} // namespace mlir
