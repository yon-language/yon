//===- ReductionInlining.h --------------------------------*- C++ -*-===//
//
// Pass: erases topos.with_handler whose bodies contain no topos.op_apply that
// could actually activate the handler.
//
// Strategy:
//   - if with_handler { body } has no nested op_apply -> the push/pop would be
//     useless overhead. We replace with_handler with the body itself (removing
//     the handler layer).
//   - if with_handler { body } has op_apply but the body of the referenced
//     ReduceOp is semantically empty (i.e. a default handler that does nothing)
//     -> the same.
//
// When a dialect with a structured reduce body (per-op-handler) emerges, the
// pass becomes more powerful: it will inline the handler body at the call sites
// of the corresponding op_apply.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_REDUCTION_INLINING_H
#define TOPOS_REDUCTION_INLINING_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createReductionInliningPass();
void registerReductionInliningPass();

} // namespace topos
} // namespace mlir

#endif
