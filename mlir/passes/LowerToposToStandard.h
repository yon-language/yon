//===- LowerToposToStandard.h - Topos -> standard MLIR ------*- C++ -*-===//
//
// Main lowering pass from the Topos dialect to the standard MLIR dialects
// (func, scf, memref, arith, cf). The fixed architectural decisions are:
// section = contiguous struct, reduce/handler = runtime dispatch table,
// scope/arena = explicit + static verifier.
//
// Lowering implementato in milestone successive:
//   M1: topos.field, topos.path, topos.coherence -> erase (evidenze di tipo)
//       topos.heyt -> arith.constant
//       topos.heyt_and/or/not/implies -> arith ops
//   M2: topos.section -> memref.alloca + memref.store
//       topos.operation -> func.func
//       topos.op_apply -> func.call (con handler lookup)
//   M3: topos.move -> func.func
//       topos.apply_move -> func.call
//   M4: topos.scope -> func.func IsolatedFromAbove + arena param
//       topos.with_handler -> yon_handler_push + scf.execute_region + pop
//
// Attualmente: M1 implementato.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_LOWER_TO_STANDARD_H
#define TOPOS_LOWER_TO_STANDARD_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

// Builds the Topos -> standard dialects lowering pass.
std::unique_ptr<Pass> createLowerToposToStandardPass();

// Registers the pass in the global PassRegistry under the name
// --lower-topos-to-standard. To be called in topos-opt::main().
void registerLowerToposToStandardPass();

} // namespace topos
} // namespace mlir

#endif // TOPOS_LOWER_TO_STANDARD_H
