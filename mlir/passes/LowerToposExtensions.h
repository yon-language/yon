//===- LowerToposExtensions.h - extended Topos -> standard lowering ---*- C++ -*-===//
//
// Extension pass for `LowerToposToStandard.cpp`. Lowers the operations
// that the original pass leaves at the Topos level, in five families:
//
//   F1 — Heyting completion: HeytImplies -> arith truth table.
//   F2 — Yoneda probe ops: ProbeConstruct / ProbeApply / ProbeCollapse
//        -> memref-backed structural lowering.
//   F3 — Reduction extras: ComposeReductions -> func.func composition.
//   F4 — Sheaf ops: Restrict / Glue -> memref + select.
//   F5 — 20 new ops introduced for the verifier layer.
//        Most of them are erased at lowering time (they carry no
//        runtime semantics; the verifier has already done its job).
//        A few (LoadWorld, CoeffectPure/Extract/Extend) emit runtime
//        function calls.
//
// The pass is intended to run AFTER `LowerToposToStandard`, so that
// the orchestrator can compose them in pipeline order.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_PASSES_LOWER_TOPOS_EXTENSIONS_H
#define TOPOS_PASSES_LOWER_TOPOS_EXTENSIONS_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createLowerToposExtensionsPass();
void registerLowerToposExtensionsPass();

} // namespace topos
} // namespace mlir

#endif // TOPOS_PASSES_LOWER_TOPOS_EXTENSIONS_H
