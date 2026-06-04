//===- LowerToposToLLVM.cpp - Standard MLIR -> LLVM dialect -*- C++ -*-===//
//
// Final lowering from the mix of dialects produced by the
// --lower-topos-to-standard pass to pure LLVM dialect.
//
// Expected input:
//   - arith.*, cf.*, scf.*, func.*, memref.* (scratch buffers and
//     view/load/store for staging the payload before the XLeech2 runtime
//     calls)
//   - llvm.struct<(i32, i32)>, llvm.{undef, insertvalue, extractvalue}
//     (HeapRef already LLVM-typed)
//   - func.func private declarations of the XLeech2 runtime (real ABI;
//     the per-Space C arena family was RETIRED with the 81b resolution
//     of 2026-06-03 — allocation goes through yon_rt_new and friends):
//       @yon_handler_push   : () -> ()                          (M4 placeholder)
//       @yon_handler_pop    : () -> ()                          (M4 placeholder)
//       @yon_handler_lookup : (i64) -> !llvm.ptr
//   - func.func @<Place>__<op>(i32 xcoord, args...) -> result
//   - func.func @<Move>__move(i32) -> i32
//   - func.func @<Place>__<op>__trampoline(memref<?xi8>, i32, arg) -> result
//
// Output: solo LLVM dialect, pronto per `mlir-translate --mlir-to-llvmir`.
//
// Strategy: use the standard MLIR conversion patterns. No Topos-specific
// patterns in this pass — the Topos dialect no longer exists in the input
// because the previous pass already fully lowered it. It is only a matter of
// bringing the mix of intermediate dialects to uniform LLVM.
//
// Conversion targets:
//   - scf      -> cf       (via populateSCFToControlFlowConversionPatterns)
//   - cf       -> llvm     (via populateControlFlowToLLVMConversionPatterns)
//   - cf.assert -> llvm    (via populateAssertToLLVMConversionPattern)
//   - arith    -> llvm     (via populateArithToLLVMConversionPatterns)
//   - memref   -> llvm     (via populateFinalizeMemRefToLLVMConversionPatterns)
//   - func     -> llvm     (via populateFuncToLLVMConversionPatterns)
//
// The order does not matter for the single applyFullConversion: the driver
// resolves the dependencies. What matters is that ALL patterns are registered
// before the apply, because memref->llvm creates cf ops
// which in turn get lowered to llvm, and similar chains.
//
//===----------------------------------------------------------------------===//

#include "passes/LowerToposToLLVM.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/MemRefToLLVM/MemRefToLLVM.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/BuiltinDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassRegistry.h"
#include "mlir/Transforms/DialectConversion.h"

namespace mlir {
namespace topos {

namespace {

//===----------------------------------------------------------------------===//
// Pass driver
//===----------------------------------------------------------------------===//

struct LowerToposToLLVMPass
    : public PassWrapper<LowerToposToLLVMPass, OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(LowerToposToLLVMPass)

  StringRef getArgument() const override { return "lower-topos-to-llvm"; }
  StringRef getDescription() const override {
    return "Final lowering to pure LLVM dialect after Topos lowering "
           "(closes the MLIR pipeline before mlir-translate/llc).";
  }

  void getDependentDialects(DialectRegistry &registry) const override {
    // Source dialects (input).
    registry.insert<arith::ArithDialect,
                    cf::ControlFlowDialect,
                    func::FuncDialect,
                    memref::MemRefDialect,
                    scf::SCFDialect>();
    // Target dialect.
    registry.insert<LLVM::LLVMDialect>();
  }

  void runOnOperation() override {
    auto module = getOperation();
    auto *ctx = &getContext();

    // Step 1 — SCF -> CF (scf.if/for/while -> cf.cond_br + blocks).
    // We do this BEFORE the main LLVM conversion because cf ->
    // llvm conversion can handle the cf produced by SCF lowering,
    // but the LLVM conversion cannot directly handle scf ops.
    {
      RewritePatternSet scfPatterns(ctx);
      populateSCFToControlFlowConversionPatterns(scfPatterns);
      ConversionTarget scfTarget(*ctx);
      scfTarget.addLegalDialect<arith::ArithDialect,
                                 cf::ControlFlowDialect,
                                 func::FuncDialect,
                                 LLVM::LLVMDialect,
                                 memref::MemRefDialect>();
      scfTarget.addIllegalDialect<scf::SCFDialect>();
      if (failed(applyPartialConversion(module, scfTarget,
                                         std::move(scfPatterns)))) {
        module.emitError(
            "[TOPOS-E1201] SCF -> CF lowering failed; cannot complete "
            "the LLVM pipeline.");
        signalPassFailure();
        return;
      }
    }

    // Step 2 — Everything else -> LLVM. We use a single
    // applyFullConversion with all relevant populate-* registered
    // and a single LLVMTypeConverter so that struct, memref, and
    // function signatures are converted consistently.
    // Step 3: useBarePtrCallConv = false (default).
    // It is no longer necessary to force bare-ptr because the runtime
    // signatures are already pure !llvm.ptr in the Topos->Standard lowering.
    // The MemRef descriptor unpacking still concerns only the user functions
    // that use memref in their own signatures, not the XLeech2 runtimes.
    LowerToLLVMOptions options(ctx);

    LLVMTypeConverter typeConverter(ctx, options);

    RewritePatternSet patterns(ctx);

    // Order in which we add populates is not semantically important;
    // applyFullConversion's driver resolves cross-dialect
    // dependencies. Order below is by "logical layer" for
    // readability only.
    mlir::arith::populateArithToLLVMConversionPatterns(typeConverter,
                                                        patterns);
    populateMemRefToLLVMConversionPatternsLocal(typeConverter, patterns);
    mlir::cf::populateControlFlowToLLVMConversionPatterns(typeConverter,
                                                           patterns);
    mlir::cf::populateAssertToLLVMConversionPattern(typeConverter,
                                                     patterns);
    populateFuncToLLVMConversionPatterns(typeConverter, patterns);

    LLVMConversionTarget llvmTarget(*ctx);
    llvmTarget.addLegalOp<ModuleOp>();
    // BuiltinDialect ops like UnrealizedConversionCast that MAY
    // appear as ABI bridges between partially-converted regions
    // are explicitly legal.
    llvmTarget.addLegalOp<UnrealizedConversionCastOp>();

    if (failed(applyFullConversion(module, llvmTarget,
                                    std::move(patterns)))) {
      module.emitError(
          "[TOPOS-E1202] Final lowering to LLVM dialect failed. "
          "Likely cause: an op in the module is not handled by any "
          "of the standard populate-*ToLLVM conversion pattern sets "
          "(arith, cf, memref, func, builtin).");
      signalPassFailure();
      return;
    }
  }

private:
  // Wrapper to handle the renaming of MemRefToLLVM populate. In
  // MLIR-20 the canonical name is
  // `populateFinalizeMemRefToLLVMConversionPatterns`.
  static void populateMemRefToLLVMConversionPatternsLocal(
      LLVMTypeConverter &converter, RewritePatternSet &patterns) {
    populateFinalizeMemRefToLLVMConversionPatterns(converter, patterns);
  }
};

} // namespace

//===----------------------------------------------------------------------===//
// Factory + registration
//===----------------------------------------------------------------------===//

std::unique_ptr<Pass> createLowerToposToLLVMPass() {
  return std::make_unique<LowerToposToLLVMPass>();
}

void registerLowerToposToLLVMPass() {
  PassRegistration<LowerToposToLLVMPass>();
}

} // namespace topos
} // namespace mlir
