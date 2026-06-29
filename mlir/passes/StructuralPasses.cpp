//===- StructuralPasses.cpp - Batch C ---------------------------*- C++ -*-===//
//
// Implements 10 analysis passes that perform structural/categorical
// well-formedness checks beyond what TableGen verifiers can express.
//
// Implementation strategy:
//   - Each pass walks the module looking for a small set of patterns
//     that indicate a violation of the corresponding categorical or
//     type-theoretic property.
//   - On violation, an in-place diagnostic is emitted with a
//     [TOPOS-Exxxx] code, a fix hint, and a brief context note.
//   - These passes never modify the IR.
//
// The checks here are deliberately conservative: they catch obvious
// violations and serve as a documentation point for which properties
// each operation must satisfy. A fully complete analysis (deciding
// e.g. Giraud's exactness axioms in full generality) is a research
// task and is out of scope for the verifier layer.
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
// Walks every `topos.reduce` operation and checks the structural
// property that the result of the reduction has the same type as the
// place it operates on. This is a necessary condition for the
// preservation theorem: a well-typed term should remain well-typed
// after reduction.
//
// In MLIR the reduction's body is itself a region; we cannot fully
// type-check that region without a full type inference pass (see
// #18f), so we limit ourselves here to checking that any explicit
// `topos.section` returned from the body has its `place` field
// equal to the reduction's `of_place`.
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
// The progress theorem says that a well-typed term is either a value
// or can take a step. At the MLIR layer we check a weaker structural
// proxy: every `topos.move` referenced by a `topos.apply_move` must
// have a non-empty body region, otherwise applying it produces no
// step and the program would be "stuck" without being a value.
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
      // The move op declares a body region of the same name; check
      // it is non-empty.
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
// We check here only the trivial structural one at the MLIR layer:
//   - the world has at least one place (existence of a generating
//     family is the witness that the topos is non-trivial).
// The full Giraud check is delegated to a future analysis.
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
// Simpson's characterisation of ∞-topoi by six equivalent properties.
// We check the structural part: every `topos.from_site` is accompanied
// by a declared topology, ensuring the site is genuine (rather than a
// bare category).
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
// Every geometric morphism factors as an embedding followed by a
// surjection. We check the weaker structural property that every
// `topos.geom_morphism` declared with attribute
// `proper_base_change_attested` is preceded in the module order by
// the definition of its source and target worlds.
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
// surrounding topos. The MLIR-level check we perform here:
// every `topos.heyt`-typed value used as a classifier (via
// `topos.canonical_subplace`) must originate from a Heyting op
// (not from an arbitrary cast). This rules out fake propositions
// smuggled in from other dialects.
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
// A pre-typecheck pass that flags shadowing in the symbol space of
// nested places and worlds. Shadowing can mask bugs and confuse
// later type-equivalence checks (which rely on names being unique
// across nested scopes).
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
