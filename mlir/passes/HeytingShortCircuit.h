//===- HeytingShortCircuit.h ------------------------------*- C++ -*-===//
//
// Canonicalization pass for the tri-valued Heyting operations of the Topos
// dialect. Applies standard algebraic identities:
//
//   AND(x, x)       -> x        (idempotence)
//   OR(x, x)        -> x        (idempotence)
//   AND(x, T)       -> x        (AND identity, T = true)
//   OR(x, F)        -> x        (OR identity, F = false)
//   NOT(NOT(x))     -> x        (double negation)
//   AND(x, F)       -> F        (annihilator F)
//   OR(x, T)        -> T        (annihilator T)
//   AND(F, x)       -> F        (symmetric annihilator F)
//   OR(T, x)        -> T        (symmetric annihilator T)
//   AND(c1, c2)     -> fold     (both constant)
//   OR(c1, c2)      -> fold     (both constant)
//   NOT(c)          -> fold     (single constant)
//
// Note: operates on the Topos dialect, before the lowering. The dialect ops are
// Pure, so the rewrite is safe. The pass is idempotent.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_HEYTING_SHORT_CIRCUIT_H
#define TOPOS_HEYTING_SHORT_CIRCUIT_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createHeytingShortCircuitPass();
void registerHeytingShortCircuitPass();

} // namespace topos
} // namespace mlir

#endif
