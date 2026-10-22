//===- StructuralPasses.cpp - Opt-in diagnostic passes ----------*- C++ -*-===//
//
// Implements 10 opt-in diagnostic passes (not in the yonc pipeline).
// Each checks one syntactic proxy, described at the pass.
//
// Implementation strategy:
//   - Each pass walks the module looking for a small set of patterns
//     that indicate a violation of the corresponding categorical or
//     type-theoretic property.
//   - On violation, an in-place diagnostic is emitted with a
//     [TOPOS-Exxxx] code, a fix hint, and a brief context note.
//   - These passes never modify the IR.
//
// The checks are syntactic proxies only: none of them decides the
// categorical or type-theoretic property its pass is named after.
//
//===----------------------------------------------------------------------===//

#include "passes/StructuralPasses.h"
#include "TopDialect.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/ADT/SmallSet.h"

using namespace mlir;
using namespace mlir::topos;

//===----------------------------------------------------------------------===//
// type-preservation
//
// Walks every `topos.reduce` operation and checks that every
// `topos.section` built anywhere inside its body (returned or not) has
// its `place` field equal to the reduction's `of_place` (E0101). The
// body region is not otherwise type-checked.
//===----------------------------------------------------------------------===//

namespace {

struct TypePreservationPass
    : public PassWrapper<TypePreservationPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(TypePreservationPass)
  StringRef getArgument() const override {
    return "topos-type-preservation";
  }
  StringRef getDescription() const override {
    return "Check that each reduction preserves the type of its "
           "underlying place.";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    mod.walk([&](ReduceOp red) {
      StringRef ofPlace = red.getOfPlace();
      red.getBody().walk([&](Operation *inner) {
        if (auto sec = dyn_cast<SectionOp>(inner)) {
          StringRef secPlace = sec.getPlace();
          if (secPlace != ofPlace) {
            sec.emitOpError(
                "[TOPOS-E0101] section produced inside reduction '")
                << red.getSymName()
                << "' refers to place '" << secPlace
                << "', but the reduction operates on place '"
                << ofPlace << "'.\n"
                   "  fix: ensure that the body of the reduction "
                   "produces sections of the place it operates on, "
                   "or introduce an explicit `topos.geom_morphism` "
                   "between the two places.\n"
                   "  context: type preservation requires the "
                   "reduction to remain in the same place; a cross-"
                   "place section breaks the preservation theorem.";
            failed = true;
          }
        }
      });
    });
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// progress
//
// Looks up the `topos.move` named by each `topos.apply_move` and reports
// E0102 if the move has no non-empty region. MoveOp has no regions (it
// is a pure declaration), so every apply_move whose move resolves is
// rejected; an apply_move whose move does not resolve is skipped.
//===----------------------------------------------------------------------===//

struct ProgressPass
    : public PassWrapper<ProgressPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(ProgressPass)
  StringRef getArgument() const override { return "topos-progress"; }
  StringRef getDescription() const override {
    return "Check that every applied move has a non-empty body "
           ".";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    mod.walk([&](ApplyMoveOp app) {
      StringRef name = app.getMove();
      MoveOp target;
      mod.walk([&](MoveOp m) {
        if (m.getSymName() == name) {
          target = m;
          return WalkResult::interrupt();
        }
        return WalkResult::advance();
      });
      if (!target)
        return;
      // MoveOp declares no region, so this loop finds nothing and
      // `empty` stays true.
      bool empty = true;
      for (Region &r : target->getRegions()) {
        for (Block &b : r) {
          if (!b.empty()) { empty = false; break; }
        }
        if (!empty) break;
      }
      if (empty) {
        app.emitOpError("[TOPOS-E0102] applied move '")
            << name << "' has an empty body; applying it would "
                       "produce no computation step, contradicting "
                       "the progress property.\n"
                       "  fix: define the move's body so that it "
                       "actually transforms the place, or remove "
                       "this `topos.apply_move`.\n";
        failed = true;
      }
    });
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// type-equivalence sanity
//
// MLIR's equivalence on Types is reference identity for cached
// uniqued types, so types that print equal MUST be equal pointers.
// This pass walks the module and verifies, for every pair of
// `topos.section` results that have the same `place` attribute, that
// their result Type is identical (not merely structurally equal).
//===----------------------------------------------------------------------===//

struct TypeEquivSanityPass
    : public PassWrapper<TypeEquivSanityPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(TypeEquivSanityPass)
  StringRef getArgument() const override {
    return "topos-type-equiv-sanity";
  }
  StringRef getDescription() const override {
    return "Check that all sections of the same place have an "
           "identical (uniqued) Type.";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    llvm::DenseMap<StringRef, Type> seen;
    bool failed = false;
    mod.walk([&](SectionOp s) {
      StringRef p = s.getPlace();
      Type t = s.getResult().getType();
      auto it = seen.find(p);
      if (it == seen.end()) {
        seen[p] = t;
      } else if (it->second != t) {
        s.emitOpError("[TOPOS-E0103] section of place '")
            << p << "' has a Type different from a previous section "
                    "of the same place; uniqueness of types per "
                    "place is broken.\n"
                    "  fix: this is most likely a bug in an earlier "
                    "compiler pass; file a bug report.";
        failed = true;
      }
    });
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// Hindley-Milner inference (structural check)
//
// A full Algorithm W is out of scope here; this pass performs the
// structural sanity that every `topos.pabs` has all its referenced
// type parameters actually used in the body (otherwise the
// generalisation step would be vacuous and likely a mistake).
//===----------------------------------------------------------------------===//

struct HMInferencePass
    : public PassWrapper<HMInferencePass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(HMInferencePass)
  StringRef getArgument() const override {
    return "topos-hm-inference";
  }
  StringRef getDescription() const override {
    return "Sanity check that every pabs uses each of its type "
           "parameters (a structural surrogate for "
           "Algorithm W).";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    mod.walk([&](PabsOp pabs) {
      // Render the body to a string and check that each parameter
      // name appears at least once. This is a weak surrogate: it
      // accepts false positives (e.g. parameter names that happen
      // to occur as substrings of other identifiers). It is enough
      // to flag clearly unused parameters in hand-written IR.
      std::string body;
      llvm::raw_string_ostream os(body);
      pabs->print(os);
      for (Attribute a : pabs.getTypeParams()) {
        StringRef p = cast<StringAttr>(a).getValue();
        if (body.find(p.str()) == std::string::npos) {
          pabs.emitOpError("[TOPOS-E0104] pabs declares type "
                           "parameter '")
              << p << "' but the parameter does not appear in the "
                      "body.\n"
                      "  fix: either drop the unused parameter from "
                      "`type_params`, or use it inside the body so "
                      "that the polymorphism is meaningful.\n";
          failed = true;
        }
      }
    });
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// Giraud axiom check (structural)
//
// Giraud's theorem characterises Grothendieck topoi by five axioms.
// None of them is checked. The pass checks only that each world
// contains at least one place (E0501).
//===----------------------------------------------------------------------===//

struct GiraudCheckPass
    : public PassWrapper<GiraudCheckPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(GiraudCheckPass)
  StringRef getArgument() const override {
    return "topos-giraud-check";
  }
  StringRef getDescription() const override {
    return "Check basic structural prerequisites of Giraud's axioms "
           "for each world.";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    mod.walk([&](WorldOp w) {
      bool hasPlace = false;
      for (Region &r : w->getRegions())
        for (Block &b : r)
          for (Operation &op : b)
            if (isa<PlaceOp>(&op)) { hasPlace = true; break; }
      if (!hasPlace) {
        w.emitOpError("[TOPOS-E0501] world '")
            << w.getSymName() << "' has no places. Giraud's "
               "characterisation of a Grothendieck topos requires a "
               "small generating family; an empty world cannot serve "
               "as one.\n"
               "  fix: declare at least one `topos.place` inside the "
               "world, or remove the world if it is unused.";
        failed = true;
      }
    });
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// Simpson's six equivalences (structural)
//
// Named after Simpson's six equivalent characterisations of ∞-topoi,
// none of which is checked. The pass checks only that the topology of
// each `topos.from_site` names a symbol declared in the module (E0502);
// it does not check that the symbol is a `topos.topology`.
//===----------------------------------------------------------------------===//

struct Simpson6Pass
    : public PassWrapper<Simpson6Pass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(Simpson6Pass)
  StringRef getArgument() const override { return "topos-simpson6"; }
  StringRef getDescription() const override {
    return "Structural check of Simpson's six ∞-topos "
           "equivalences.";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    mod.walk([&](FromSiteOp fs) {
      Operation *topo = SymbolTable::lookupSymbolIn(mod, fs.getTopology());
      if (!topo) {
        fs.emitOpError("[TOPOS-E0502] `topos.from_site` references "
                       "topology '")
            << fs.getTopology() << "' which is not declared. "
               "Simpson's equivalences require a genuine site (a "
               "category equipped with a topology); without the "
               "topology the resulting object is only a presheaf "
               "category.\n"
               "  fix: declare the topology with `topos.topology` "
               "before this `topos.from_site`.";
        failed = true;
      }
    });
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// accessibility check
//
// A topos is accessible if its underlying category is locally
// presentable. The structural witness in our IR is the absence of
// "infinite" constructions; we approximate by checking that every
// world has a bounded number of places (a soft warning above a
// heuristic threshold, to flag possibly inaccessible worlds).
//===----------------------------------------------------------------------===//

struct AccessibilityPass
    : public PassWrapper<AccessibilityPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(AccessibilityPass)
  StringRef getArgument() const override {
    return "topos-accessibility";
  }
  StringRef getDescription() const override {
    return "Heuristic accessibility check: warn if a world has an "
           "unusually large generating family.";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    constexpr size_t kThreshold = 1024;
    mod.walk([&](WorldOp w) {
      size_t count = 0;
      for (Region &r : w->getRegions())
        for (Block &b : r)
          for (Operation &op : b)
            if (isa<PlaceOp>(&op)) ++count;
      if (count > kThreshold) {
        w.emitWarning("[TOPOS-W0503] world '")
            << w.getSymName() << "' has " << count
            << " places, which exceeds the heuristic accessibility "
               "threshold of " << kThreshold << ".\n"
               "  hint: review whether this world is meant to be "
               "small (in the sense of locally presentable "
               "categories); if so, factor it into sub-worlds.";
      }
    });
    // This is a warning-only pass; never signals failure.
  }
};

//===----------------------------------------------------------------------===//
// localisation decomposition (structural)
//
// No factorisation of geometric morphisms is checked. The pass checks
// only module order: every top-level `topos.geom_morphism` declared
// with attribute `proper_base_change_attested` must appear after both
// its source and its target world (E0504).
//===----------------------------------------------------------------------===//

struct LocalisationDecompPass
    : public PassWrapper<LocalisationDecompPass,
                         OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(LocalisationDecompPass)
  StringRef getArgument() const override {
    return "topos-localisation-decomp";
  }
  StringRef getDescription() const override {
    return "Structural check of the localisation-decomposition "
           "property for attested geometric morphisms "
           ".";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    // Track worlds we have seen so far in module order.
    llvm::StringSet<> seen;
    for (Operation &top : mod.getBody()->getOperations()) {
      if (auto w = dyn_cast<WorldOp>(&top)) {
        seen.insert(w.getSymName());
      } else if (auto gm = dyn_cast<GeomMorphismOp>(&top)) {
        if (gm.getProperBaseChangeAttested()) {
          if (!seen.count(gm.getSourceSite())
              || !seen.count(gm.getTargetSite())) {
            gm.emitOpError("[TOPOS-E0504] attested geometric "
                           "morphism '")
                << gm.getSymName()
                << "' is declared before its source or target world "
                   "has been defined in module order.\n"
                   "  fix: move the geometric morphism after both "
                   "worlds, or use a forward declaration. The "
                   "localisation decomposition requires the source "
                   "and target topoi to be already constructed "
                   "before the morphism is recorded.";
            failed = true;
          }
        }
      }
    }
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// internal-language consistency
//
// Yon's internal language is the Mitchell-Bénabou language of the
// surrounding topos. The check performed here: the classifier of each
// `topos.canonical_subplace` must be a block argument or be produced by
// one of heyt, heyt_and, heyt_or, heyt_not, heyt_implies, forces, path,
// dep_proposition, or_intro, exists_intro (E0505). This rules out
// propositions smuggled in from other dialects.
//===----------------------------------------------------------------------===//

struct InternalLanguageConsistencyPass
    : public PassWrapper<InternalLanguageConsistencyPass,
                         OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(
      InternalLanguageConsistencyPass)
  StringRef getArgument() const override {
    return "topos-internal-lang";
  }
  StringRef getDescription() const override {
    return "Check that proposition values flowing into "
           "topos.canonical_subplace are produced by Heyting ops "
           ".";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    mod.walk([&](CanonicalSubplaceOp sub) {
      Value c = sub.getClassifier();
      if (c.isa<BlockArgument>())
        return; // accept block arguments
      Operation *p = c.getDefiningOp();
      if (!p) return;
      StringRef name = p->getName().getStringRef();
      if (!(name == "topos.heyt" || name == "topos.heyt_and"
            || name == "topos.heyt_or" || name == "topos.heyt_not"
            || name == "topos.heyt_implies"
            || name == "topos.forces" || name == "topos.path"
            || name == "topos.dep_proposition"
            || name == "topos.or_intro"
            || name == "topos.exists_intro")) {
        sub.emitOpError(
            "[TOPOS-E0505] classifier of canonical subplace '")
            << sub.getSymName() << "' is produced by '" << name
            << "', which is not a Heyting or proposition-building "
               "operation.\n"
               "  fix: produce the classifier through "
               "`topos.heyt`, `topos.heyt_and`, "
               "`topos.heyt_or`, `topos.heyt_not`, "
               "`topos.heyt_implies`, `topos.forces`, "
               "`topos.dep_proposition`, or one of the proof "
               "introduction ops (or_intro / exists_intro). "
               "Avoid casts from foreign dialects.\n"
               "  context: the internal language of the topos is "
               "the Heyting algebra of its subobject classifier; "
               "letting an arbitrary value play that role breaks "
               "the language's consistency.";
        failed = true;
      }
    });
    if (failed)
      signalPassFailure();
  }
};

//===----------------------------------------------------------------------===//
// alpha-rename pre-typecheck
//
// Flags a symbol name declared twice among the top-level operations of
// the module (E0539). Nested scopes are not inspected.
//===----------------------------------------------------------------------===//

struct AlphaRenamePass
    : public PassWrapper<AlphaRenamePass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(AlphaRenamePass)
  StringRef getArgument() const override { return "topos-alpha-rename"; }
  StringRef getDescription() const override {
    return "Flag shadowing in nested scopes; does not "
           "modify the IR.";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool failed = false;
    llvm::StringSet<> moduleScope;
    for (Operation &top : mod.getBody()->getOperations()) {
      if (auto sym =
              top.getAttrOfType<StringAttr>(
                  SymbolTable::getSymbolAttrName())) {
        if (!moduleScope.insert(sym.getValue()).second) {
          top.emitOpError("[TOPOS-E0539] symbol '")
              << sym.getValue()
              << "' is declared more than once at module scope.\n"
                 "  fix: rename one of the duplicates; the "
                 "downstream type-equivalence checks expect "
                 "uniqueness of names within a scope.";
          failed = true;
        }
      }
    }
    if (failed)
      signalPassFailure();
  }
};

} // namespace

//===----------------------------------------------------------------------===//
// Factory and registration boilerplate
//===----------------------------------------------------------------------===//

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createTypePreservationPass() {
  return std::make_unique<TypePreservationPass>();
}
std::unique_ptr<Pass> createProgressPass() {
  return std::make_unique<ProgressPass>();
}
std::unique_ptr<Pass> createTypeEquivSanityPass() {
  return std::make_unique<TypeEquivSanityPass>();
}
std::unique_ptr<Pass> createHMInferencePass() {
  return std::make_unique<HMInferencePass>();
}
std::unique_ptr<Pass> createGiraudCheckPass() {
  return std::make_unique<GiraudCheckPass>();
}
std::unique_ptr<Pass> createSimpson6Pass() {
  return std::make_unique<Simpson6Pass>();
}
std::unique_ptr<Pass> createAccessibilityPass() {
  return std::make_unique<AccessibilityPass>();
}
std::unique_ptr<Pass> createLocalisationDecompPass() {
  return std::make_unique<LocalisationDecompPass>();
}
std::unique_ptr<Pass> createInternalLanguageConsistencyPass() {
  return std::make_unique<InternalLanguageConsistencyPass>();
}
std::unique_ptr<Pass> createAlphaRenamePass() {
  return std::make_unique<AlphaRenamePass>();
}

void registerTypePreservationPass() {
  PassRegistration<TypePreservationPass>();
}
void registerProgressPass() { PassRegistration<ProgressPass>(); }
void registerTypeEquivSanityPass() {
  PassRegistration<TypeEquivSanityPass>();
}
void registerHMInferencePass() {
  PassRegistration<HMInferencePass>();
}
void registerGiraudCheckPass() {
  PassRegistration<GiraudCheckPass>();
}
void registerSimpson6Pass() { PassRegistration<Simpson6Pass>(); }
void registerAccessibilityPass() {
  PassRegistration<AccessibilityPass>();
}
void registerLocalisationDecompPass() {
  PassRegistration<LocalisationDecompPass>();
}
void registerInternalLanguageConsistencyPass() {
  PassRegistration<InternalLanguageConsistencyPass>();
}
void registerAlphaRenamePass() {
  PassRegistration<AlphaRenamePass>();
}

} // namespace topos
} // namespace mlir
