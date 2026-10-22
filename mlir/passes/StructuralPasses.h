//===- StructuralPasses.h - Opt-in diagnostic passes ------------*- C++ -*-===//
//
// Declares 10 opt-in diagnostic passes. None of them is in the yonc
// pipeline; they run only when named on the topos-opt command line.
//
// These passes do not modify the IR; they only emit diagnostics.
// Each pass checks one syntactic proxy, described at the pass in
// StructuralPasses.cpp. The names below are the pass names, not a claim
// that the named property is decided:
//
//   type-preservation       (--topos-type-preservation)
//   progress                (--topos-progress)
//   type-equivalence sanity (--topos-type-equiv-sanity)
//   Hindley-Milner inference (--topos-hm-inference)
//   Giraud-axiom check       (--topos-giraud-check)
//   Simpson 6-equivalences   (--topos-simpson6)
//   accessibility check      (--topos-accessibility)
//   localisation decomp.     (--topos-localisation-decomp)
//   internal-language consist (--topos-internal-lang)
//   alpha-rename pre-typecheck (--topos-alpha-rename)
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_PASSES_STRUCTURAL_PASSES_H
#define TOPOS_PASSES_STRUCTURAL_PASSES_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createTypePreservationPass();
std::unique_ptr<Pass> createProgressPass();
std::unique_ptr<Pass> createTypeEquivSanityPass();
std::unique_ptr<Pass> createHMInferencePass();
std::unique_ptr<Pass> createGiraudCheckPass();
std::unique_ptr<Pass> createSimpson6Pass();
std::unique_ptr<Pass> createAccessibilityPass();
std::unique_ptr<Pass> createLocalisationDecompPass();
std::unique_ptr<Pass> createInternalLanguageConsistencyPass();
std::unique_ptr<Pass> createAlphaRenamePass();

void registerTypePreservationPass();
void registerProgressPass();
void registerTypeEquivSanityPass();
void registerHMInferencePass();
void registerGiraudCheckPass();
void registerSimpson6Pass();
void registerAccessibilityPass();
void registerLocalisationDecompPass();
void registerInternalLanguageConsistencyPass();
void registerAlphaRenamePass();

} // namespace topos
} // namespace mlir

#endif // TOPOS_PASSES_STRUCTURAL_PASSES_H
