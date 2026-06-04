//===- ClusterCollapse.cpp - structural value numbering ---------*- C++ -*-===//

#include "passes/ClusterCollapse.h"
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
// structural cluster-equivalence relation. Includes:
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
// and is pure. Purity is (1) the MemoryEffectFree trait, or (2) a func.call to
// a runtime in the "known-pure" whitelist — Yon's content-addressed loaders,
// which are referentially transparent (same SSA input => same output) even
// though MLIR treats func.call as potentially having effects.
static bool isKnownPureCall(Operation *op) {
  auto call = llvm::dyn_cast<func::CallOp>(op);
  if (!call) return false;
  StringRef callee = call.getCallee();
  // Referentially-transparent runtimes: the value depends only on the SSA
  // operands. field_load from a section, list head/tail, merkle equal, hsh
  // contains/levels: all deterministic and with no observable side effect.
  static const char *pureRuntimes[] = {
      "yon_rt_field_load", "yon_rt_list_head",  "yon_rt_list_tail",
      "yon_rt_list_length", "yon_rt_merkle_equal", "yon_rt_merkle_label",
      "yon_rt_merkle_child", "yon_rt_hsh_contains", "yon_rt_hsh_levels",
      "yon_rt_hashset_contains", "yon_rt_hashset_size", "yon_rt_map_get",
      "to_prop", "to_bool", "to_bool_dec"};
  for (const char *p : pureRuntimes)
    if (callee == p) return true;
  return false;
}

static bool isCollapsible(Operation *op) {
  if (op->getNumResults() != 1) return false;
  if (op->getNumRegions() != 0) return false;
  if (isMemoryEffectFree(op)) return true;   // trait Pure
  if (isKnownPureCall(op)) return true;       // runtime noti-puri (whitelist)
  return false;
}

struct ClusterCollapsePass
    : public PassWrapper<ClusterCollapsePass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(ClusterCollapsePass)

  StringRef getArgument() const final { return "cluster-collapse"; }
  StringRef getDescription() const final {
    return "Structural value numbering — cluster-equivalent "
           "Pure ops share one computation";
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();
    unsigned collapsed = 0;

    // Process each function separately; inside, a single top-down scan per
    // block. We number the Values as we go to give a stable identity to the
    // operands (already-canonicalized results inherit the canonical's id,
    // propagating the collapse in cascade — like the forward closure of a
    // cluster).
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
            // Cluster-equivalent to an op already seen: replace and erase.
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
      llvm::errs() << "[cluster-collapse] collassate " << collapsed
                   << " operazioni cluster-equivalenti\n";
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createClusterCollapsePass() {
  return std::make_unique<ClusterCollapsePass>();
}

void registerClusterCollapsePass() { PassRegistration<ClusterCollapsePass>(); }

} // namespace topos
} // namespace mlir
