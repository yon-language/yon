//===- AlgebraVerifier.cpp - algebra law verifier --------------*- C++ -*-===//

#include "passes/AlgebraVerifier.h"
#include "TopDialect.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Operation.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/raw_ostream.h"
#include <string>

using namespace mlir;
using namespace mlir::topos;

namespace {

// Algebra catalog with certified laws (theorems). Same table as the runtime
// (yon_rt_hsh.c g_alg_catalog). The laws here are the universal-algebra theorems
// that define each structure, not empirical checks.
struct CatalogEntry {
  const char *name;
  bool commutative;
  bool associative;
  bool monotone;   // a op b >= max(a,b) per generatori >= 0
  int cat_id;      // index in the runtime catalog (bridge to yon_rt_magma_from_algebra)
};

static const CatalogEntry kCatalog[] = {
    {"Additive",       true, true, true,  0},
    {"TropicalMax",    true, true, false, 1},
    {"TropicalMin",    true, true, false, 2},
    {"Multiplicative", true, true, false, 3},
    {"BooleanOr",      true, true, true,  4},
    {"BooleanAnd",     true, true, false, 5},
    {"Gcd",            true, true, false, 6},
};
static const unsigned kCatalogN = sizeof(kCatalog) / sizeof(kCatalog[0]);

static const CatalogEntry *lookupCatalog(StringRef name) {
  for (unsigned i = 0; i < kCatalogN; i++)
    if (name == kCatalog[i].name)
      return &kCatalog[i];
  return nullptr;
}

struct AlgebraVerifierPass
    : public PassWrapper<AlgebraVerifierPass, OperationPass<ModuleOp>> {

  StringRef getArgument() const final { return "algebra-verifier"; }
  StringRef getDescription() const final {
    return "Verify the declared algebraic laws of a place against the "
           "certified catalog.";
  }

  // On success this pass MATERIALIZES func.func / func.call / func.return ops
  // (the @<Place>_instantiate bridge + the yon_rt_magma_from_algebra decl), so
  // the Func (and Arith) dialects must be declared as dependencies. Without
  // this, running the pass in ISOLATION (`topos-opt --algebra-verifier`)
  // aborts with "Building op `func.func` but it isn't known in this
  // MLIRContext"; in the full pipeline it was masked because other passes had
  // already loaded Func.
  void getDependentDialects(DialectRegistry &registry) const override {
    registry.insert<func::FuncDialect, arith::ArithDialect>();
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();
    bool failed = false;
    // place verificati: (nome_place, cat_id) -> emetteremo @<Place>_instantiate
    llvm::SmallVector<std::pair<std::string, int>, 8> verified;

    module.walk([&](PlaceOp place) {
      // Cerca un'operation con attributo `algebra` nel body del place.
      for (Operation &nested : place.getBody().front()) {
        auto op = llvm::dyn_cast<OperationOp>(&nested);
        if (!op)
          continue;
        auto algAttr = op->getAttrOfType<StringAttr>("algebra");
        if (!algAttr)
          continue; // non-algebraic operation: ignore

        StringRef algName = algAttr.getValue();
        const CatalogEntry *entry = lookupCatalog(algName);
        if (!entry) {
          op->emitError() << "algebra '" << algName
                          << "' is not in the certified catalog";
          failed = true;
          continue;
        }

        // Each law DECLARED on the place must be GUARANTEED by the catalog.
        // A declared law that the catalog does not certify = error.
        if (place->hasAttr("law_commutative") && !entry->commutative) {
          place->emitError()
              << "place declares law_commutative but the algebra '" << algName
              << "' is not commutative by catalog theorem";
          failed = true;
        }
        if (place->hasAttr("law_associative") && !entry->associative) {
          place->emitError()
              << "place declares law_associative but the algebra '" << algName
              << "' is not associative by catalog theorem";
          failed = true;
        }
        if (place->hasAttr("law_monotone") && !entry->monotone) {
          place->emitError()
              << "place declares law_monotone but the algebra '" << algName
              << "' is not monotone by catalog theorem";
          failed = true;
        }

        // Verification passed: annotate the place with the certified laws (for
        // the downstream lowering). These come FROM the catalog, not from the
        // user declaration: they are the theorems, not the assertions.
        OpBuilder b(op);
        op->setAttr("certified_commutative", b.getBoolAttr(entry->commutative));
        op->setAttr("certified_associative", b.getBoolAttr(entry->associative));
        op->setAttr("certified_monotone", b.getBoolAttr(entry->monotone));

        if (!failed)
          verified.push_back({place.getSymName().str(), entry->cat_id});
      }
    });

    if (failed) {
      signalPassFailure();
      return;
    }

    // LOWERING (bidirectional): for each verified place emit a function
    // @<Place>_instantiate() -> f64 that instantiates the place as a catalog
    // Magma handle (yon_rt_magma_from_algebra(cat_id)). The place declared in
    // Yon BECOMES a runtime handle; from there all solver queries operate.
    OpBuilder mb(module.getBodyRegion());
    mb.setInsertionPointToEnd(module.getBody());
    Location loc = module.getLoc();
    Type f64 = mb.getF64Type();

    // external runtime declaration (if not already present)
    if (!module.lookupSymbol("yon_rt_magma_from_algebra")) {
      auto fnTy = mb.getFunctionType({f64}, {f64});
      auto decl = mb.create<func::FuncOp>(loc, "yon_rt_magma_from_algebra", fnTy);
      decl.setPrivate();
    }

    for (auto &pr : verified) {
      std::string fname = pr.first + "_instantiate";
      if (module.lookupSymbol(fname))
        continue;
      auto fnTy = mb.getFunctionType({}, {f64});
      auto fn = mb.create<func::FuncOp>(loc, fname, fnTy);
      Block *entry = fn.addEntryBlock();
      OpBuilder fb(entry, entry->end());
      // cat_id as an f64 constant
      auto cst = fb.create<arith::ConstantOp>(
          loc, f64, fb.getF64FloatAttr((double)pr.second));
      auto call = fb.create<func::CallOp>(
          loc, "yon_rt_magma_from_algebra", TypeRange{f64}, ValueRange{cst});
      fb.create<func::ReturnOp>(loc, call.getResult(0));
    }
  }
};

} // namespace

std::unique_ptr<Pass> mlir::topos::createAlgebraVerifierPass() {
  return std::make_unique<AlgebraVerifierPass>();
}

void mlir::topos::registerAlgebraVerifierPass() {
  PassRegistration<AlgebraVerifierPass>();
}
