//===- CCCEquationsCheck.cpp --------------------------*- C++ -*-===//
//
// Sanity check that the eleven Cartesian-Closed-Category equations on
// the Heyting connectives are in normal form in the current module:
//
//   1.  a AND ⊤ = a,  ⊤ AND a = a       (top neutral for AND)
//   2.  a AND ⊥ = ⊥,  ⊥ AND a = ⊥       (bot absorbing for AND)
//   3.  a OR ⊤ = ⊤,  ⊤ OR a = ⊤       (top absorbing for OR)
//   4.  a OR ⊥ = a,  ⊥ OR a = a       (bot neutral for OR)
//   5.  ⊤ -> a = a                   (top antecedent for implication)
//   6.  a -> ⊤ = ⊤                   (top consequent for implication)
//   7.  ⊥ -> a = ⊤                   (ex falso)
//   8.  NOT⊤ = ⊥
//   9.  NOT⊥ = ⊤
//  10.  a AND a = a,  a OR a = a       (idempotence)
//  11.  a AND NOTa = ⊥                  (contradiction)
//
// If any of these patterns appears in the IR un-normalised after the
// canonicalisation pass `HeytingShortCircuit` has been applied, this
// pass reports a verifier-style diagnostic. It is intended to be run
// after `HeytingShortCircuit` as part of CI.
//
// This pass never modifies the IR; it only emits diagnostics.
//
//===----------------------------------------------------------------------===//

#include "TopDialect.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

// Returns the HeytingValue carried by the operation if `v` is the
// result of a `topos.heyt` constant; otherwise returns std::nullopt.
static std::optional<HeytingValue> matchHeytConst(Value v) {
  if (auto h = v.getDefiningOp<HeytOp>())
    return h.getValue();
  return std::nullopt;
}

// Returns true if `lhs` and `rhs` are syntactically the same SSA value
// (same defining op or same block argument). Used for idempotence and
// contradiction checks (a AND a, a OR a, a AND NOTa).
static bool sameValue(Value lhs, Value rhs) { return lhs == rhs; }

// Returns true if `nf` is the result of `topos.heyt_not` applied to
// the same value as `v`.
static bool isNegationOf(Value v, Value nf) {
  if (auto n = nf.getDefiningOp<HeytNotOp>())
    return n.getOperand() == v;
  return false;
}

struct CCCEquationsCheckPass
    : public PassWrapper<CCCEquationsCheckPass, OperationPass<ModuleOp>> {

  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(CCCEquationsCheckPass)

  StringRef getArgument() const override { return "ccc-equations-check"; }
  StringRef getDescription() const override {
    return "Sanity check that the 11 CCC equations on Heyting "
           "connectives have been normalised (run after "
           "heyt-short-circuit).";
  }

  void runOnOperation() override {
    ModuleOp mod = getOperation();
    bool anyFailure = false;

    mod.walk([&](Operation *op) {
      if (auto a = dyn_cast<HeytAndOp>(op)) {
        Value l = a.getLhs(), r = a.getRhs();
        auto lc = matchHeytConst(l);
        auto rc = matchHeytConst(r);
        // Eq 1, 2: top/bot operand should have been folded.
        if (lc == HeytingValue::True || rc == HeytingValue::True
            || lc == HeytingValue::False || rc == HeytingValue::False) {
          a.emitOpError(
              "[TOPOS-E0451] `topos.heyt_and` has a literal "
              "True/False operand that should have been folded "
              "(equations 1-2 of the CCC normal form for AND).\n"
              "  fix: run the `heyt-short-circuit` pass before "
              "`ccc-equations-check`.\n"
              "  context: top is a neutral element and bot is "
              "absorbing for AND, so any AND with a constant "
              "operand admits a strictly simpler form.");
          anyFailure = true;
        }
        // Eq 10: idempotence a AND a = a.
        if (sameValue(l, r)) {
          a.emitOpError(
              "[TOPOS-E0452] `topos.heyt_and` of a value with "
              "itself should have been folded by idempotence "
              "(equation 10 of the CCC normal form).\n"
              "  fix: run the `heyt-short-circuit` pass before "
              "`ccc-equations-check`.");
          anyFailure = true;
        }
        // Eq 11: a AND NOTa = ⊥ (and the symmetric case).
        if (isNegationOf(l, r) || isNegationOf(r, l)) {
          a.emitOpError(
              "[TOPOS-E0453] `topos.heyt_and` of a value with "
              "its negation should have been folded to False "
              "(equation 11, contradiction).\n"
              "  fix: run the `heyt-short-circuit` pass before "
              "`ccc-equations-check`.");
          anyFailure = true;
        }
      } else if (auto o = dyn_cast<HeytOrOp>(op)) {
        Value l = o.getLhs(), r = o.getRhs();
        auto lc = matchHeytConst(l);
        auto rc = matchHeytConst(r);
        // Eq 3, 4: top/bot operand should have been folded.
        if (lc == HeytingValue::True || rc == HeytingValue::True
            || lc == HeytingValue::False || rc == HeytingValue::False) {
          o.emitOpError(
              "[TOPOS-E0454] `topos.heyt_or` has a literal "
              "True/False operand that should have been folded "
              "(equations 3-4 of the CCC normal form for OR).\n"
              "  fix: run the `heyt-short-circuit` pass before "
              "`ccc-equations-check`.");
          anyFailure = true;
        }
        // Eq 10: idempotence a OR a = a.
        if (sameValue(l, r)) {
          o.emitOpError(
              "[TOPOS-E0455] `topos.heyt_or` of a value with "
              "itself should have been folded by idempotence "
              "(equation 10).\n"
              "  fix: run the `heyt-short-circuit` pass before "
              "`ccc-equations-check`.");
          anyFailure = true;
        }
      } else if (auto i = dyn_cast<HeytImpliesOp>(op)) {
        Value l = i.getLhs(), r = i.getRhs();
        auto lc = matchHeytConst(l);
        auto rc = matchHeytConst(r);
        // Eq 5: ⊤ -> a = a.  Eq 6: a -> ⊤ = ⊤.  Eq 7: ⊥ -> a = ⊤.
        if (lc == HeytingValue::True || lc == HeytingValue::False
            || rc == HeytingValue::True) {
          i.emitOpError(
              "[TOPOS-E0456] `topos.heyt_implies` has a literal "
              "True/False at a position where equations 5-7 of "
              "the CCC normal form admit a simpler form.\n"
              "  fix: run the `heyt-short-circuit` pass before "
              "`ccc-equations-check`.");
          anyFailure = true;
        }
      } else if (auto n = dyn_cast<HeytNotOp>(op)) {
        auto vc = matchHeytConst(n.getOperand());
        // Eq 8: NOT⊤ = ⊥.  Eq 9: NOT⊥ = ⊤.
        if (vc == HeytingValue::True || vc == HeytingValue::False) {
          n.emitOpError(
              "[TOPOS-E0457] `topos.heyt_not` of a literal "
              "True/False should have been folded to the "
              "opposite constant (equations 8-9 of the CCC "
              "normal form).\n"
              "  fix: run the `heyt-short-circuit` pass before "
              "`ccc-equations-check`.");
          anyFailure = true;
        }
      }
    });

    if (anyFailure)
      signalPassFailure();
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createCCCEquationsCheckPass() {
  return std::make_unique<CCCEquationsCheckPass>();
}

void registerCCCEquationsCheckPass() {
  PassRegistration<CCCEquationsCheckPass>();
}

} // namespace topos
} // namespace mlir
