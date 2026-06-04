//===- topos-opt.cpp - Standalone mlir-opt driver for Topos -*- C++ -*-===//
//
// An executable equivalent to mlir-opt but with the Topos dialect
// pre-registered. Lets you parse/print/validate .mlir files that use Topos
// dialect operations.
//
// Uso:
//   topos-opt input.mlir                  # parse + print
//   topos-opt input.mlir -verify-each     # verify pass
//
//===----------------------------------------------------------------------===//

#include "TopDialect.h"
#include "passes/CCCEquationsCheck.h"
#include "passes/CoherenceElimination.h"
#include "passes/CPSConversion.h"
#include "passes/HeytingShortCircuit.h"
#include "passes/LowerToposExtensions.h"
#include "passes/LowerToposToLLVM.h"
#include "passes/LowerToposToStandard.h"
#include "passes/MoveComposition.h"
#include "passes/PlaceFusion.h"
#include "passes/MagmaSolve.h"
#include "passes/ClusterCollapse.h"
#include "passes/ReductionInlining.h"
#include "passes/StructuralPasses.h"
#include "passes/WorldSpecialization.h"
#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVMPass.h"
#include "mlir/Conversion/MemRefToLLVM/MemRefToLLVM.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"
#include "mlir/Conversion/SCFToControlFlow/SCFToControlFlow.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/DialectRegistry.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Pass/PassRegistry.h"
#include "mlir/Transforms/Passes.h"
#include "mlir/Tools/mlir-opt/MlirOptMain.h"

int main(int argc, char **argv) {
  // Pass standard MLIR (canonicalize, cse).
  mlir::registerCanonicalizerPass();
  mlir::registerCSEPass();

  // Upstream MLIR conversion passes (lowering toward the LLVM dialect).
  // We register via PassRegistration using the create* factories.
  mlir::PassPipelineRegistration<>(
      "convert-scf-to-cf", "Convert SCF dialect to ControlFlow dialect",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::createConvertSCFToCFPass());
      });
  mlir::PassPipelineRegistration<>(
      "convert-arith-to-llvm", "Convert Arith dialect to LLVM dialect",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::createArithToLLVMConversionPass());
      });
  mlir::PassPipelineRegistration<>(
      "convert-cf-to-llvm", "Convert ControlFlow dialect to LLVM dialect",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::createConvertControlFlowToLLVMPass());
      });
  mlir::PassPipelineRegistration<>(
      "convert-func-to-llvm", "Convert Func dialect to LLVM dialect",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::createConvertFuncToLLVMPass());
      });
  mlir::PassPipelineRegistration<>(
      "finalize-memref-to-llvm",
      "Convert MemRef dialect to LLVM dialect (finalize stage)",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::createFinalizeMemRefToLLVMConversionPass());
      });
  mlir::PassPipelineRegistration<>(
      "reconcile-unrealized-casts",
      "Eliminate unrealized_conversion_cast inserted during conversion",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::createReconcileUnrealizedCastsPass());
      });

  // Composite pipeline: --lower-to-llvm = scf->cf, arith->llvm, cf->llvm,
  // memref->llvm, func->llvm, reconcile-unrealized-casts. Applied in canonical
  // order.
  mlir::PassPipelineRegistration<>(
      "lower-to-llvm",
      "Full lowering pipeline: standard MLIR -> LLVM dialect",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::createConvertSCFToCFPass());
        pm.addPass(mlir::createArithToLLVMConversionPass());
        pm.addPass(mlir::createConvertControlFlowToLLVMPass());
        pm.addPass(mlir::createFinalizeMemRefToLLVMConversionPass());
        pm.addPass(mlir::createConvertFuncToLLVMPass());
        pm.addPass(mlir::createReconcileUnrealizedCastsPass());
      });

  // Custom Topos passes.
  mlir::topos::registerLowerToposToStandardPass();
  mlir::topos::registerLowerToposExtensionsPass();
  mlir::topos::registerLowerToposToLLVMPass();
  mlir::topos::registerHeytingShortCircuitPass();
  mlir::topos::registerCoherenceEliminationPass();
  mlir::topos::registerReductionInliningPass();
  mlir::topos::registerWorldSpecializationPass();
  mlir::topos::registerMagmaSolvePass();
  mlir::topos::registerMoveCompositionPass();
  mlir::topos::registerCPSConversionPass();
  mlir::topos::registerPlaceFusionPass();
  mlir::topos::registerClusterCollapsePass();
  mlir::topos::registerCCCEquationsCheckPass();

  // Batch C: 10 structural / analysis passes that implement the verifier
  // items.
  mlir::topos::registerTypePreservationPass();
  mlir::topos::registerProgressPass();
  mlir::topos::registerTypeEquivSanityPass();
  mlir::topos::registerHMInferencePass();
  mlir::topos::registerGiraudCheckPass();
  mlir::topos::registerSimpson6Pass();
  mlir::topos::registerAccessibilityPass();
  mlir::topos::registerLocalisationDecompPass();
  mlir::topos::registerInternalLanguageConsistencyPass();
  mlir::topos::registerAlphaRenamePass();

  // Pipeline completa Yon -> LLVM dialect: lower-topos-to-standard +
  // lower-to-llvm. Applicabile via --yon-to-llvm in single shot.
  mlir::PassPipelineRegistration<>(
      "yon-to-llvm",
      "Full Yon compilation pipeline: Topos -> standard MLIR -> LLVM dialect",
      [](mlir::OpPassManager &pm) {
        pm.addPass(mlir::topos::createLowerToposToStandardPass());
        pm.addPass(mlir::createConvertSCFToCFPass());
        pm.addPass(mlir::createArithToLLVMConversionPass());
        pm.addPass(mlir::createConvertControlFlowToLLVMPass());
        pm.addPass(mlir::createFinalizeMemRefToLLVMConversionPass());
        pm.addPass(mlir::createConvertFuncToLLVMPass());
        pm.addPass(mlir::createReconcileUnrealizedCastsPass());
      });

  mlir::DialectRegistry registry;
  registry.insert<mlir::topos::ToposDialect,
                  mlir::arith::ArithDialect,
                  mlir::cf::ControlFlowDialect,
                  mlir::func::FuncDialect,
                  mlir::LLVM::LLVMDialect,
                  mlir::memref::MemRefDialect,
                  mlir::scf::SCFDialect>();

  return mlir::asMainReturnCode(
      mlir::MlirOptMain(argc, argv, "Topos dialect optimizer\n", registry));
}
