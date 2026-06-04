//===- CCCEquationsCheck.h --------------------------------*- C++ -*-===//
#ifndef TOPOS_PASSES_CCCEQUATIONSCHECK_H
#define TOPOS_PASSES_CCCEQUATIONSCHECK_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createCCCEquationsCheckPass();
void registerCCCEquationsCheckPass();

} // namespace topos
} // namespace mlir

#endif
