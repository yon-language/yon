//===- StructuralPasses.h - Batch C -----------------------------*- C++ -*-===//
//
// Declares 9 analysis passes that perform structural/categorical
// well-formedness checks beyond what TableGen verifiers can express.
//
// These passes do not modify the IR; they only emit diagnostics.
// Each pass implements one structural check:
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

std::unique_ptr<Pass> createTypePreservationPass();          // #18a
std::unique_ptr<Pass> createProgressPass();                  // #18b
std::unique_ptr<Pass> createTypeEquivSanityPass();           // #18c
std::unique_ptr<Pass> createHMInferencePass();               // #18f
std::unique_ptr<Pass> createGiraudCheckPass();               // #27a
std::unique_ptr<Pass> createSimpson6Pass();                  // #27b
std::unique_ptr<Pass> createAccessibilityPass();             // #27c
std::unique_ptr<Pass> createLocalisationDecompPass();        // #27f
std::unique_ptr<Pass> createInternalLanguageConsistencyPass(); // #27p
std::unique_ptr<Pass> createAlphaRenamePass();               // #52f

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
