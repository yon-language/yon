//===- LowerToposToLLVM.h - Standard MLIR -> LLVM dialect ---*- C++ -*-===//
//
// Final lowering from the mix of dialects produced by the
// --lower-topos-to-standard pass to pure LLVM dialect.
//
// Expected input:
//   arith.*, cf.*, scf.*, func.*, memref.*
//   llvm.struct<(i32, i32)>     (HeapRef already LLVM)
//   llvm.{undef, insertvalue, extractvalue}
//   func.func private declarations of the XLeech2 runtime:
//     @yon_current_heap, @yon_current_heap_id, @yon_get_heap_by_id,
//     @yon_hexheap_alloc, @yon_hexheap_get_payload,
//     @yon_space_request_alloc, @yon_probe_dispatch, ...
//
// Output:
//   LLVM dialect only, ready for `mlir-translate --mlir-to-llvmir` and the
//   subsequent `llc`.
//
// Strategy: use the standard MLIR conversion patterns
// (populateFuncToLLVMConversionPatterns, populateMemRefToLLVMConversionPatterns,
// populateSCFToControlFlowConversionPatterns, etc.) with a unified
// LLVMTypeConverter. No Topos-specific patterns are written: the output of the
// previous pass is already made only of standard dialect ops that have official
// conversion patterns.
//
// The canonical end-to-end pipeline is now:
//   --lower-topos-extensions
//   --lower-topos-to-standard
//   --lower-topos-to-llvm
// dopo cui si invoca:
//   mlir-translate --mlir-to-llvmir input.mlir > output.ll
//   llc output.ll
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_LOWER_TO_LLVM_H
#define TOPOS_LOWER_TO_LLVM_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

// Builds the Standard -> LLVM dialect lowering pass.
std::unique_ptr<Pass> createLowerToposToLLVMPass();

// Registers the pass in the global PassRegistry under the name
// --lower-topos-to-llvm. To be called in topos-opt::main().
void registerLowerToposToLLVMPass();

} // namespace topos
} // namespace mlir

#endif // TOPOS_LOWER_TO_LLVM_H
