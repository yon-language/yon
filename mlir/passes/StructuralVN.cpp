//===- StructuralVN.cpp - structural value numbering ---------*- C++ -*-===//

#include "passes/StructuralVN.h"
#include "TopDialect.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Operation.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Support/raw_ostream.h"
#include <string>
#include <vector>

using namespace mlir;
using namespace mlir::topos;

namespace {

// Structural fingerprint of a Pure operation, a candidate for collapse.
// Two ops with the same fingerprint compute the same value: it is the
// structural structural-equivalence relation. Includes:
//   - operation name
//   - operands by SSA identity (a stable Value pointer in the module)
//   - attributes (name=value)
//   - result types
// Uses the SSA identity of the operands: two field_loads are equivalent only if
// they load from the SAME section-value, not from two sections equal by value
// but distinct as SSA (that would already be handled by PlaceFusion upstream).
static std::string computeOpFingerprint(Operation *op,
                                         DenseMap<Value, unsigned> &valueId) {
  std::string s;
  llvm::raw_string_ostream os(s);
  os << op->getName().getStringRef() << "(";
  bool first = true;
  for (Value operand : op->getOperands()) {
    if (!first) os << ",";
    first = false;
    auto it = valueId.find(operand);
    if (it != valueId.end())
      os << "v" << it->second;
    else {
      // An operand defined outside the numbered pool (e.g. a block arg already
      // seen): use the address as a stable key within the run.
      os << "p" << reinterpret_cast<uintptr_t>(operand.getAsOpaquePointer());
    }
  }
  os << ")|attrs=[";
  // Attributes in deterministic order.
  std::vector<NamedAttribute> attrs(op->getAttrs().begin(),
                                    op->getAttrs().end());
  std::sort(attrs.begin(), attrs.end(),
            [](const NamedAttribute &a, const NamedAttribute &b) {
              return a.getName().strref() < b.getName().strref();
            });
  for (auto &na : attrs) {
    os << na.getName().strref() << "=";
    na.getValue().print(os);
    os << ";";
  }
  os << "]|res=[";
  for (Type t : op->getResultTypes()) {
    t.print(os);
    os << ";";
  }
  os << "]";
  return os.str();
}

// An op is a candidate for collapse if: it has exactly one result, no region,
// and is pure. Purity is (1) the MemoryEffectFree trait, or (2) a func.call
// whose callee declares an empty effect signature (`topos.effects = []`): the
// frontend states it on the declaration of a function whose result is fixed
// by its operands and that changes nothing. A callee without it has effects.
// The pass never decides purity from a callee's name.
static bool isKnownPureCall(Operation *op) {
  auto call = llvm::dyn_cast<func::CallOp>(op);
  if (!call) return false;
  auto callee = SymbolTable::lookupNearestSymbolFrom<func::FuncOp>(
      op, call.getCalleeAttr());
  if (!callee) return false;
  auto effects = callee->getAttrOfType<ArrayAttr>("topos.effects");
  return effects && effects.empty();
}

static bool isCollapsible(Operation *op) {
  if (op->getNumResults() != 1) return false;
  if (op->getNumRegions() != 0) return false;
  if (isMemoryEffectFree(op)) return true;   // trait Pure
  if (isKnownPureCall(op)) return true;       // runtime noti-puri (whitelist)
  return false;
}

struct StructuralVNPass
    : public PassWrapper<StructuralVNPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(StructuralVNPass)

  StringRef getArgument() const final { return "structural-value-numbering"; }
  StringRef getDescription() const final {
    return "Structural value numbering — structurally-equivalent "
           "Pure ops share one computation";
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();
    unsigned collapsed = 0;

    // Process each function separately; inside, a single top-down scan per
    // block. We number the Values as we go to give a stable identity to the
    // operands (already-canonicalized results inherit the canonical's id,
    // propagating the collapse in cascade — like the forward closure of a
    // structural equivalence class).
    module.walk([&](func::FuncOp func) {
      DenseMap<Value, unsigned> valueId;
      unsigned nextId = 0;
      // Block arguments get a stable id.
      for (Block &block : func.getBody())
        for (BlockArgument arg : block.getArguments())
          valueId[arg] = nextId++;

      // Fingerprint -> canonical Value table, per block (linear dominance
      // guaranteed by the top-down scan within a block without arbitrary
      // branches; for general CFGs this stays conservative and correct: we
      // collapse only within the same block).
      for (Block &block : func.getBody()) {
        llvm::StringMap<Value> canonical;
        for (Operation &opRef : llvm::make_early_inc_range(block)) {
          Operation *op = &opRef;

          if (!isCollapsible(op)) {
            // Still number its results for future operands.
            for (Value r : op->getResults())
              if (valueId.find(r) == valueId.end()) valueId[r] = nextId++;
            continue;
          }

          std::string fp = computeOpFingerprint(op, valueId);
          auto it = canonical.find(fp);
          if (it != canonical.end()) {
            // Structurally equivalent to an op already seen: replace and erase.
            Value canon = it->second;
            op->getResult(0).replaceAllUsesWith(canon);
            // The erased result inherits the canonical id (cascade).
            op->erase();
            collapsed++;
          } else {
            Value r = op->getResult(0);
            if (valueId.find(r) == valueId.end()) valueId[r] = nextId++;
            canonical[fp] = r;
          }
        }
      }
    });

    if (collapsed > 0)
      llvm::errs() << "[structural-value-numbering] collassate " << collapsed
                   << " operazioni structurally-equivalenti\n";
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createStructuralVNPass() {
  return std::make_unique<StructuralVNPass>();
}

void registerStructuralVNPass() { PassRegistration<StructuralVNPass>(); }

} // namespace topos
} // namespace mlir
