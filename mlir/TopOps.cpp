//===- TopOps.cpp - Topos operations custom verifiers -------*- C++ -*-===//
//
// Structural verifiers of the Topos dialect.
//
// Convention: each op with `let hasVerifier = 1;` in TopOps.td must have an
// `OpName::verify()` method here. The verifiers cover the predicates TableGen
// cannot express: symbolic lookups, cross-attribute consistency, categorical
// constraints (e.g. reduction lawful for policy = paxos|crdt, geom_morphism
// with both pull and push).
//
// Categorical references:
//   - place_in_world: each place lives in a world (the HasParent trait covers
//     the structural case; the `over` lookups remain)
//   - reduction = a geometric morphism with a fixed codomain
//   - move = a morphism of the underlying category (same-world or cross via
//     geom_morphism)
//   - geom_morphism = an adjunction f^* |- f_* (both required)
//
//===----------------------------------------------------------------------===//

#include "TopDialect.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Operation.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/StringSet.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

//===----------------------------------------------------------------------===//
// Helper di lookup simbolico
//===----------------------------------------------------------------------===//

// Finds a symbol of type T named `name` inside `container`. The container must
// be a SymbolTable (e.g. WorldOp, ModuleOp). Returns nullptr if not found or if
// it is of the wrong type.
template <typename T>
static T lookupSymbolIn(Operation *container, StringRef name) {
  if (!container)
    return nullptr;
  Operation *raw = SymbolTable::lookupSymbolIn(container, name);
  return llvm::dyn_cast_or_null<T>(raw);
}

// Walks up the parent chain to find the WorldOp that contains `op`. Nullptr if
// there is no parent WorldOp (an orphan op).
static WorldOp findEnclosingWorld(Operation *op) {
  Operation *cur = op->getParentOp();
  while (cur) {
    if (auto w = llvm::dyn_cast<WorldOp>(cur))
      return w;
    cur = cur->getParentOp();
  }
  return nullptr;
}

// Looks for a PlaceOp named `name` in the enclosing world of `op`. If the op is
// top-level (a direct child of the ModuleOp), `name` may be a place inside any
// WorldOp: we descend into the module's WorldOps to find it. Returns nullptr if
// not found.
static PlaceOp findPlaceByName(Operation *op, StringRef name) {
  // (1) Look in the direct enclosing world.
  if (auto w = findEnclosingWorld(op)) {
    if (auto p = lookupSymbolIn<PlaceOp>(w, name))
      return p;
  }
  // (2) Look in the ancestor ModuleOp: descend into each WorldOp.
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur)
    return nullptr;
  auto mod = llvm::cast<ModuleOp>(cur);
  PlaceOp found = nullptr;
  mod.walk([&](PlaceOp candidate) {
    if (candidate.getSymName() == name) {
      found = candidate;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  return found;
}

// Looks for a top-level WorldOp named `name` in the ancestor ModuleOp.
static WorldOp findWorldByName(Operation *op, StringRef name) {
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur)
    return nullptr;
  auto mod = llvm::cast<ModuleOp>(cur);
  return lookupSymbolIn<WorldOp>(mod, name);
}

// Extracts the name of the parent world of a PlaceOp.
static StringRef placeWorldName(PlaceOp p) {
  return p.getWorld();
}

// Looks for a "place declaration" that can be:
//   - a direct PlaceOp (explicit declaration)
//   - a PullbackOp / PushoutOp / CoproductOp / CoequalizerOp that declares a
//     derived place (a limit / colimit construction).
//
// Returns true if it finds something with that name. The "owning world" of the
// derived place is inferred by walking up to the moves or the components (see
// `derivedPlaceWorld`).
static bool placeOrDerivedExists(Operation *op, StringRef name) {
  if (findPlaceByName(op, name)) return true;

  // Walk up to the module to scan the derived ops.
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return false;
  auto mod = llvm::cast<ModuleOp>(cur);

  bool found = false;
  mod.walk([&](Operation *o) {
    if (auto p = llvm::dyn_cast<PullbackOp>(o)) {
      if (p.getSymName() == name) { found = true; return WalkResult::interrupt(); }
    } else if (auto p = llvm::dyn_cast<PushoutOp>(o)) {
      if (p.getSymName() == name) { found = true; return WalkResult::interrupt(); }
    } else if (auto p = llvm::dyn_cast<CoproductOp>(o)) {
      if (p.getSymName() == name) { found = true; return WalkResult::interrupt(); }
    } else if (auto p = llvm::dyn_cast<CoequalizerOp>(o)) {
      if (p.getSymName() == name) { found = true; return WalkResult::interrupt(); }
    }
    return WalkResult::advance();
  });
  return found;
}

// Infers the world of a place or a derived place.
//   - direct PlaceOp:    its `world` attribute
//   - CoproductOp:       the world of its components (the first Place)
//   - CoequalizerOp:     the world of the source/target of f,g
//   - PullbackOp/PushoutOp: the world inferred from the two moves f,g (if both
//                            consistent — otherwise the original op's verifier
//                            already rejected it)
//
// Returns an empty StringRef if not resolvable.
static StringRef derivedPlaceWorld(Operation *op, StringRef name) {
  // Explicit PlaceOp case.
  if (auto p = findPlaceByName(op, name)) return placeWorldName(p);

  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return {};
  auto mod = llvm::cast<ModuleOp>(cur);

  // Internal helper: find a MoveOp by name.
  auto findMoveIn = [&](StringRef mname) -> MoveOp {
    MoveOp m;
    mod.walk([&](MoveOp candidate) {
      if (candidate.getSymName() == mname) {
        m = candidate;
        return WalkResult::interrupt();
      }
      return WalkResult::advance();
    });
    return m;
  };

  StringRef out;
  mod.walk([&](Operation *o) {
    if (auto p = llvm::dyn_cast<CoproductOp>(o)) {
      if (p.getSymName() != name) return WalkResult::advance();
      auto comps = p.getComponents();
      if (comps.empty()) return WalkResult::interrupt();
      auto firstSym = llvm::cast<FlatSymbolRefAttr>(comps[0]);
      if (auto firstP = findPlaceByName(op, firstSym.getValue()))
        out = placeWorldName(firstP);
      return WalkResult::interrupt();
    }
    if (auto p = llvm::dyn_cast<CoequalizerOp>(o)) {
      if (p.getSymName() != name) return WalkResult::advance();
      auto f = findMoveIn(p.getF());
      if (!f) return WalkResult::interrupt();
      if (auto srcP = findPlaceByName(op, f.getSourcePlace()))
        out = placeWorldName(srcP);
      return WalkResult::interrupt();
    }
    if (auto p = llvm::dyn_cast<PullbackOp>(o)) {
      if (p.getSymName() != name) return WalkResult::advance();
      auto f = findMoveIn(p.getF());
      if (!f) return WalkResult::interrupt();
      if (auto tgtP = findPlaceByName(op, f.getTargetPlace()))
        out = placeWorldName(tgtP);
      return WalkResult::interrupt();
    }
    if (auto p = llvm::dyn_cast<PushoutOp>(o)) {
      if (p.getSymName() != name) return WalkResult::advance();
      auto f = findMoveIn(p.getF());
      if (!f) return WalkResult::interrupt();
      if (auto srcP = findPlaceByName(op, f.getSourcePlace()))
        out = placeWorldName(srcP);
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  return out;
}

//===----------------------------------------------------------------------===//
// Syntactic purity test (shared by #18g, #27k, #27q, #27h, ...).
//
// A conservative, sound, syntactic purity test for the `topos`
// dialect:
//   - operations carrying the MLIR Pure / ConstantLike traits are pure;
//   - operations exposing `MemoryEffectOpInterface::hasNoEffect()` are
//     pure (modulo their nested regions);
//   - a hand-maintained allow-list of topos ops known to be pure by
//     construction is accepted;
//   - everything else is treated as potentially impure.
// All region children must themselves be pure (recursive descent).
//===----------------------------------------------------------------------===//

static bool isToposKnownPure(Operation *op) {
  StringRef name = op->getName().getStringRef();
  return name == "topos.field" || name == "topos.operation"
      || name == "topos.cell" || name == "topos.section"
      || name == "topos.restrict" || name == "topos.glue"
      || name == "topos.path" || name == "topos.coherence"
      || name == "topos.probe_construct"
      || name == "topos.probe_collapse"
      || name == "topos.apply_move" || name == "topos.heyt"
      || name == "topos.heyt_and" || name == "topos.heyt_or"
      || name == "topos.heyt_not" || name == "topos.heyt_implies"
      || name == "topos.compose_reductions"
      || name == "topos.pabs";  // pabs nested is pure iff its body is
}

// Forward declaration for mutual recursion.
static bool isOpSyntacticallyPure(Operation *op);

static bool isRegionPure(Region &region) {
  for (Block &block : region) {
    for (Operation &op : block) {
      if (!isOpSyntacticallyPure(&op))
        return false;
    }
  }
  return true;
}

static bool isOpSyntacticallyPure(Operation *op) {
  if (!op)
    return false;

  // (a) Constant-like values (e.g. `arith.constant`).
  if (op->hasTrait<OpTrait::ConstantLike>())
    return true;

  // (b) Topos ops on the hand-maintained allow-list.
  bool baseOk = isToposKnownPure(op);

  // (c) Otherwise, ask MLIR via MemoryEffectOpInterface.
  if (!baseOk) {
    if (auto memInterface = dyn_cast<MemoryEffectOpInterface>(op)) {
      if (!memInterface.hasNoEffect())
        return false;
      baseOk = true;
    }
  }

  if (!baseOk)
    return false;

  // (d) Even when the op itself is pure, its nested regions must be
  // pure as well.
  for (Region &r : op->getRegions()) {
    if (!isRegionPure(r))
      return false;
  }
  return true;
}

} // namespace

//===----------------------------------------------------------------------===//
// PlaceOp
//===----------------------------------------------------------------------===//

// Verifica:
//   (1) field names unique within the body
//   (2) operation names unique within the body
//   (3) cell names unique within the body
//   (4) if it contains an OperationOp, it must be with_effects = true
//   (5) if `over` is present, it must reference an existing PlaceOp in the same
//       world (slice category C/X requires X in Obj(C))
LogicalResult PlaceOp::verify() {
  llvm::StringSet<> seenFields;
  llvm::StringSet<> seenOps;
  llvm::StringSet<> seenCells;

  bool hasAnyOperation = false;

  // Terminal object 1: a fieldless place has an empty body region (0 blocks).
  // It carries no fields/ops/cells, so the membership checks below are vacuous.
  // We must not call getBody().front() on an empty region (UB). The qualifier,
  // `over`, and coeffect_algebra checks further down do not touch the body and
  // still apply, so we only guard the body iterations.
  bool hasBody = !getBody().empty();

  if (hasBody)
  for (Operation &nested : getBody().front()) {
    if (auto f = llvm::dyn_cast<FieldOp>(&nested)) {
      StringRef name = f.getSymName();
      if (!seenFields.insert(name).second)
        return f.emitOpError("field name '")
               << name << "' duplicated in place '" << getSymName() << "'";
    } else if (auto o = llvm::dyn_cast<OperationOp>(&nested)) {
      hasAnyOperation = true;
      StringRef name = o.getSymName();
      if (!seenOps.insert(name).second)
        return o.emitOpError("operation name '")
               << name << "' duplicated in place '" << getSymName() << "'";
    } else if (auto c = llvm::dyn_cast<CellOp>(&nested)) {
      StringRef name = c.getSymName();
      if (!seenCells.insert(name).second)
        return c.emitOpError("cell name '")
               << name << "' duplicated in place '" << getSymName() << "'";
    }
  }

  if (hasAnyOperation && !getWithEffects())
    return emitOpError("place '")
           << getSymName()
           << "' declares operations but with_effects is not set; "
              "an operation algebra (1-cells) requires opt-in via with_effects";

  // (5-bis) Lambek-Scott Part II cap 11 — qualifier check.
  //   D(L) "dogma"      : type judgments only -> no OperationOp, no
  //                        proposition-typed field (no Omega)
  //   A(L) "relational" : adds propositions -> no OperationOp but the fields
  //                        may have type !topos.proposition
  //   T(L) "term"       : full (default) -> no restriction
  // Errori: [TOPOS-E0960..E0962]
  if (auto qOpt = getQualifier()) {
    StringRef q = *qOpt;
    if (q != "dogma" && q != "relational" && q != "term") {
      return emitOpError(
          "[TOPOS-E0960] place '")
          << getSymName() << "' has invalid qualifier '" << q << "'.\n"
          << "  fix: qualifier must be one of: \"dogma\", \"relational\", "
             "\"term\" (Lambek-Scott Part II cap 11 — the three categories "
             "D(L), A(L), T(L) associated with a type theory).";
    }
    bool hasProposition = false;
    if (hasBody)
    for (Operation &nested : getBody().front()) {
      if (auto f = llvm::dyn_cast<FieldOp>(&nested)) {
        if (llvm::isa<PropositionType>(f.getFieldType()))
          hasProposition = true;
      }
    }
    if (q == "dogma") {
      if (hasAnyOperation) {
        return emitOpError(
            "[TOPOS-E0961] place '")
            << getSymName() << "' is qualified `dogma` (D(L)) but "
               "declares operations.\n"
            << "  fix: D(L) is the pure type-judgment fragment "
               "of the theory; it admits only `topos.field` declarations. "
               "Remove the operations or change qualifier to "
               "\"relational\" (still operation-free, but admits "
               "propositions) or \"term\" (full T(L)).";
      }
      if (hasProposition) {
        return emitOpError(
            "[TOPOS-E0961] place '")
            << getSymName() << "' is qualified `dogma` (D(L)) but "
               "has a field of type !topos.proposition.\n"
            << "  fix: D(L) admits only ground type judgments. "
               "Propositions (Omega) belong to A(L) — use qualifier "
               "\"relational\" or \"term\".";
      }
    } else if (q == "relational") {
      if (hasAnyOperation) {
        return emitOpError(
            "[TOPOS-E0962] place '")
            << getSymName() << "' is qualified `relational` (A(L)) "
               "but declares operations.\n"
            << "  fix: A(L) admits type judgments + propositions but "
               "no term-forming operators (1-cells / operations). "
               "Remove the operations or use qualifier \"term\" for "
               "the full T(L).";
      }
    }
    // q == "term" : no restriction, it is the default semantically.
  }

  if (auto over = getOver()) {
    StringRef overName = *over;
    auto base = findPlaceByName(*this, overName);
    if (!base)
      return emitOpError("slice base place '")
             << overName << "' not found (place '" << getSymName()
             << "' declared `over` an unknown place)";
    // Slice category C/X requires X in Obj(C): the base must be in the same
    // world (or reachable via geom_morphism, but that case is left open: a
    // later pass verifies it).
    if (placeWorldName(base) != getWorld())
      return emitOpError("slice base place '")
             << overName << "' is in world '" << placeWorldName(base)
             << "' but this place is in world '" << getWorld()
             << "'; slice category requires same world (or explicit "
                "geom_morphism)";
  }

  // (6) field_escape check.
  //
  // Collect the types of private fields. For every OperationOp in the
  // body, the result type must not coincide with any private field
  // type — otherwise the abstract representation leaks through the
  // public interface.
  llvm::SmallVector<Type, 4> privateTypes;
  if (hasBody)
  for (Operation &nested : getBody().front()) {
    if (auto f = llvm::dyn_cast<FieldOp>(&nested)) {
      if (f.getIsPrivate())
        privateTypes.push_back(f.getFieldType());
    }
  }
  if (!privateTypes.empty()) {
    for (Operation &nested : getBody().front()) {
      if (auto opOp = llvm::dyn_cast<OperationOp>(&nested)) {
        Type rt = opOp.getResultType();
        for (Type pt : privateTypes) {
          if (rt == pt) {
            return opOp.emitOpError(
                "[TOPOS-E0275] operation '") << opOp.getSymName()
                << "' has a result type that coincides with the type "
                   "of a private field declared in the same place. "
                   "This causes the private representation to leak "
                   "into the public interface of the place.\n"
                   "  fix: either (a) wrap the result in an opaque "
                   "type alias that does not expose the private "
                   "field type, or (b) mark the field as non-private "
                   "by removing the `is_private` attribute, or (c) "
                   "change the operation's result type to a public "
                   "type that does not include the private field.\n"
                   "  context: data abstraction requires that types "
                   "marked as private (the internal representation) "
                   "never appear in public operation signatures, "
                   "otherwise clients can rely on the representation "
                   "and break abstraction.";
          }
        }
      }
    }
  }

  // (7) coeffect_algebra attribute validity.
  if (auto algName = getCoeffectAlgebra()) {
    static const llvm::StringRef knownAlgebras[] = {
        "linear", "affine", "semiring", "nat", "boolean", "lattice"};
    bool ok = false;
    for (StringRef k : knownAlgebras)
      if (*algName == k) { ok = true; break; }
    if (!ok) {
      return emitOpError("[TOPOS-E0535] place '")
             << getSymName() << "' declares coeffect_algebra '"
             << *algName << "', which is not a recognised algebra "
                            "tag.\n"
                            "  fix: set coeffect_algebra to one of "
                            "{\"linear\", \"affine\", \"semiring\", "
                            "\"nat\", \"boolean\", \"lattice\"}, or "
                            "drop the attribute if no coeffect "
                            "tracking is desired.\n"
                            "  context: the coeffect algebra "
                            "controls which usage patterns are "
                            "tracked at the type level for this "
                            "place (e.g. linear forbids duplication "
                            "of inhabitants).";
    }
  }

  return success();
}

//===----------------------------------------------------------------------===//
// MoveOp
//===----------------------------------------------------------------------===//

// Verifica:
//   (1) source_place e target_place esistono
//   (2) source and target are in the same world (a cross-world move requires
//       an explicit geom_morphism — out of scope for this verifier)
LogicalResult MoveOp::verify() {
  // Risolvi source e target: possono essere PlaceOp diretti o
  // derived places (Pullback/Pushout/Coproduct/Coequalizer).
  bool srcExists = placeOrDerivedExists(*this, getSourcePlace());
  if (!srcExists)
    return emitOpError("source place '")
           << getSourcePlace() << "' not found";
  bool tgtExists = placeOrDerivedExists(*this, getTargetPlace());
  if (!tgtExists)
    return emitOpError("target place '")
           << getTargetPlace() << "' not found";

  // World consistency: the two places (or derived places) must live in the
  // same enclosing world.
  StringRef srcWorld = derivedPlaceWorld(*this, getSourcePlace());
  StringRef tgtWorld = derivedPlaceWorld(*this, getTargetPlace());
  if (!srcWorld.empty() && !tgtWorld.empty() && srcWorld != tgtWorld)
    return emitOpError("move '")
           << getSymName() << "' crosses worlds ('"
           << srcWorld << "' -> '" << tgtWorld
           << "'); cross-world moves require an explicit geom_morphism";
  return success();
}

//===----------------------------------------------------------------------===//
// ApplyMoveOp
//===----------------------------------------------------------------------===//

// Verify: the referenced move exists as a MoveOp in the module.
LogicalResult ApplyMoveOp::verify() {
  Operation *cur = getOperation()->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur)
    return emitOpError("apply_move not inside a module");
  auto mod = llvm::cast<ModuleOp>(cur);

  StringRef moveName = getMove();
  MoveOp found = nullptr;
  mod.walk([&](MoveOp m) {
    if (m.getSymName() == moveName) {
      found = m;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (!found)
    return emitOpError("referenced move '")
           << moveName << "' not found in module";
  return success();
}

//===----------------------------------------------------------------------===//
// FieldLoadOp — Topos_FieldLoadOp verifier (P7-frontend A1)
//===----------------------------------------------------------------------===//

// Verify:
//   (1) [TOPOS-E1020] the SectionType place must exist
//   (2) [TOPOS-E1021] the named field must exist in the place
//   (3) [TOPOS-E1022] the result type must match the declared field type
LogicalResult FieldLoadOp::verify() {
  auto sectionTy = llvm::cast<SectionType>(getSection().getType());
  StringRef placeName = sectionTy.getPlaceName();
  StringRef fname = getFieldName();

  auto place = findPlaceByName(*this, placeName);
  if (!place) {
    return emitOpError(
        "[TOPOS-E1020] field_load on section of place '")
        << placeName << "' which is not declared.\n"
        << "  fix: declare the place before reading its fields.";
  }

  // Cerca il field nel body del place.
  Type expectedFieldType;
  bool fieldFound = false;
  for (Operation &nested : place.getBody().front()) {
    if (auto f = llvm::dyn_cast<FieldOp>(&nested)) {
      if (f.getSymName() == fname) {
        expectedFieldType = f.getFieldType();
        fieldFound = true;
        break;
      }
    }
  }
  if (!fieldFound) {
    return emitOpError(
        "[TOPOS-E1021] field_load: place '")
        << placeName << "' has no field named '" << fname << "'.\n"
        << "  fix: declare the field with `topos.field @" << fname
        << " : <type>` inside the place body, or correct the field name.";
  }

  Type resultTy = getResult().getType();
  if (resultTy != expectedFieldType) {
    return emitOpError(
        "[TOPOS-E1022] field_load: result type ")
        << resultTy << " does not match the declared field type "
        << expectedFieldType << " of '" << placeName << "." << fname
        << "'.\n  fix: align the result type with the field declaration.";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// ReduceOp
//===----------------------------------------------------------------------===//

// Verifica:
//   (1) of_place exists
//   (2) direction = bi  =>  invertible must be set
//   (3) policy in {paxos, crdt}  =>  lawful must be set
//       (only left-exact geometric morphisms can materialize as consensus
//       or CRDT in a categorically sound way)
//   (4) multi_shot = false  =>  shot_ordering must be sequential
//       (di default; se l'utente ha esplicitato parallel/by_priority
//       without multi_shot is a contradiction)
// Verifies a reduction declaration:
//   (1) the `of_place` symbol resolves to a declared place;
//   (2) direction = bi requires `invertible` to be set;
//   (3) policy = paxos|crdt requires `lawful` to be set;
//   (4) when `multi_shot` is not set, `shot_ordering` must be
//       Sequential;
//   (5) when `coeffect_preserving` is set, the reduction must be
//       forward and the target place must declare a `coeffect_algebra`
//       (subject reduction for coeffected places).
LogicalResult ReduceOp::verify() {
  // (1) of_place lookup.
  auto place = findPlaceByName(*this, getOfPlace());
  if (!place) {
    return emitOpError("[TOPOS-E0341] reduction '")
           << getSymName() << "' references unknown place '"
           << getOfPlace() << "'.\n"
           "  fix: declare the place (and the enclosing world) "
           "before this reduction, or correct the place reference.";
  }

  // (2) direction = bi requires invertible.
  if (getDirection() == ReductionDirection::Bi && !getInvertible()) {
    return emitOpError("[TOPOS-E0342] reduction '")
           << getSymName()
           << "' is declared bidirectional but is not marked "
              "invertible.\n"
              "  fix: either add the `invertible` attribute (and "
              "ensure the reduction really is an equivalence) or "
              "change the direction to forward or backward.\n"
              "  context: a bidirectional reduction must be a "
              "genuine equivalence, not merely a pair of moves "
              "that happen to be defined in both directions.";
  }

  // (3) policy = paxos|crdt requires lawful.
  auto pol = getPolicy();
  if ((pol == ReductionPolicy::ReplicatedPaxos
       || pol == ReductionPolicy::EventualCRDT)
      && !getLawful()) {
    return emitOpError("[TOPOS-E0343] reduction '")
           << getSymName()
           << "' uses a consensus or CRDT policy but is not marked "
              "`lawful`.\n"
              "  fix: prove that the underlying geometric morphism "
              "is left exact and add the `lawful` attribute, or "
              "switch the policy to direct/sharded if the "
              "left-exactness obligation cannot be met.\n"
              "  context: only left-exact geometric morphisms can "
              "be safely materialised as replicated state machines "
              "or CRDTs without breaking categorical structure.";
  }

  // (4) shot_ordering coherence.
  if (!getMultiShot()
      && getShotOrdering() != ShotOrdering::Sequential) {
    return emitOpError("[TOPOS-E0344] reduction '")
           << getSymName()
           << "' is single-shot but `shot_ordering` is not "
              "Sequential.\n"
              "  fix: either set `shot_ordering` to Sequential, or "
              "mark the reduction `multi_shot` if multiple "
              "concurrent handlers are intended.";
  }

  // (5) coeffect-preserving reductions are forward only
  // and require the target place to declare a coeffect algebra.
  if (getCoeffectPreserving()) {
    if (getDirection() != ReductionDirection::Forward) {
      return emitOpError("[TOPOS-E0345] reduction '")
             << getSymName()
             << "' is marked `coeffect_preserving` but its direction "
                "is not forward.\n"
                "  fix: either remove `coeffect_preserving` (if the "
                "reduction is genuinely bidirectional or backward) "
                "or set the direction to forward.\n"
                "  context: coeffect tracking is only preserved by "
                "the forward leg of a reduction; the backward or "
                "bidirectional cases require additional structure "
                "that is not yet supported.";
    }
    auto p = llvm::cast<PlaceOp>(place.getOperation());
    if (!p.getCoeffectAlgebra().has_value()) {
      return emitOpError("[TOPOS-E0346] reduction '")
             << getSymName()
             << "' is marked `coeffect_preserving` but its target "
                "place '" << getOfPlace()
             << "' does not declare a `coeffect_algebra`.\n"
                "  fix: either set the place's `coeffect_algebra` "
                "attribute (e.g. \"linear\", \"affine\", ...) or "
                "drop the `coeffect_preserving` attribute on the "
                "reduction.";
    }
  }

  return success();
}

//===----------------------------------------------------------------------===//
// OpApplyOp
//===----------------------------------------------------------------------===//

// Verify:
//   (1) op_ref exists as an OperationOp inside some PlaceOp of the module
//   (2) the argument arity matches the declared arg_types
//   (3) the place of op_ref is that of the instance (type SectionType<P>)
LogicalResult OpApplyOp::verify() {
  StringRef opName = getOpRef();

  // Look for the OperationOp in the module (scan all places of all
  // i world).
  Operation *cur = getOperation()->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur)
    return emitOpError("op_apply not inside a module");
  auto mod = llvm::cast<ModuleOp>(cur);

  OperationOp found = nullptr;
  PlaceOp foundPlace = nullptr;
  mod.walk([&](OperationOp candidate) {
    if (candidate.getSymName() == opName) {
      found = candidate;
      foundPlace = llvm::dyn_cast_or_null<PlaceOp>(
          candidate->getParentOp());
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (!found)
    return emitOpError("operation '")
           << opName << "' not found in any place of the module";

  // (2) arity check
  auto declaredTypes = found.getArgTypes();
  if (declaredTypes.size() != getArgs().size())
    return emitOpError("operation '")
           << opName << "' expects " << declaredTypes.size()
           << " argument(s) but got " << getArgs().size();

  // (3) instance place must match op's enclosing place
  if (foundPlace) {
    auto instType = llvm::cast<SectionType>(getInstance().getType());
    if (instType.getPlaceName() != foundPlace.getSymName())
      return emitOpError("operation '")
             << opName << "' belongs to place '"
             << foundPlace.getSymName()
             << "' but instance has section type for place '"
             << instType.getPlaceName() << "'";
  }

  return success();
}

//===----------------------------------------------------------------------===//
// PullbackOp / PushoutOp
//===----------------------------------------------------------------------===//

// Verify that f and g are moves existing in the module (cospan for pullback,
// span for pushout). The categorical compatibility of the cospan (coinciding
// codomains) or of the span (coinciding domains) is delegated to a later pass
// that requires type information.
static LogicalResult verifyUniversalConstruction(
    Operation *op, StringRef name, StringRef fName, StringRef gName,
    StringRef kind) {
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur)
    return op->emitOpError(kind) << " not inside a module";
  auto mod = llvm::cast<ModuleOp>(cur);

  bool foundF = false, foundG = false;
  mod.walk([&](MoveOp m) {
    if (m.getSymName() == fName)
      foundF = true;
    if (m.getSymName() == gName)
      foundG = true;
  });
  if (!foundF)
    return op->emitOpError(kind)
           << " '" << name << "' references unknown move '" << fName << "'";
  if (!foundG)
    return op->emitOpError(kind)
           << " '" << name << "' references unknown move '" << gName << "'";
  return success();
}

LogicalResult PullbackOp::verify() {
  return verifyUniversalConstruction(*this, getSymName(), getF(), getG(),
                                     "pullback");
}

LogicalResult PushoutOp::verify() {
  return verifyUniversalConstruction(*this, getSymName(), getF(), getG(),
                                     "pushout");
}

//===----------------------------------------------------------------------===//
// CoproductOp (Lurie 4.4.1) — dualismo di pullback/restrict-to-product.
//===----------------------------------------------------------------------===//

// Verifier:
//   (1) [TOPOS-E0950]  N >= 1 (no empty coproduct in single-space; the true
//                              "0" is `topos.initial`)
//   (2)               each component resolves to an existing PlaceOp
//   (3) [TOPOS-E0951]  all components share the same world
//                      enclosing (cross-space coproduct is deferred)
LogicalResult CoproductOp::verify() {
  auto components = getComponents();
  if (components.empty()) {
    return emitOpError(
        "[TOPOS-E0950] coproduct '")
        << getSymName() << "' has no components.\n"
        << "  fix: provide at least one place. The empty coproduct "
           "(categorical initial object) is represented by "
           "`topos.initial` (CDT Hagino layer).";
  }

  // Resolve the referenced places and verify they live in the same world.
  SmallVector<PlaceOp, 4> resolvedPlaces;
  resolvedPlaces.reserve(components.size());
  StringRef firstWorld;
  for (auto attr : components) {
    auto symAttr = llvm::cast<FlatSymbolRefAttr>(attr);
    auto p = findPlaceByName(*this, symAttr.getValue());
    if (!p) {
      return emitOpError(
          "[TOPOS-E0950] coproduct '")
          << getSymName() << "' references unknown place '"
          << symAttr.getValue() << "'.\n"
          << "  fix: declare the place inside an enclosing `topos.world`, "
             "or correct the symbol name.";
    }
    resolvedPlaces.push_back(p);
    StringRef w = placeWorldName(p);
    if (firstWorld.empty()) {
      firstWorld = w;
    } else if (w != firstWorld) {
      return emitOpError(
          "[TOPOS-E0951] coproduct '")
          << getSymName() << "' mixes places from different worlds: "
          << "'" << symAttr.getValue() << "' lives in world '"
          << w << "' but the first component lives in world '"
          << firstWorld << "'.\n"
          << "  fix: cross-Space coproduct is not yet supported "
             "(scheduled for P8.1+). All components must share the "
             "same enclosing world.";
    }
  }
  return success();
}

//===----------------------------------------------------------------------===//
// CoequalizerOp (Lurie 4.4.3) — quotient by the equivalence relation generated
// by a pair of parallel morphisms.
//===----------------------------------------------------------------------===//

// Verifier:
//   (1) f e g devono essere MoveOp dichiarati
//   (2) [TOPOS-E0952]  f and g must be parallel (same source,
//                       same target)
//   (3) [TOPOS-E0953]  the two moves must live in the same world
//                       enclosing (cross-space coeq is deferred)
//   (4)                quotient_move must be an already-declared MoveOp
//                       with source = target of f,g and target = sym_name (the
//                       coequalizer place declared here)
//
// NOTE: the quotient_move is declared separately (as a regular MoveOp)
// and referenced by name; this allows pre-declaring it so it can be referenced
// inside forces / coherence blocks, and consolidates its nature as a "named
// morphism".
LogicalResult CoequalizerOp::verify() {
  // Local helper: find a MoveOp by name.
  auto findMove = [&](StringRef name) -> MoveOp {
    Operation *cur = (*this)->getParentOp();
    while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
    if (!cur) return nullptr;
    auto mod = llvm::cast<ModuleOp>(cur);
    MoveOp found = nullptr;
    mod.walk([&](MoveOp m) {
      if (m.getSymName() == name) {
        found = m;
        return WalkResult::interrupt();
      }
      return WalkResult::advance();
    });
    return found;
  };

  auto fMove = findMove(getF());
  if (!fMove) {
    return emitOpError(
        "[TOPOS-E0952] coequalizer '")
        << getSymName() << "' references unknown move '" << getF() << "'.\n"
        << "  fix: declare the move with `topos.move` before referring "
           "to it here.";
  }
  auto gMove = findMove(getG());
  if (!gMove) {
    return emitOpError(
        "[TOPOS-E0952] coequalizer '")
        << getSymName() << "' references unknown move '" << getG() << "'.\n"
        << "  fix: declare the move with `topos.move` before referring "
           "to it here.";
  }

  // Parallelism: same source, same target.
  if (fMove.getSourcePlace() != gMove.getSourcePlace()) {
    return emitOpError(
        "[TOPOS-E0952] coequalizer '")
        << getSymName() << "': moves '" << getF() << "' and '"
        << getG() << "' are not parallel — source mismatch: '"
        << fMove.getSourcePlace() << "' vs '"
        << gMove.getSourcePlace() << "'.\n"
        << "  fix: the categorical coequalizer requires two parallel "
           "morphisms f, g : P -> Q. Adjust the moves so they share "
           "source and target.";
  }
  if (fMove.getTargetPlace() != gMove.getTargetPlace()) {
    return emitOpError(
        "[TOPOS-E0952] coequalizer '")
        << getSymName() << "': moves '" << getF() << "' and '"
        << getG() << "' are not parallel — target mismatch: '"
        << fMove.getTargetPlace() << "' vs '"
        << gMove.getTargetPlace() << "'.\n"
        << "  fix: f and g must share both source and target.";
  }

  // World consistency: the source/target places must live in the same world
  // (and that world must be the coequalizer's enclosing world).
  auto srcPlace = findPlaceByName(*this, fMove.getSourcePlace());
  auto tgtPlace = findPlaceByName(*this, fMove.getTargetPlace());
  if (srcPlace && tgtPlace) {
    if (placeWorldName(srcPlace) != placeWorldName(tgtPlace)) {
      return emitOpError(
          "[TOPOS-E0953] coequalizer '")
          << getSymName() << "': source place '"
          << fMove.getSourcePlace() << "' (world '"
          << placeWorldName(srcPlace) << "') and target place '"
          << fMove.getTargetPlace() << "' (world '"
          << placeWorldName(tgtPlace) << "') belong to different "
             "worlds.\n"
          << "  fix: cross-Space coequalizer is not yet supported "
             "(scheduled for P8.1+).";
    }
  }

  // Quotient move check: must be declared and have
  //   source = target di f,g     target = sym_name (= il place coeq)
  auto qMove = findMove(getQuotientMove());
  if (!qMove) {
    return emitOpError(
        "[TOPOS-E0953] coequalizer '")
        << getSymName() << "' references unknown quotient move '"
        << getQuotientMove() << "'.\n"
        << "  fix: declare the quotient morphism with `topos.move "
        << getQuotientMove() << " : "
        << fMove.getTargetPlace() << " -> " << getSymName()
        << "` before this coequalizer.";
  }
  if (qMove.getSourcePlace() != fMove.getTargetPlace()) {
    return emitOpError(
        "[TOPOS-E0953] coequalizer '")
        << getSymName() << "': quotient move '"
        << getQuotientMove() << "' has source '"
        << qMove.getSourcePlace() << "' but should be '"
        << fMove.getTargetPlace() << "' (the target of f,g).\n"
        << "  fix: the canonical quotient q : Q -> C has source = Q.";
  }
  if (qMove.getTargetPlace() != getSymName()) {
    return emitOpError(
        "[TOPOS-E0953] coequalizer '")
        << getSymName() << "': quotient move '"
        << getQuotientMove() << "' has target '"
        << qMove.getTargetPlace() << "' but should be '"
        << getSymName() << "' (this coequalizer's name).\n"
        << "  fix: the canonical quotient q : Q -> C has target = C.";
  }

  return success();
}

//===----------------------------------------------------------------------===//
// CDT Hagino layer — Terminal, Initial, Bang, Absurd
//===----------------------------------------------------------------------===//

// Local helper (file-scope): find a MoveOp by name in the module.
static MoveOp findMoveOpByName(Operation *op, StringRef name) {
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return nullptr;
  auto mod = llvm::cast<ModuleOp>(cur);
  MoveOp found;
  mod.walk([&](MoveOp m) {
    if (m.getSymName() == name) {
      found = m;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  return found;
}

// Find a TerminalOp (by name) in the whole module.
static TerminalOp findTerminalByName(Operation *op, StringRef name) {
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return nullptr;
  auto mod = llvm::cast<ModuleOp>(cur);
  TerminalOp found;
  mod.walk([&](TerminalOp t) {
    if (t.getSymName() == name) {
      found = t;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  return found;
}

// Find an InitialOp (by name) in the whole module.
static InitialOp findInitialByName(Operation *op, StringRef name) {
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return nullptr;
  auto mod = llvm::cast<ModuleOp>(cur);
  InitialOp found;
  mod.walk([&](InitialOp i) {
    if (i.getSymName() == name) {
      found = i;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  return found;
}

// TerminalOp verify:
//   (1) the world exists
//   (2) [TOPOS-E0970] uniqueness: only one Terminal per world
LogicalResult TerminalOp::verify() {
  if (!findWorldByName(*this, getWorld())) {
    return emitOpError(
        "[TOPOS-E0970] terminal '")
        << getSymName() << "' references unknown world '"
        << getWorld() << "'.";
  }

  // Uniqueness: there cannot be two TerminalOps in the same world.
  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return success();
  auto mod = llvm::cast<ModuleOp>(cur);

  StringRef myWorld = getWorld();
  StringRef myName = getSymName();
  TerminalOp other;
  mod.walk([&](TerminalOp t) {
    if (t.getOperation() == this->getOperation()) return WalkResult::advance();
    if (t.getWorld() == myWorld) {
      other = t;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (other) {
    return emitOpError(
        "[TOPOS-E0970] terminal '")
        << myName << "' duplicates another terminal '"
        << other.getSymName() << "' already declared in world '"
        << myWorld << "'.\n"
        << "  fix: a categorical world has a unique terminal object "
           "(up to canonical isomorphism). Remove one of the two "
           "declarations.";
  }
  return success();
}

// InitialOp verify: speculare a TerminalOp.
LogicalResult InitialOp::verify() {
  if (!findWorldByName(*this, getWorld())) {
    return emitOpError(
        "[TOPOS-E0971] initial '")
        << getSymName() << "' references unknown world '"
        << getWorld() << "'.";
  }

  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return success();
  auto mod = llvm::cast<ModuleOp>(cur);

  StringRef myWorld = getWorld();
  StringRef myName = getSymName();
  InitialOp other;
  mod.walk([&](InitialOp i) {
    if (i.getOperation() == this->getOperation()) return WalkResult::advance();
    if (i.getWorld() == myWorld) {
      other = i;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (other) {
    return emitOpError(
        "[TOPOS-E0971] initial '")
        << myName << "' duplicates another initial '"
        << other.getSymName() << "' already declared in world '"
        << myWorld << "'.\n"
        << "  fix: a categorical world has a unique initial object. "
           "Remove one of the two declarations.";
  }
  return success();
}

// BangOp verify:
//   (1) src exists as a place (or derived place)
//   (2) [TOPOS-E0972] terminal exists as a TerminalOp
//   (3) src and terminal live in the same world
//   (4) [TOPOS-E0973] uniqueness: only one Bang per (src, terminal) pair
LogicalResult BangOp::verify() {
  if (!placeOrDerivedExists(*this, getSrc())) {
    return emitOpError(
        "[TOPOS-E0972] bang '")
        << getSymName() << "' references unknown source place '"
        << getSrc() << "'.";
  }
  auto term = findTerminalByName(*this, getTerminal());
  if (!term) {
    return emitOpError(
        "[TOPOS-E0972] bang '")
        << getSymName() << "' references '" << getTerminal()
        << "' which is not a declared topos.terminal.\n"
        << "  fix: bang's target must be a TerminalOp declared with "
           "`topos.terminal @<name> in @<world>`.";
  }
  StringRef srcWorld = derivedPlaceWorld(*this, getSrc());
  if (!srcWorld.empty() && srcWorld != term.getWorld()) {
    return emitOpError(
        "[TOPOS-E0972] bang '")
        << getSymName() << "' crosses worlds: source '" << getSrc()
        << "' is in world '" << srcWorld
        << "', terminal '" << getTerminal()
        << "' is in world '" << term.getWorld() << "'.\n"
        << "  fix: bang is the unique morphism A -> 1 in a single world; "
           "cross-world cases need an explicit geom_morphism.";
  }

  // Uniqueness: only one Bang per (src, terminal) pair.
  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return success();
  auto mod = llvm::cast<ModuleOp>(cur);

  StringRef mySrc = getSrc(), myTerm = getTerminal();
  StringRef myName = getSymName();
  BangOp other;
  mod.walk([&](BangOp b) {
    if (b.getOperation() == this->getOperation()) return WalkResult::advance();
    if (b.getSrc() == mySrc && b.getTerminal() == myTerm) {
      other = b;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (other) {
    return emitOpError(
        "[TOPOS-E0973] bang '")
        << myName << "' duplicates '" << other.getSymName()
        << "': both declare a morphism from '" << mySrc
        << "' to terminal '" << myTerm << "'.\n"
        << "  fix: the universal arrow A -> 1 is unique. Use the existing "
           "bang instead of declaring a second one.";
  }
  return success();
}

// AbsurdOp verify: speculare a BangOp.
LogicalResult AbsurdOp::verify() {
  auto init = findInitialByName(*this, getInitial());
  if (!init) {
    return emitOpError(
        "[TOPOS-E0974] absurd '")
        << getSymName() << "' references '" << getInitial()
        << "' which is not a declared topos.initial.";
  }
  if (!placeOrDerivedExists(*this, getTgt())) {
    return emitOpError(
        "[TOPOS-E0974] absurd '")
        << getSymName() << "' references unknown target place '"
        << getTgt() << "'.";
  }
  StringRef tgtWorld = derivedPlaceWorld(*this, getTgt());
  if (!tgtWorld.empty() && tgtWorld != init.getWorld()) {
    return emitOpError(
        "[TOPOS-E0974] absurd '")
        << getSymName() << "' crosses worlds: initial '" << getInitial()
        << "' is in '" << init.getWorld()
        << "', target '" << getTgt() << "' is in '" << tgtWorld << "'.";
  }

  // Uniqueness: only one Absurd per (initial, tgt) pair.
  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return success();
  auto mod = llvm::cast<ModuleOp>(cur);

  StringRef myInit = getInitial(), myTgt = getTgt();
  StringRef myName = getSymName();
  AbsurdOp other;
  mod.walk([&](AbsurdOp a) {
    if (a.getOperation() == this->getOperation()) return WalkResult::advance();
    if (a.getInitial() == myInit && a.getTgt() == myTgt) {
      other = a;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (other) {
    return emitOpError(
        "[TOPOS-E0975] absurd '")
        << myName << "' duplicates '" << other.getSymName()
        << "': both declare a morphism from initial '" << myInit
        << "' to '" << myTgt << "'.\n"
        << "  fix: the universal arrow 0 -> A is unique.";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// RightObjectOp / LeftObjectOp — generale CDT declaration mechanism
//===----------------------------------------------------------------------===//

// Common helper: verifies the params (must exist as places in the same world)
// and the factorizer (must exist as a MoveOp).
//
// productive check (Hagino Def 4.1.5): a functor-expr "P(X1,...,Xn)" is
// productive in X_i if it contains X_i ONLY at the top level or inside a
// functor itself productive in X_i. For now the check here is left declarative
// (the full CSL grammar is out of scope for this phase);
// emit a placeholder warning through optional attributes. The full check comes
// with a dedicated `--cdt-productive` pass.
//
// kind = "right" o "left" per i messaggi.
static LogicalResult verifyHaginoObject(Operation *op, StringRef name,
                                         StringRef worldName,
                                         ArrayAttr params,
                                         StringRef factorizerName,
                                         Region &natTransRegion,
                                         StringRef kind) {
  // (a) the world exists
  if (!findWorldByName(op, worldName)) {
    return op->emitOpError(
        "[TOPOS-E0976] ")
        << kind << "_object '" << name
        << "' references unknown world '" << worldName << "'.";
  }
  // (b) params exist as places
  for (auto p : params) {
    auto sym = llvm::cast<FlatSymbolRefAttr>(p);
    auto place = findPlaceByName(op, sym.getValue());
    if (!place) {
      return op->emitOpError(
          "[TOPOS-E0977] ")
          << kind << "_object '" << name << "' references unknown "
             "parameter place '" << sym.getValue() << "'.";
    }
    if (placeWorldName(place) != worldName) {
      return op->emitOpError(
          "[TOPOS-E0977] ")
          << kind << "_object '" << name << "' has parameter '"
          << sym.getValue() << "' in world '" << placeWorldName(place)
          << "' but the object lives in world '" << worldName << "'.\n"
          << "  fix: all parameters of a Hagino object must live in "
             "the same enclosing world.";
    }
  }
  // (c) the factorizer exists as a MoveOp
  if (!findMoveOpByName(op, factorizerName)) {
    return op->emitOpError(
        "[TOPOS-E0978] ")
        << kind << "_object '" << name
        << "' references unknown factorizer move '" << factorizerName
        << "'.\n  fix: declare the factorizer with `topos.move "
        << factorizerName << " from ... to ...` before this object.";
  }
  // (d) all nat_trans must be NatTransOp (already enforced by the TableGen
  //     ParentOneOf, but for clarity we verify there are some and that they
  //     have unique names)
  llvm::StringSet<> seenNatTrans;
  for (Operation &child : natTransRegion.front()) {
    if (auto nt = llvm::dyn_cast<NatTransOp>(&child)) {
      if (!seenNatTrans.insert(nt.getSymName()).second) {
        return nt.emitOpError(
            "[TOPOS-E0979] duplicated nat_trans name '")
            << nt.getSymName() << "' inside " << kind << "_object '"
            << name << "'.";
      }
    } else {
      return child.emitOpError(
          "[TOPOS-E0980] non-NatTransOp inside ")
          << kind << "_object '" << name << "' body.";
    }
  }
  return success();
}

LogicalResult RightObjectOp::verify() {
  return verifyHaginoObject(*this, getSymName(), getWorld(),
                             getParams(), getFactorizer(),
                             getNatTrans(), "right");
}

LogicalResult LeftObjectOp::verify() {
  return verifyHaginoObject(*this, getSymName(), getWorld(),
                             getParams(), getFactorizer(),
                             getNatTrans(), "left");
}

//===----------------------------------------------------------------------===//
// ExponentialOp / CplElementOp
//===----------------------------------------------------------------------===//

LogicalResult ExponentialOp::verify() {
  if (!findWorldByName(*this, getWorld())) {
    return emitOpError(
        "[TOPOS-E0981] exponential '")
        << getSymName() << "' references unknown world '"
        << getWorld() << "'.";
  }
  // base and target must be places of the same world
  auto basePlace = findPlaceByName(*this, getBase());
  if (!basePlace) {
    return emitOpError(
        "[TOPOS-E0981] exponential '")
        << getSymName() << "' references unknown base place '"
        << getBase() << "'.";
  }
  auto tgtPlace = findPlaceByName(*this, getTarget());
  if (!tgtPlace) {
    return emitOpError(
        "[TOPOS-E0981] exponential '")
        << getSymName() << "' references unknown target place '"
        << getTarget() << "'.";
  }
  if (placeWorldName(basePlace) != getWorld() ||
      placeWorldName(tgtPlace) != getWorld()) {
    return emitOpError(
        "[TOPOS-E0981] exponential '")
        << getSymName() << "' has base or target in a different world.";
  }
  // curry_factorizer and eval_nat_trans must exist as MoveOp
  if (!findMoveOpByName(*this, getCurryFactorizer())) {
    return emitOpError(
        "[TOPOS-E0981] exponential '")
        << getSymName() << "' references unknown curry factorizer '"
        << getCurryFactorizer() << "'.";
  }
  if (!findMoveOpByName(*this, getEvalNatTrans())) {
    return emitOpError(
        "[TOPOS-E0981] exponential '")
        << getSymName() << "' references unknown eval morphism '"
        << getEvalNatTrans() << "'.";
  }
  return success();
}

LogicalResult CplElementOp::verify() {
  if (!findWorldByName(*this, getWorld())) {
    return emitOpError(
        "[TOPOS-E0982] cpl_element '")
        << getSymName() << "' references unknown world '"
        << getWorld() << "'.";
  }
  // A TerminalOp must exist in the world.
  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  bool hasTerminal = false;
  if (cur) {
    auto mod = llvm::cast<ModuleOp>(cur);
    StringRef myWorld = getWorld();
    mod.walk([&](TerminalOp t) {
      if (t.getWorld() == myWorld) {
        hasTerminal = true;
        return WalkResult::interrupt();
      }
      return WalkResult::advance();
    });
  }
  if (!hasTerminal) {
    return emitOpError(
        "[TOPOS-E0982] cpl_element '")
        << getSymName() << "' is in world '" << getWorld()
        << "' which has no declared terminal.\n"
        << "  fix: declare `topos.terminal @<name> in @"
        << getWorld() << "` before any cpl_element.";
  }
  // target must exist as a place or derived place
  if (!placeOrDerivedExists(*this, getTarget())) {
    return emitOpError(
        "[TOPOS-E0982] cpl_element '")
        << getSymName() << "' references unknown target place '"
        << getTarget() << "'.";
  }
  StringRef tgtWorld = derivedPlaceWorld(*this, getTarget());
  if (!tgtWorld.empty() && tgtWorld != getWorld()) {
    return emitOpError(
        "[TOPOS-E0982] cpl_element '")
        << getSymName() << "': target '" << getTarget()
        << "' lives in world '" << tgtWorld
        << "' but the cpl_element is in world '" << getWorld() << "'.";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// AdjointCheckOp (Lambek-Scott Part II Th 15.4)
//===----------------------------------------------------------------------===//

LogicalResult AdjointCheckOp::verify() {
  StringRef worldName = getWorld();
  if (!findWorldByName(*this, worldName)) {
    return emitOpError(
        "[TOPOS-E0990] adjoint_check '")
        << getSymName() << "' references unknown world '"
        << worldName << "'.";
  }

  // Conta le strutture CDT presenti nel world.
  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return success();
  auto mod = llvm::cast<ModuleOp>(cur);

  int nTerminal = 0, nInitial = 0, nRightObj = 0, nLeftObj = 0;
  mod.walk([&](TerminalOp t) {
    if (t.getWorld() == worldName) ++nTerminal;
  });
  mod.walk([&](InitialOp i) {
    if (i.getWorld() == worldName) ++nInitial;
  });
  mod.walk([&](RightObjectOp r) {
    if (r.getWorld() == worldName) ++nRightObj;
  });
  mod.walk([&](LeftObjectOp l) {
    if (l.getWorld() == worldName) ++nLeftObj;
  });

  if (nTerminal == 0) {
    return emitOpError(
        "[TOPOS-E0990] adjoint_check '")
        << getSymName() << "': world '" << worldName
        << "' has no terminal object.\n"
        << "  fix: a topos in Top_0 must have a unique terminal 1. "
           "Declare `topos.terminal @<name> in @" << worldName << "`.";
  }
  if (nInitial == 0) {
    return emitOpError(
        "[TOPOS-E0991] adjoint_check '")
        << getSymName() << "': world '" << worldName
        << "' has no initial object.\n"
        << "  fix: a topos in Top_0 must have a unique initial 0. "
           "Declare `topos.initial @<name> in @" << worldName << "`.";
  }
  if (nRightObj == 0) {
    return emitOpError(
        "[TOPOS-E0992] adjoint_check '")
        << getSymName() << "': world '" << worldName
        << "' has no right_object declarations.\n"
        << "  fix: a topos in Top_0 admits products and exponentials, "
           "represented as Hagino right objects. Declare at least one "
           "`topos.right_object` (e.g. a product) or use "
           "`topos.exponential` to satisfy this requirement.";
  }
  if (nLeftObj == 0) {
    // Coproduct is a colimit; in Yon it is both ExpressableViaLeftObject and
    // directly with CoproductOp; we consider that CoproductOp satisfies the
    // structural requirement (Lurie 4.4.1 says colim decomposes into
    // coequalizer + coproducts, so having a CoproductOp is sufficient).
    int nCoproductFallback = 0;
    mod.walk([&](CoproductOp c) {
      // Verify that its components live in worldName.
      auto comps = c.getComponents();
      if (comps.empty()) return;
      auto firstSym = llvm::cast<FlatSymbolRefAttr>(comps[0]);
      if (auto p = findPlaceByName(*this, firstSym.getValue())) {
        if (placeWorldName(p) == worldName) ++nCoproductFallback;
      }
    });
    if (nCoproductFallback == 0) {
      return emitOpError(
          "[TOPOS-E0993] adjoint_check '")
          << getSymName() << "': world '" << worldName
          << "' has no left_object (nor coproduct) declarations.\n"
          << "  fix: a topos in Top_0 admits coproducts. Declare at "
             "least one `topos.left_object` (e.g. a coproduct of "
             "two places) or use `topos.coproduct` to satisfy this "
             "requirement.";
    }
  }

  // All structural checks passed. The world is (structurally) a candidate for
  // Top_0 for the T |- L adjunction. The homotopy proof T(L(F)) ~= F is
  // delegated to future passes.
  return success();
}

//===----------------------------------------------------------------------===//
// ScopeOp / ScopeWithYieldOp — captures verification
//===----------------------------------------------------------------------===//

// Common verifier: the number of block arguments of the body must equal the
// number of captures, and the types must match one-to-one.
// Codici errore: [TOPOS-E1010..E1011]
static LogicalResult verifyScopeCaptures(Operation *op, OperandRange captures,
                                          Region &body, StringRef opName) {
  if (body.empty()) return success();
  Block &entry = body.front();

  size_t numCaptures = captures.size();
  size_t numArgs = entry.getNumArguments();

  if (numCaptures != numArgs) {
    return op->emitOpError(
        "[TOPOS-E1010] ")
        << opName << " has " << numCaptures
        << " capture operand(s) but its body block has "
        << numArgs << " argument(s).\n"
        << "  fix: the body block of a scope with captures must have "
           "one block argument per captured operand. Add or remove "
           "block arguments to match.";
  }

  for (size_t i = 0; i < numCaptures; ++i) {
    Type capTy = captures[i].getType();
    Type argTy = entry.getArgument(i).getType();
    if (capTy != argTy) {
      return op->emitOpError(
          "[TOPOS-E1011] ")
          << opName << " capture #" << i << " has type " << capTy
          << " but block argument #" << i << " has type " << argTy
          << ".\n  fix: capture and block argument types must match.";
    }
  }

  return success();
}

LogicalResult ScopeOp::verify() {
  return verifyScopeCaptures(*this, getCaptures(), getBody(), "scope");
}

LogicalResult ScopeWithYieldOp::verify() {
  return verifyScopeCaptures(*this, getCaptures(), getBody(),
                              "scope_with_yield");
}

//===----------------------------------------------------------------------===//
// FibrationOp / ReindexOp / IndeterminateOp / KleisliOp — Hermida fibrations
//===----------------------------------------------------------------------===//

// Helper: find a FibrationOp by name.
static FibrationOp findFibrationByName(Operation *op, StringRef name) {
  Operation *cur = op->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return nullptr;
  auto mod = llvm::cast<ModuleOp>(cur);
  FibrationOp found;
  mod.walk([&](FibrationOp f) {
    if (f.getSymName() == name) {
      found = f;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  return found;
}

// FibrationOp verify:
//   (a) base and total exist as worlds
//   (b) base != total (the trivial fibration id_B is useful but we avoid it by
//       default: emitted explicitly only via the attribute `self_fibration`
//       if really needed. For now: an error if equal.)
//   (c) generic_object, if present, must exist as a PlaceOp of the
//       world `total`. Hermida 2.x: the generic object is in the total.
LogicalResult FibrationOp::verify() {
  if (!findWorldByName(*this, getBase())) {
    return emitOpError(
        "[TOPOS-E1000] fibration '")
        << getSymName() << "' references unknown base world '"
        << getBase() << "'.";
  }
  if (!findWorldByName(*this, getTotal())) {
    return emitOpError(
        "[TOPOS-E1000] fibration '")
        << getSymName() << "' references unknown total world '"
        << getTotal() << "'.";
  }
  if (getBase() == getTotal()) {
    return emitOpError(
        "[TOPOS-E1001] fibration '")
        << getSymName() << "': base and total are the same world ('"
        << getBase() << "'); the identity fibration is trivial and "
           "should not be declared explicitly.\n"
        << "  fix: choose distinct worlds for base and total, or use "
           "a `topos.geom_morphism` for a self-functor.";
  }
  if (auto gOpt = getGenericObject()) {
    StringRef gName = *gOpt;
    auto gPlace = findPlaceByName(*this, gName);
    if (!gPlace) {
      return emitOpError(
          "[TOPOS-E1002] fibration '")
          << getSymName() << "': generic object '" << gName
          << "' is not a declared place.\n"
          << "  fix: the generic object of a lambda-arrow-fibration (Hermida "
             "cap 2) must be a place in the total world.";
    }
    if (placeWorldName(gPlace) != getTotal()) {
      return emitOpError(
          "[TOPOS-E1002] fibration '")
          << getSymName() << "': generic object '" << gName
          << "' lives in world '" << placeWorldName(gPlace)
          << "' but must be in the total world '" << getTotal() << "'.";
    }
  }
  return success();
}

// ReindexOp verify:
//   - the fibration exists
//   - base_morphism exists as a MoveOp in the fibration's base world
LogicalResult ReindexOp::verify() {
  auto fib = findFibrationByName(*this, getFibration());
  if (!fib) {
    return emitOpError(
        "[TOPOS-E1003] reindex '")
        << getSymName() << "' references unknown fibration '"
        << getFibration() << "'.";
  }
  auto m = findMoveOpByName(*this, getBaseMorphism());
  if (!m) {
    return emitOpError(
        "[TOPOS-E1003] reindex '")
        << getSymName() << "' references unknown base morphism '"
        << getBaseMorphism() << "'.";
  }
  // The move must be "in base": its source/target must be places of the
  // fibration's base world.
  auto srcPlace = findPlaceByName(*this, m.getSourcePlace());
  auto tgtPlace = findPlaceByName(*this, m.getTargetPlace());
  if (srcPlace && placeWorldName(srcPlace) != fib.getBase()) {
    return emitOpError(
        "[TOPOS-E1004] reindex '")
        << getSymName() << "': base morphism '" << getBaseMorphism()
        << "' has source '" << m.getSourcePlace()
        << "' in world '" << placeWorldName(srcPlace)
        << "', but the fibration's base is '" << fib.getBase() << "'.\n"
        << "  fix: reindexing is induced by a morphism IN the base.";
  }
  if (tgtPlace && placeWorldName(tgtPlace) != fib.getBase()) {
    return emitOpError(
        "[TOPOS-E1004] reindex '")
        << getSymName() << "': base morphism '" << getBaseMorphism()
        << "' has target '" << m.getTargetPlace()
        << "' in world '" << placeWorldName(tgtPlace)
        << "', but the fibration's base is '" << fib.getBase() << "'.";
  }
  return success();
}

// IndeterminateOp verify:
//   - type_place exists as a place of the base_world
//   - base_world exists as a world
//   - there is not already a cpl_element of the same name in the base_world
//     (because the indeterminate would be ambiguous with a real canonical
//     element)
LogicalResult IndeterminateOp::verify() {
  if (!findWorldByName(*this, getBaseWorld())) {
    return emitOpError(
        "[TOPOS-E1005] indeterminate '")
        << getSymName() << "' references unknown base world '"
        << getBaseWorld() << "'.";
  }
  auto tPlace = findPlaceByName(*this, getTypePlace());
  if (!tPlace) {
    return emitOpError(
        "[TOPOS-E1005] indeterminate '")
        << getSymName() << "': type place '" << getTypePlace()
        << "' not found.";
  }
  if (placeWorldName(tPlace) != getBaseWorld()) {
    return emitOpError(
        "[TOPOS-E1005] indeterminate '")
        << getSymName() << "': type place '" << getTypePlace()
        << "' lives in world '" << placeWorldName(tPlace)
        << "' but the indeterminate is being added to '"
        << getBaseWorld() << "'.";
  }

  // Non-collision check against cpl_elements of the same name.
  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return success();
  auto mod = llvm::cast<ModuleOp>(cur);
  StringRef myName = getSymName();
  StringRef myWorld = getBaseWorld();
  CplElementOp collision;
  mod.walk([&](CplElementOp e) {
    if (e.getSymName() == myName && e.getWorld() == myWorld) {
      collision = e;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (collision) {
    return emitOpError(
        "[TOPOS-E1006] indeterminate '")
        << myName << "' collides with cpl_element '"
        << collision.getSymName() << "' of the same name in world '"
        << myWorld << "'.\n"
        << "  fix: an indeterminate is a *symbolic* global element; "
           "it cannot coexist with a real cpl_element of the same "
           "name. Rename one of the two.";
  }
  return success();
}

// KleisliOp verify:
//   - the world exists
//   - comonad_reduction exists as a ReduceOp in the world itself
//     (the comonad is a self-functor of the world: this captures it as a
//     "reduction on a place of the world")
LogicalResult KleisliOp::verify() {
  if (!findWorldByName(*this, getWorld())) {
    return emitOpError(
        "[TOPOS-E1007] kleisli '")
        << getSymName() << "' references unknown world '"
        << getWorld() << "'.";
  }
  // Cerco ReduceOp con nome `comonad_reduction`.
  Operation *cur = (*this)->getParentOp();
  while (cur && !llvm::isa<ModuleOp>(cur)) cur = cur->getParentOp();
  if (!cur) return success();
  auto mod = llvm::cast<ModuleOp>(cur);
  bool found = false;
  StringRef rname = getComonadReduction();
  mod.walk([&](ReduceOp r) {
    if (r.getSymName() == rname) {
      found = true;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });
  if (!found) {
    return emitOpError(
        "[TOPOS-E1008] kleisli '")
        << getSymName() << "' references unknown reduction '"
        << rname << "' to be used as comonad.\n"
        << "  fix: declare a `topos.reduce` first, then refer to "
           "it as the comonad of this kleisli object.";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// TopologyOp
//===----------------------------------------------------------------------===//

// Verify: of_place exists. The Lawvere-Tierney properties
// (j(true) = true, j o j = j, j(p AND q) = j(p) AND j(q)) are semantic
// predicates on the bodies, out of scope for the structural verifier.
LogicalResult TopologyOp::verify() {
  auto place = findPlaceByName(*this, getOfPlace());
  if (!place)
    return emitOpError("topology '")
           << getSymName() << "' references unknown place '"
           << getOfPlace() << "'";
  return success();
}

//===----------------------------------------------------------------------===//
// GeomMorphismOp
//===----------------------------------------------------------------------===//

// Verifies a geometric morphism between two topoi:
//   (1) source_site is a declared world;
//   (2) target_site is a declared world;
//   (3) if `proper_base_change_attested` is set, the pull region must
//       be syntactically pure (proper base change requires
//       a left-exact pull functor, which we approximate by syntactic
//       purity of its body).
//
// The structural presence of both pull and push regions is already
// enforced by TableGen via SizedRegion<1>; the semantic naturality
// of the unit/counit of the adjunction is left to a downstream pass.
LogicalResult GeomMorphismOp::verify() {
  if (!findWorldByName(*this, getSourceSite())) {
    return emitOpError("[TOPOS-E0431] geometric morphism '")
           << getSymName() << "' has source_site '" << getSourceSite()
           << "', but no `topos.world` with that name is declared.\n"
              "  fix: declare the source world before this geometric "
              "morphism.";
  }
  if (!findWorldByName(*this, getTargetSite())) {
    return emitOpError("[TOPOS-E0432] geometric morphism '")
           << getSymName() << "' has target_site '" << getTargetSite()
           << "', but no `topos.world` with that name is declared.\n"
              "  fix: declare the target world before this geometric "
              "morphism.";
  }

  // (3) the left-exactness of pull is attested by the user via the attribute.
  // The structural check of the pull functor as syntactically pure is no longer
  // applicable at the dialect level (GeomMorphismOp is now a pure declaration —
  // the functors live in separate runtime functions). The
  // `--proper-base-change-check` pass will verify the purity of the
  // `<name>__pull` function when it is emitted.
  return success();
}

//===----------------------------------------------------------------------===//
// PabsOp purity verifier
//
// Reference: Turbak 12.2.2 [forall-intro] purity restriction.
//
// A pabs (universal polymorphism abstraction) is well-formed only if its body
// is syntactically pure: no observable side effect. A conservative test (sound,
// not complete) a la Turbak Figure 13.25:
//
//   pure(literal) = true
//   pure(op with MLIR's Pure trait) = true
//   pure(known-pure Topos dialect op) = true (see whitelist)
//   pure(composition of pure ops with pure regions) = true
//   pure(other) = false  (conservative)
//
// Inlined implementation (no external helper factored out, to avoid premature
// cross-file dependencies; the pattern is reused elsewhere).
//===----------------------------------------------------------------------===//

// Verifies a universal polymorphism abstraction (`topos.pabs`):
//   (1) the `type_params` attribute is non-empty;
//   (2) the `type_params` contain no duplicates;
//   (3) the body region is syntactically pure.
//
// The third check enforces the purity restriction on polymorphism
// introduction. Without it, polymorphic projection via `topos.pcall`
// would have evaluation-order-dependent semantics, and parametricity
// would silently fail.
LogicalResult PabsOp::verify() {
  ArrayAttr params = getTypeParams();

  // Check (1): non-empty type parameter list.
  if (params.empty()) {
    return emitOpError(
        "[TOPOS-E0181] universal polymorphism abstraction requires at "
        "least one type parameter, but `type_params` is the empty "
        "array. A pabs with zero parameters carries no abstraction "
        "and is degenerate; use the body expression directly instead.\n"
        "  context: a polymorphism introduction (Λ τ. e) must bind at "
        "least one type variable.");
  }

  // Check (2): every entry of `type_params` is a string attribute,
  // and all entries are unique.
  llvm::StringSet<> seen;
  for (Attribute a : params) {
    auto s = llvm::dyn_cast<StringAttr>(a);
    if (!s) {
      return emitOpError(
          "[TOPOS-E0182] every entry of `type_params` must be a string "
          "attribute naming a type identifier, but found an attribute "
          "of a different kind.\n"
          "  fix: write `type_params = [\"s\", \"t\", ...]` with all "
          "entries quoted as strings.");
    }
    if (!seen.insert(s.getValue()).second) {
      return emitOpError("[TOPOS-E0183] type parameter '")
             << s.getValue()
             << "' is declared more than once in `type_params`. "
                "Each forall-bound identifier must be unique within a "
                "single pabs.\n"
                "  fix: rename one of the duplicates, or introduce "
                "nested `topos.pabs` if shadowing is intended.";
    }
  }

  // Check (3): body purity.
  if (!isRegionPure(getBody())) {
    return emitOpError(
        "[TOPOS-E0184] body of `topos.pabs` is not syntactically pure: "
        "it contains an operation that may produce side effects.\n"
        "  fix: hoist the impure expression (allocation, mutation, IO, "
        "`topos.promote`, ...) above the `topos.pabs`, bind its result "
        "with `let`, and reference the bound name inside the pabs "
        "body.\n"
        "  context: a polymorphism introduction Λ τ. e must be pure "
        "so that every projection of the polymorphic value denotes "
        "the same evaluation; otherwise parametricity is lost.");
  }

  return success();
}

//===----------------------------------------------------------------------===//
// DselectOp purity verifier
//
// Reference: Turbak 15.4.4 [moduleof-elim] purity restriction.
//
// A dselect is well-formed only if its module_expr is pure. The check is based
// on the op that produces the operand: if it is a pure op according to
// isOpSyntacticallyPure (the test shared with the pabs verifier), dselect is
// admissible. If the operand is a BlockArgument (coming from a function/region
// parameter), we accept it as pure: block arguments have no intrinsic side
// effects, they are values passed explicitly.
//
// Workaround pattern for the programmer (Turbak 15.7.4): if `module_expr` is an
// impure application, bind it via let first:
//   %m = ...impure place expr...
//   topos.dselect "tc" of %m : ...
// — here `%m` is a block argument or the result of a let-binding, hence pure.
//===----------------------------------------------------------------------===//

// Verifies a dependent type constructor selection (`topos.dselect`):
// the operand `module_expr` must be syntactically pure.
//
// Without purity, the dependent type system could attribute different
// types to the same expression at different evaluation points, breaking
// soundness (Turbak 15.4.4, [moduleof-elim] purity restriction). The
// classical workaround when the underlying module expression is impure
// is to let-bind it first and then `dselect` on the let-name, since
// names (block arguments) are always considered pure.
LogicalResult DselectOp::verify() {
  Value operand = getModuleExpr();

  // A block argument represents a value already computed and bound;
  // it carries no further side effect.
  if (operand.isa<BlockArgument>())
    return success();

  Operation *producer = operand.getDefiningOp();
  if (!producer) {
    return emitOpError(
        "[TOPOS-E0271] `module_expr` operand has no defining "
        "operation. This is an inconsistent IR state, likely produced "
        "by a bug in an earlier compiler pass.\n"
        "  fix: file a bug report; this should never occur in IR "
        "produced by the front end.");
  }

  if (!isOpSyntacticallyPure(producer)) {
    return emitOpError(
        "[TOPOS-E0272] `module_expr` operand of `topos.dselect` is "
        "not syntactically pure: it is produced by an operation that "
        "may have side effects.\n"
        "  fix: bind the impure expression with a `let`-style "
        "introduction (block argument), then apply `topos.dselect` "
        "to the bound name. Names are always pure.\n"
        "  context: dependent type constructors of the form "
        "`(dselect θ E)` require `E` to be pure; otherwise the same "
        "syntactic expression could denote different type constructors "
        "at different evaluation points, breaking type soundness.");
  }

  return success();
}

//===----------------------------------------------------------------------===//
// DepPropositionOp purity verifier
//===----------------------------------------------------------------------===//

// Verifies that a dependent proposition declaration has a pure body.
// A dependent proposition is one whose truth value is used to dispatch
// between branches of distinct types (e.g. inside a dependent `if`).
// If evaluating the body could produce side effects, the type system
// would commit to a branch based on impure data, breaking soundness.
LogicalResult DepPropositionOp::verify() {
  if (!isRegionPure(getBody())) {
    return emitOpError(
        "[TOPOS-E0270] body of `topos.dep_proposition` is not "
        "syntactically pure: it contains an operation that may "
        "produce side effects.\n"
        "  fix: if you only need a non-dependent proposition (e.g. "
        "for a runtime assertion), replace `topos.dep_proposition` "
        "with a plain `topos.heyt` or a regular Heyting combinator.\n"
        "  context: this proposition is used as a predicate for "
        "dependent type dispatch (i.e. branches at distinct types "
        "depend on its value), so its evaluation must produce the "
        "same result every time it is reached; an impure body "
        "would let the dispatched type depend on evaluation order.");
  }
  return success();
}

//===----------------------------------------------------------------------===//
// OrIntroOp / ExistsIntroOp verifiers
//===----------------------------------------------------------------------===//

// Verifies a constructive disjunction-introduction. The `side`
// attribute must be exactly `"left"` or `"right"`, so the proof
// explicitly witnesses which disjunct holds. Classical derivations
// such as NOT NOT (P OR Q) => (P OR Q) are not admissible here.
LogicalResult OrIntroOp::verify() {
  StringRef side = getSide();
  if (side != "left" && side != "right") {
    return emitOpError("[TOPOS-E0276] `side` attribute must be ")
           << "either \"left\" or \"right\", but found \"" << side
           << "\".\n"
           << "  fix: set `side = \"left\"` if the proof witnesses "
              "the first disjunct, or `side = \"right\"` if it "
              "witnesses the second.\n"
              "  context: this op constructs a proof of a disjunction "
              "`P OR Q` and must record which of the two disjuncts has "
              "actually been proven; an absent or invalid `side` "
              "leaves the disjunction with no concrete justification.";
  }
  // `proven_side` is constrained to `!topos.proposition` by TableGen,
  // so no further structural check is needed here.
  return success();
}

// Verifies a constructive existence-introduction. An explicit witness
// operand is mandatory. We additionally reject `topos.coherence` as a
// witness, because coherence is a placeholder used by the optimizer
// for filler equalities and does not denote a concrete instance.
LogicalResult ExistsIntroOp::verify() {
  Value w = getWitness();
  if (!w) {
    // Defensive: TableGen ensures the operand is present, but we
    // surface a clear message if the IR somehow lacks it.
    return emitOpError(
        "[TOPOS-E0277] `topos.exists_intro` requires an explicit "
        "witness operand, but none was provided.\n"
        "  fix: supply the concrete value `a` (the term such that "
        "`P(a)` holds) as the first operand of `topos.exists_intro`.\n"
        "  context: this op constructs a proof of `exists x. P(x)` by "
        "exhibiting a specific witness; without a witness operand "
        "there is no concrete value to attach the existence claim "
        "to.");
  }
  if (Operation *p = w.getDefiningOp()) {
    StringRef opName = p->getName().getStringRef();
    if (opName == "topos.coherence") {
      return emitOpError(
          "[TOPOS-E0278] witness operand of `topos.exists_intro` is "
          "produced by `topos.coherence`, which is a placeholder for "
          "filler equalities and does not denote a concrete value of "
          "the underlying type.\n"
          "  fix: replace the coherence placeholder with an actual "
          "instance construction such as `topos.section`, a "
          "constant, a block argument, or any concrete value of the "
          "expected type.\n"
          "  context: existence proofs must witness real elements, "
          "not opaque coherence tokens.");
    }
  }
  return success();
}

//===----------------------------------------------------------------------===//
// SharingConstraintOp verifier
//===----------------------------------------------------------------------===//

// Verifies a SML-style sharing declaration between two places:
//   (1) the two place names differ (sharing with itself is trivial);
//   (2) both place names resolve to existing `topos.place` symbols
//       in the enclosing module.
//
// The deeper semantic check that both places actually declare a type
// constructor of the given name is deferred to a later analysis pass,
// since it requires deep introspection of the place bodies.
LogicalResult SharingConstraintOp::verify() {
  StringRef nameA = getPlaceA();
  StringRef nameB = getPlaceB();

  if (nameA == nameB) {
    return emitOpError("[TOPOS-E0521] sharing constraint for type "
                       "constructor '")
           << getTcName() << "' between place '" << nameA
           << "' and itself is trivial.\n"
              "  fix: either remove this constraint, or replace one "
              "of the place names with a distinct place that "
              "genuinely shares the abstract type.\n"
              "  context: a sharing declaration conveys information "
              "to the type checker only when it links two distinct "
              "abstract types.";
  }

  Operation *placeA = findPlaceByName(*this, nameA);
  if (!placeA) {
    return emitOpError("[TOPOS-E0522] sharing constraint references "
                       "place '")
           << nameA
           << "', but no `topos.place` with that name was found in "
              "any world of the enclosing module.\n"
              "  fix: ensure the place is declared (with a matching "
              "`sym_name`) before this sharing constraint.";
  }

  Operation *placeB = findPlaceByName(*this, nameB);
  if (!placeB) {
    return emitOpError("[TOPOS-E0523] sharing constraint references "
                       "place '")
           << nameB
           << "', but no `topos.place` with that name was found in "
              "any world of the enclosing module.\n"
              "  fix: ensure the place is declared (with a matching "
              "`sym_name`) before this sharing constraint.";
  }

  return success();
}

//===----------------------------------------------------------------------===//
// CellOp n-connectivity verifier
//===----------------------------------------------------------------------===//

// Verifies that when `n_connective_lvl` is given, it is consistent
// with the cell's `dimension`. The level n is an upper bound on the
// homotopy dimension of trivial structure; a k-cell with declared
// n-connectivity must have n >= k.
LogicalResult CellOp::verify() {
  auto nlvl = getNConnectiveLvl();
  if (!nlvl)
    return success();
  int32_t n = *nlvl;
  int32_t k = getDimension();
  if (n < k) {
    return emitOpError("[TOPOS-E0291] cell '")
           << getSymName() << "' has dimension " << k
           << " but declares `n_connective_lvl = " << n
           << "`, which is strictly less than the dimension.\n"
              "  fix: either raise `n_connective_lvl` to at least "
           << k << ", or drop the attribute if you do not need to "
                   "constrain connectivity.\n"
                   "  context: a cell of dimension k carries "
                   "non-trivial structure at level k, so the level "
                   "of connectivity (below which structure is "
                   "trivial) cannot be smaller than k.";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// BATCH A — 12 verify() implementations
//===----------------------------------------------------------------------===//

// explicit subtype coercion. For now we accept iff the
// source and target types are syntactically equal; the broader set of
// subtype rules (arrow co/contra, record width/depth, oneof,
// forall, μ) is delegated to a downstream pass.
LogicalResult TheOp::verify() {
  Type s = getSource().getType();
  Type t = getTargetType();
  Type out = getCoerced().getType();
  if (t != out) {
    return emitOpError("[TOPOS-E0185] declared target_type and result "
                       "type of `topos.the` must agree, but they do "
                       "not.\n"
                       "  fix: ensure that the result type printed "
                       "after `->` matches the `target_type` "
                       "attribute exactly.\n"
                       "  context: `topos.the` is a tagged coercion "
                       "and the tag is the result type itself.");
  }
  if (s != t) {
    return emitOpError("[TOPOS-E0186] `topos.the` coercion from "
                       "source type to target type is not justified "
                       "by syntactic type equality; non-trivial "
                       "subtype coercion is not yet supported by "
                       "this verifier (waiting on the subtype-rule "
                       "pass).\n"
                       "  fix: either change the operand so its type "
                       "matches the target exactly, or rebuild the "
                       "value with the correct type before applying "
                       "`topos.the`.\n"
                       "  context: this version accepts only "
                       "S = T; a future verifier extension will "
                       "accept S <= T according to the full subtype "
                       "rule set.");
  }
  return success();
}

// bounded universal quantification.
LogicalResult PabsBoundedOp::verify() {
  ArrayAttr params = getTypeParams();
  ArrayAttr bounds = getBounds();
  if (params.empty()) {
    return emitOpError("[TOPOS-E0187] bounded pabs requires at least "
                       "one type parameter, but `type_params` is "
                       "empty.\n"
                       "  fix: declare at least one parameter, e.g. "
                       "`[\"t\"] <: [some_type]`.");
  }
  if (params.size() != bounds.size()) {
    return emitOpError("[TOPOS-E0188] `type_params` and `bounds` must "
                       "have the same number of entries, but ")
           << params.size() << " parameters were given against "
           << bounds.size() << " bounds.\n"
              "  fix: provide exactly one upper bound type per type "
              "parameter, in the same order.";
  }
  llvm::StringSet<> seen;
  for (Attribute a : params) {
    auto s = llvm::dyn_cast<StringAttr>(a);
    if (!s) {
      return emitOpError("[TOPOS-E0189] every entry of `type_params` "
                         "must be a string attribute.");
    }
    if (!seen.insert(s.getValue()).second) {
      return emitOpError("[TOPOS-E0190] type parameter '")
             << s.getValue() << "' is declared more than once.\n"
             "  fix: rename the duplicate, or nest a second "
             "`topos.pabs_bounded` if shadowing is intended.";
    }
  }
  if (!isRegionPure(getBody())) {
    return emitOpError(
        "[TOPOS-E0191] body of `topos.pabs_bounded` is not "
        "syntactically pure: it contains an operation that may "
        "produce side effects.\n"
        "  fix: hoist the impure expression above the abstraction, "
        "let-bind its result, and reference the bound name inside "
        "the body.\n"
        "  context: bounded polymorphism shares the purity "
        "requirement of plain polymorphism so that every projection "
        "denotes the same evaluation.");
  }
  return success();
}

// Type class declaration.
LogicalResult ClassOp::verify() {
  if (getTypeParam().empty()) {
    return emitOpError("[TOPOS-E0192] type class '")
           << getSymName() << "' must declare a non-empty "
              "`type_param` (the name of the class's type "
              "variable).\n"
              "  fix: set `type_param` to a single identifier, e.g. "
              "\"a\".";
  }
  // The body region must contain at least one operation signature.
  if (getBody().front().empty()) {
    return emitOpError("[TOPOS-E0193] type class '")
           << getSymName() << "' has an empty body; a class with no "
              "members is meaningless.\n"
              "  fix: add at least one `topos.operation` declaration "
              "in the class body to specify the required interface.";
  }
  return success();
}

// Type class instance.
LogicalResult InstanceOp::verify() {
  StringRef cls = getClassName();
  // Resolve the class symbol up to the enclosing ModuleOp.
  Operation *cur = getOperation()->getParentOp();
  while (cur && !isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur) {
    return emitOpError("[TOPOS-E0194] `topos.instance` is not inside "
                       "a module; cannot resolve class reference.");
  }
  auto mod = cast<ModuleOp>(cur);
  Operation *classOp = SymbolTable::lookupSymbolIn(mod, cls);
  if (!classOp || classOp->getName().getStringRef() != "topos.class") {
    return emitOpError("[TOPOS-E0195] `topos.instance` references "
                       "class '")
           << cls << "', but no `topos.class` with that name is "
                     "declared in the enclosing module.\n"
                     "  fix: declare the class first (with `topos.class"
                     " @" << cls << " ...`), or correct the class "
                     "reference in this instance.";
  }
  if (getBody().front().empty()) {
    return emitOpError("[TOPOS-E0196] `topos.instance` for class '")
           << cls << "' has an empty body; the instance must implement "
                     "the class's operations.\n"
                     "  fix: add one implementation per operation "
                     "declared by the class.";
  }
  return success();
}

// build a topos from a site.
LogicalResult FromSiteOp::verify() {
  Operation *cat = findWorldByName(*this, getBaseCategory());
  if (!cat) {
    return emitOpError("[TOPOS-E0273] `topos.from_site` references "
                       "base category '")
           << getBaseCategory()
           << "', but no `topos.world` with that name is declared in "
              "the enclosing module.\n"
              "  fix: declare the underlying small category as a "
              "world first, then reference it here.";
  }
  // The topology symbol is searched in the module too: it must be a
  // `topos.topology` op.
  Operation *cur = getOperation()->getParentOp();
  while (cur && !isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur)
    return emitOpError("[TOPOS-E0274] `topos.from_site` is not inside "
                       "a module.");
  auto mod = cast<ModuleOp>(cur);
  Operation *topo = SymbolTable::lookupSymbolIn(mod, getTopology());
  if (!topo || topo->getName().getStringRef() != "topos.topology") {
    return emitOpError("[TOPOS-E0279] `topos.from_site` references "
                       "topology '")
           << getTopology()
           << "', but no `topos.topology` with that name is declared.\n"
              "  fix: declare the coverage as a `topos.topology` op, "
              "then refer to it here.";
  }
  return success();
}

// canonical site extraction.
LogicalResult CanonicalSiteOp::verify() {
  if (!findWorldByName(*this, getWorldName())) {
    return emitOpError("[TOPOS-E0280] `topos.canonical_site` "
                       "references world '")
           << getWorldName()
           << "', but no `topos.world` with that name is declared.\n"
              "  fix: ensure the world is declared before extracting "
              "its canonical site.";
  }
  return success();
}

// Čech nerve verifier.
LogicalResult CechNerveOp::verify() {
  // The cover_morphism must resolve to a topos.move (the move
  // representing the covering family). We search the move symbol
  // up to ModuleOp.
  StringRef name = getCoverMorphism();
  Operation *cur = getOperation()->getParentOp();
  while (cur && !isa<ModuleOp>(cur))
    cur = cur->getParentOp();
  if (!cur)
    return emitOpError("[TOPOS-E0281] `topos.cech_nerve` is not "
                       "inside a module.");
  auto mod = cast<ModuleOp>(cur);
  Operation *found = nullptr;
  mod.walk([&](Operation *candidate) {
    if (candidate->getName().getStringRef() == "topos.move") {
      if (auto sym = candidate->getAttrOfType<StringAttr>(
              SymbolTable::getSymbolAttrName())) {
        if (sym.getValue() == name) {
          found = candidate;
          return WalkResult::interrupt();
        }
      }
    }
    return WalkResult::advance();
  });
  if (!found) {
    return emitOpError("[TOPOS-E0282] `topos.cech_nerve` references "
                       "move '")
           << name
           << "', but no `topos.move` with that name was found in "
              "the enclosing module.\n"
              "  fix: declare the covering family as a `topos.move` "
              "first, then reference it here.";
  }
  return success();
}

// Kripke-Joyal forcing.
LogicalResult KripkeJoyalForcingOp::verify() {
  StringRef c = getConnective();
  static const llvm::StringRef admitted[] = {"and", "or", "implies",
                                              "forall", "exists",
                                              "atom"};
  bool ok = false;
  for (StringRef a : admitted)
    if (c == a) { ok = true; break; }
  if (!ok) {
    return emitOpError("[TOPOS-E0283] `topos.kripke_joyal_forcing` "
                       "`connective` attribute must be one of "
                       "{\"and\", \"or\", \"implies\", \"forall\", "
                       "\"exists\", \"atom\"}, but found \"")
           << c << "\".\n"
                   "  fix: set `connective` to the logical "
                   "connective being interpreted at this stage.\n"
                   "  context: each connective is interpreted by a "
                   "distinct clause of the forcing relation; the tag "
                   "selects the clause.";
  }
  return success();
}

// canonical subobjects.
LogicalResult CanonicalSubplaceOp::verify() {
  StringRef parent = getParentPlace();
  if (!findPlaceByName(*this, parent)) {
    return emitOpError("[TOPOS-E0284] `topos.canonical_subplace` "
                       "references parent place '")
           << parent
           << "', but no `topos.place` with that name was found.\n"
              "  fix: ensure the parent place is declared before "
              "this canonical subplace.";
  }
  // The classifier must be of !topos.proposition type.
  Type cls = getClassifier().getType();
  // We accept any type whose name ends in `.proposition` to avoid
  // hard-coding the C++ class. A stricter check can be added later.
  std::string s;
  llvm::raw_string_ostream os(s);
  cls.print(os);
  if (os.str().find("proposition") == std::string::npos) {
    return emitOpError("[TOPOS-E0285] classifier of "
                       "`topos.canonical_subplace` must be of type "
                       "`!topos.proposition`, but the operand has "
                       "type ")
           << cls << ".\n"
                     "  fix: pass a value of `!topos.proposition` "
                     "type (e.g. obtained via `topos.heyt` or a "
                     "Heyting combinator) as the classifier.";
  }
  return success();
}

// split fibration verifier.
LogicalResult SplitFibrationOp::verify() {
  StringRef total = getTotal();
  StringRef base = getBase();
  if (total == base) {
    return emitOpError("[TOPOS-E0524] split fibration must have "
                       "distinct total and base worlds, but both "
                       "are '")
           << total << "'.\n"
                       "  fix: provide two different world names; "
                       "the fibration projects the total category "
                       "onto a strictly different base.";
  }
  if (!findWorldByName(*this, total)) {
    return emitOpError("[TOPOS-E0525] split fibration's total "
                       "world '")
           << total << "' is not a declared `topos.world`.\n"
                       "  fix: declare the total world first.";
  }
  if (!findWorldByName(*this, base)) {
    return emitOpError("[TOPOS-E0526] split fibration's base "
                       "world '")
           << base << "' is not a declared `topos.world`.\n"
                       "  fix: declare the base world first.";
  }
  return success();
}

// dependent place.
LogicalResult PlaceDependentOp::verify() {
  if (getWorldParam().empty()) {
    return emitOpError("[TOPOS-E0527] dependent place '")
           << getSymName() << "' must declare a non-empty "
              "`world_param` (the name of the world parameter the "
              "place depends on).\n"
              "  fix: set `world_param` to a single identifier "
              "naming the dependency.";
  }
  if (getBody().front().empty()) {
    return emitOpError("[TOPOS-E0528] dependent place '")
           << getSymName() << "' has an empty body; a place must "
              "declare at least one field, operation, or cell.\n"
              "  fix: add at least one structural member in the "
              "body.";
  }
  return success();
}

// invert (topos of fractions).
LogicalResult InvertOp::verify() {
  StringRef src = getSourceWorld();
  if (!findWorldByName(*this, src)) {
    return emitOpError("[TOPOS-E0529] `topos.invert` references "
                       "source world '")
           << src << "', but no `topos.world` with that name is "
                     "declared.\n"
                     "  fix: declare the source world first, then "
                     "build the inverted world from it.";
  }
  ArrayAttr reds = getReductionsToInvert();
  if (reds.empty()) {
    return emitOpError("[TOPOS-E0530] `topos.invert` was given an "
                       "empty list of reductions to invert; the "
                       "resulting world would equal the source "
                       "world.\n"
                       "  fix: list at least one reduction name in "
                       "`reductions_to_invert`, or drop the "
                       "`topos.invert` entirely.");
  }
  llvm::StringSet<> seen;
  for (Attribute a : reds) {
    auto s = llvm::dyn_cast<StringAttr>(a);
    if (!s) {
      return emitOpError("[TOPOS-E0531] every entry of "
                         "`reductions_to_invert` must be a string "
                         "attribute naming a reduction.");
    }
    if (!seen.insert(s.getValue()).second) {
      return emitOpError("[TOPOS-E0532] reduction '")
             << s.getValue() << "' appears more than once in "
                                "`reductions_to_invert`.\n"
                                "  fix: list each reduction at most "
                                "once.";
    }
  }
  return success();
}

// load_world coherence verifier (structural).
LogicalResult LoadWorldOp::verify() {
  if (getPath().empty()) {
    return emitOpError("[TOPOS-E0533] `topos.load_world` requires a "
                       "non-empty `path` attribute.\n"
                       "  fix: set `path` to the file from which the "
                       "world should be loaded.");
  }
  StringRef expected = getExpectedWorld();
  if (!findWorldByName(*this, expected)) {
    return emitOpError("[TOPOS-E0534] `topos.load_world` expects the "
                       "loaded file to have world type '")
           << expected
           << "', but no `topos.world` with that name is declared in "
              "the enclosing module to act as the type tag.\n"
              "  fix: declare the expected world (as a forward "
              "declaration or full definition) before the "
              "`topos.load_world`.";
  }
  return success();
}

//===----------------------------------------------------------------------===//
// coeffect_pure / extract / extend verifiers
//
// All three ops share a single check: the `algebra` attribute must
// name one of the recognised coeffect algebras (same allow-list used
// by the place's `coeffect_algebra` attribute).
//===----------------------------------------------------------------------===//

namespace {

static bool isKnownCoeffectAlgebra(StringRef tag) {
  return tag == "linear" || tag == "affine" || tag == "semiring"
      || tag == "nat" || tag == "boolean" || tag == "lattice";
}

} // namespace

LogicalResult CoeffectPureOp::verify() {
  if (!isKnownCoeffectAlgebra(getAlgebra())) {
    return emitOpError("[TOPOS-E0536] `topos.coeffect_pure` uses "
                       "unknown coeffect algebra '")
           << getAlgebra() << "'.\n"
              "  fix: set `algebra` to one of {\"linear\", "
              "\"affine\", \"semiring\", \"nat\", \"boolean\", "
              "\"lattice\"}, matching the `coeffect_algebra` "
              "declared on the enclosing place.";
  }
  return success();
}

LogicalResult CoeffectExtractOp::verify() {
  if (!isKnownCoeffectAlgebra(getAlgebra())) {
    return emitOpError("[TOPOS-E0537] `topos.coeffect_extract` uses "
                       "unknown coeffect algebra '")
           << getAlgebra() << "'.\n"
              "  fix: set `algebra` to one of {\"linear\", "
              "\"affine\", \"semiring\", \"nat\", \"boolean\", "
              "\"lattice\"}.";
  }
  return success();
}

LogicalResult CoeffectExtendOp::verify() {
  if (!isKnownCoeffectAlgebra(getAlgebra())) {
    return emitOpError("[TOPOS-E0538] `topos.coeffect_extend` uses "
                       "unknown coeffect algebra '")
           << getAlgebra() << "'.\n"
              "  fix: set `algebra` to one of {\"linear\", "
              "\"affine\", \"semiring\", \"nat\", \"boolean\", "
              "\"lattice\"}.";
  }
  return success();
}
