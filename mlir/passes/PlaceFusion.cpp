//===- PlaceFusion.cpp --------------------------------*- C++ -*-===//

#include "passes/PlaceFusion.h"
#include "TopDialect.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Support/raw_ostream.h"
#include <algorithm>
#include <string>

using namespace mlir;
using namespace mlir::topos;

namespace {

// Computes a structural fingerprint of a PlaceOp. Two places with the same
// fingerprint are fusion-equivalent. The fingerprint includes:
//   - world parent (the same world is required)
//   - field sequence: name|type
//   - operation sequence: name|arg_types|result_type
//   - cell sequence: name|dimension
//   - with_effects flag
// Does NOT include:
//   - sym_name (it is what we want to unify)
//   - over (slice category): if present, fingerprint = unique to avoid fusion
//     (we preserve the categorical structure)
static std::string computeFingerprint(PlaceOp place) {
  // If it has `over`, the fingerprint is unique (we never fuse).
  if (place.getOver().has_value()) {
    std::string s;
    llvm::raw_string_ostream os(s);
    os << "UNIQUE:over@" << place.getSymName();
    return s;
  }

  std::string fp;
  llvm::raw_string_ostream os(fp);

  os << "world=" << place.getWorld().str() << "|";
  os << "effects=" << (place.getWithEffects() ? "1" : "0") << "|";

  // Fields in declaration order (the order matters for the layout).
  os << "fields=[";
  bool first = true;
  for (Operation &nested : place.getBody().front()) {
    if (auto f = llvm::dyn_cast<FieldOp>(&nested)) {
      if (!first) os << ",";
      first = false;
      os << f.getSymName() << ":";
      f.getFieldType().print(os);
    }
  }
  os << "]|";

  // Operations in order.
  os << "ops=[";
  first = true;
  for (Operation &nested : place.getBody().front()) {
    if (auto o = llvm::dyn_cast<OperationOp>(&nested)) {
      if (!first) os << ",";
      first = false;
      os << o.getSymName() << ":(";
      bool firstArg = true;
      for (Attribute argTy : o.getArgTypes()) {
        if (!firstArg) os << ",";
        firstArg = false;
        if (auto tyAttr = llvm::dyn_cast<TypeAttr>(argTy)) {
          tyAttr.getValue().print(os);
        }
      }
      os << ")->";
      o.getResultType().print(os);
    }
  }
  os << "]|";

  // Cells in order.
  os << "cells=[";
  first = true;
  for (Operation &nested : place.getBody().front()) {
    if (auto c = llvm::dyn_cast<CellOp>(&nested)) {
      if (!first) os << ",";
      first = false;
      os << c.getSymName() << ":" << c.getDimension();
    }
  }
  os << "]";

  return fp;
}

// Replaces a SectionType pointing to `oldName` with one that points to
// `newName`. Returns the new type or nullptr if it is not a SectionType of
// `oldName`.
static Type rewriteSectionType(Type t, StringRef oldName, StringRef newName) {
  if (auto st = llvm::dyn_cast<SectionType>(t)) {
    if (st.getPlaceName() == oldName) {
      return SectionType::get(t.getContext(), newName);
    }
  }
  return t;
}

// Riscrive una funzione: types di operand SSA, types dei block args,
// types of the function signatures.
static void rewriteOperationsRefs(ModuleOp module,
                                  const llvm::StringMap<std::string> &renames) {
  MLIRContext *ctx = module.getContext();

  module.walk([&](Operation *op) {
    // (1) Rewrite SectionType nei result types.
    for (Value result : op->getResults()) {
      Type t = result.getType();
      for (auto &kv : renames) {
        Type newT = rewriteSectionType(t, kv.first(), kv.second);
        if (newT != t) {
          result.setType(newT);
          t = newT;
        }
      }
    }
    // (2) Rewrite SectionType in the block arg types (useful for the func.func
    //     signature: the entry block's block args have the same types as the
    //     inputs).
    for (Region &region : op->getRegions()) {
      for (Block &block : region) {
        for (BlockArgument arg : block.getArguments()) {
          Type t = arg.getType();
          for (auto &kv : renames) {
            Type newT = rewriteSectionType(t, kv.first(), kv.second);
            if (newT != t) {
              arg.setType(newT);
              t = newT;
            }
          }
        }
      }
    }
    // (3) Rewrite SymbolRefAttr wherever it appears as an attribute, name-by-name
    //     comuni: op_ref (OpApplyOp), source_place/target_place (MoveOp),
    //     of_place (ReduceOp, TopologyOp). Iteriamo gli attributi.
    SmallVector<NamedAttribute, 4> newAttrs;
    bool changed = false;
    for (NamedAttribute na : op->getAttrs()) {
      Attribute val = na.getValue();
      if (auto symRef = llvm::dyn_cast<FlatSymbolRefAttr>(val)) {
        auto it = renames.find(symRef.getValue());
        if (it != renames.end()) {
          newAttrs.push_back(
              NamedAttribute(na.getName(),
                             FlatSymbolRefAttr::get(ctx, it->second)));
          changed = true;
          continue;
        }
      }
      newAttrs.push_back(na);
    }
    if (changed) {
      op->setAttrs(newAttrs);
    }
  });

  // (4) func.func signature: i FunctionType rewrite vanno fatti via
  //     setFunctionType perché il type lives in un attributo separato.
  module.walk([&](func::FuncOp f) {
    FunctionType ft = f.getFunctionType();
    SmallVector<Type, 4> newIns;
    SmallVector<Type, 4> newOuts;
    bool changed = false;
    for (Type t : ft.getInputs()) {
      Type rewritten = t;
      for (auto &kv : renames) {
        rewritten = rewriteSectionType(rewritten, kv.first(), kv.second);
      }
      newIns.push_back(rewritten);
      if (rewritten != t) changed = true;
    }
    for (Type t : ft.getResults()) {
      Type rewritten = t;
      for (auto &kv : renames) {
        rewritten = rewriteSectionType(rewritten, kv.first(), kv.second);
      }
      newOuts.push_back(rewritten);
      if (rewritten != t) changed = true;
    }
    if (changed) {
      f.setFunctionType(FunctionType::get(ctx, newIns, newOuts));
    }
  });
}

struct PlaceFusionPass
    : public PassWrapper<PlaceFusionPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(PlaceFusionPass)

  StringRef getArgument() const final { return "place-fusion"; }
  StringRef getDescription() const final {
    return "Fuse structurally equivalent topos.place in the same world";
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();

    // Step 1: collect all PlaceOps with their fingerprint.
    struct Entry { PlaceOp op; std::string fp; };
    SmallVector<Entry, 8> places;
    module.walk([&](PlaceOp p) {
      places.push_back({p, computeFingerprint(p)});
    });

    if (places.size() < 2) return;

    // Step 2: raggruppa per fingerprint. Mappa fp -> vector di place names.
    llvm::StringMap<SmallVector<PlaceOp, 2>> groups;
    for (auto &e : places) {
      groups[e.fp].push_back(e.op);
    }

    // Step 3: for each group with >= 2 places, choose the canonical one (the
    // lexicographically smaller sym_name) and prepare the renames.
    llvm::StringMap<std::string> renames;
    SmallVector<PlaceOp, 4> toErase;
    for (auto &kv : groups) {
      auto &group = kv.second;
      if (group.size() < 2) continue;
      // Skippa i fingerprint UNIQUE (place con over).
      if (kv.first().starts_with("UNIQUE:")) continue;

      // Ordina per sym_name.
      std::sort(group.begin(), group.end(), [](PlaceOp a, PlaceOp b) {
        return a.getSymName() < b.getSymName();
      });
      PlaceOp canonical = group[0];
      StringRef canonicalName = canonical.getSymName();
      for (size_t i = 1; i < group.size(); ++i) {
        PlaceOp dup = group[i];
        renames[dup.getSymName()] = canonicalName.str();
        toErase.push_back(dup);
      }
    }

    if (renames.empty()) return;

    // Step 4: apply the rewrites to the module.
    rewriteOperationsRefs(module, renames);

    // Step 5: erase le PlaceOp duplicate.
    for (PlaceOp p : toErase) {
      p->erase();
    }
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createPlaceFusionPass() {
  return std::make_unique<PlaceFusionPass>();
}

void registerPlaceFusionPass() {
  PassRegistration<PlaceFusionPass>();
}

} // namespace topos
} // namespace mlir
