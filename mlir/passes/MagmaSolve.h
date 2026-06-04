//===- MagmaSolve.h - Algebraic solver as a topos pass ---------*- C++ -*-===//
//
// Pass: categorical grafting of the algebraic solver into the topos dialect.
// A `topos.place` that instantiates a catalog algebra declares it with an
// attribute `algebra = "<Name>"` on its `topos.operation`. The place's laws are
// declared as unit attributes (`law_commutative`, `law_associative`,
// `law_monotone`).
//
// The pass implements the design decision "law = static proof obligation":
//   - VERIFIES at pass-time that `<Name>` is in the algebra catalog.
//   - VERIFIES that each law DECLARED on the place is GUARANTEED by the catalog
//     for that algebra. If the user declares `law_commutative` on an algebra the
//     catalog does not certify as commutative, the pass EMITS AN ERROR (rejects).
//     This is the `lawful` (left-exactness) check of the reduce made
//     operational: a quotient by an unguaranteed law does not pass compilation.
//
// The algebra catalog is the same table as the runtime (laws as theorems):
//   Additive, TropicalMax, TropicalMin, Multiplicative, BooleanOr, BooleanAnd, Gcd.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_MAGMA_SOLVE_H
#define TOPOS_MAGMA_SOLVE_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createMagmaSolvePass();
void registerMagmaSolvePass();

} // namespace topos
} // namespace mlir

#endif
