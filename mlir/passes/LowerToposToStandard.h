//===- LowerToposToStandard.h - Topos -> standard MLIR ------*- C++ -*-===//
//
// Main lowering pass from the Topos dialect to the standard MLIR dialects
// (func, scf, memref, arith, cf, llvm). See the header of
// LowerToposToStandard.cpp for the type mapping and the list of patterns.
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
