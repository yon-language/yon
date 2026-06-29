//===- LowerToposExtensions.cpp - extended Topos lowering -------*- C++ -*-===//
//
// Lowers operations not handled by `LowerToposToStandard`, organised
// in five families. See LowerToposExtensions.h for the scope of each.
//
// Design constraints lifted from sintesi.md:
//
//   - The XLeech2 runtime is GC-free: blocks are pre-allocated in MPHF
//     tables; no `malloc`/`gc_alloc` is to be emitted by this lowering.
//     Stack alloca (`memref.alloca`) is fine; cross-Space pieces emit
//     runtime calls that resolve through MPHF, not through heap.
//
//   - The pipeline Topos -> MLIR Standard corresponds to "type/effect
//     reconstruction + CPS + closure conversion" of the Tortoise
//     architecture (Turbak ch. 17).
//
//   - Per Turbak ch. 12.3, polymorphism is erased at compile time
//     (type-erasure). Purely declarative ops are dropped here; ops with
//     runtime semantics emit runtime calls.
//
// Family classification of the 20 verifier-layer ops:
//
//   ERASE (no runtime semantics, only verifier-time information):
//     pabs, pabs_bounded     — polymorphism, erased after type checking
//     dep_proposition         — proof-relevant declaration
//     or_intro, exists_intro  — constructive proof introductions
//     sharing_constraint      — SML-style sharing (type-checker only)
//     class, instance         — type classes; TODO: lower to dict-passing
//     from_site, canonical_site, cech_nerve, kripke_joyal_forcing,
//     canonical_subplace      — topos-theoretic declarations
//     split_fibration, place_dependent, invert
//                             — categorical declarations
//
//   IDENTITY-COERCE (runtime-identity, replace with operand):
//     the, dselect            — subtype and module-projection coercions
//
//   RUNTIME CALL (emit a func.call into the XLeech2 runtime):
//     load_world              — yon_load_world(path) -> world handle
//     coeffect_pure           — yon_coeffect_pure(value)
//     coeffect_extract        — yon_coeffect_extract(coeffected)
//     coeffect_extend         — yon_coeffect_extend(coeffected, fn)
//
// Families 1-4 (HeytImplies / Yoneda probes / ComposeReductions /
// Restrict+Glue) are pure structural lowerings; see each section.
// This file implements F2 (Yoneda probes), F3 (ComposeReductions),
// and the F5 layer; F1 (HeytImplies) lives in LowerToposToStandard
// and F4 (Restrict+Glue) is not lowered here.
//
//===----------------------------------------------------------------------===//

#include "passes/LowerToposExtensions.h"
#include "TopDialect.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"
#include "mlir/Transforms/GreedyPatternRewriteDriver.h"
#include "llvm/ADT/Hashing.h"
#include "llvm/ADT/StringRef.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

//===----------------------------------------------------------------------===//
// Shared helpers
//===----------------------------------------------------------------------===//

// Heyting tri-value encoding shared with `LowerToposToStandard.cpp`:
//   0 -> True, 1 -> False, 2 -> Unknown, stored in i8.
static Value heytConst(ConversionPatternRewriter &rewriter, Location loc,
                       uint8_t v) {
  auto i8 = rewriter.getIntegerType(8);
  return rewriter.create<arith::ConstantOp>(
      loc, i8, rewriter.getIntegerAttr(i8, v));
}

// Looks up (or declares) a private runtime function with the given
// name and type at the top of the module. Used by ops that lower to
// runtime calls (load_world, coeffect_*).
static func::FuncOp ensureRuntimeFunc(ModuleOp mod, StringRef name,
                                      FunctionType type) {
  if (auto existing =
          dyn_cast_or_null<func::FuncOp>(mod.lookupSymbol(name))) {
    return existing;
  }
  OpBuilder builder(mod.getContext());
  builder.setInsertionPointToStart(mod.getBody());
  auto fn = builder.create<func::FuncOp>(mod.getLoc(), name, type);
  fn.setPrivate();
  return fn;
}

//===----------------------------------------------------------------------===//
// Family 1 — Heyting completion.
//
// `HeytImpliesOp` lowering lives in `LowerToposToStandard.cpp`,
// alongside the existing `LowerHeytAndOp` / `LowerHeytOrOp` /
// `LowerHeytNotOp` patterns, so it shares the same `TypeConverter`
// that maps `!topos.proposition` to `i8`. This file no longer
// contains a pattern for it.
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Family 3 — Reduction composition: `topos.compose_reductions` becomes
// a concrete `func.func` whose body chains the two component
// reductions in the standard mathematical convention
//
//     (left o right)(x) = left(right(x))
//
// matching the TableGen comment `@result = @left . @right`.
//
// Implementation: a direct walk over the module rather than an
// `OpRewritePattern`. Reason: `topos.compose_reductions` carries the
// `Pure` trait and has no SSA results, which makes the MLIR
// `GreedyPatternRewriter` eliminate it as dead code before any
// pattern can match. Using a plain walk side-steps the dead-code
// elimination heuristic and keeps the lowering deterministic.
//
// The function fails with a precise diagnostic when either operand
// cannot be resolved to an already-materialised `func.func`
// (typically because `MaterializeReduceOp` has not yet run, or
// because the user listed a name that is not a `topos.reduce` in
// the module).
//===----------------------------------------------------------------------===//

static LogicalResult lowerComposeReductions(ModuleOp module) {
  // Collect every compose_reductions first, then process. We do not
  // want to mutate the body while walking it.
  SmallVector<ComposeReductionsOp> composes;
  module.walk([&](ComposeReductionsOp c) { composes.push_back(c); });

  for (ComposeReductionsOp op : composes) {
    OpBuilder builder(op.getContext());

    auto resolve = [&](StringRef name) -> func::FuncOp {
      std::string mangled = (name + "__reduce").str();
      return dyn_cast_or_null<func::FuncOp>(
          module.lookupSymbol(mangled));
    };

    func::FuncOp leftFn = resolve(op.getLeft());
    if (!leftFn) {
      op.emitOpError(
          "[TOPOS-E0801] compose_reductions '")
          << op.getSymName()
          << "' references left reduction '" << op.getLeft()
          << "', but no `func.func @" << op.getLeft()
          << "__reduce` has been materialised in the module.\n"
             "  fix: ensure `--lower-topos-to-standard` runs before "
             "`--lower-topos-extensions`, and check that '"
          << op.getLeft() << "' is the name of an actual "
                             "`topos.reduce` declaration.";
      return failure();
    }
    func::FuncOp rightFn = resolve(op.getRight());
    if (!rightFn) {
      op.emitOpError(
          "[TOPOS-E0802] compose_reductions '")
          << op.getSymName()
          << "' references right reduction '" << op.getRight()
          << "', but no `func.func @" << op.getRight()
          << "__reduce` has been materialised in the module.\n"
             "  fix: same as for the left operand.";
      return failure();
    }

    // The composition `(left o right)` is well-typed iff:
    //   right :  A... -> B   (right may take multiple inputs)
    //   left  :  B -> C
    FunctionType leftType = leftFn.getFunctionType();
    FunctionType rightType = rightFn.getFunctionType();
    // Composition `left o right`: `right` MAY take multiple inputs (they
    // become the composition's inputs); it must produce exactly ONE result,
    // which `left` consumes. `left` must be unary (one input = right's
    // result; one output = the composition's result).
    if (leftType.getNumInputs() != 1 || leftType.getNumResults() != 1
        || rightType.getNumResults() != 1) {
      op.emitOpError(
          "[TOPOS-E0803] compose_reductions '")
          << op.getSymName()
          << "': in `left o right`, `left` must be unary (one input, one "
             "result) and `right` must produce exactly one result (which "
             "`left` consumes). `right` may take multiple inputs.\n"
             "  fix: ensure `left` is a unary `topos.reduce`, and `right` "
             "produces a single result.";
      return failure();
    }
    if (leftType.getInput(0) != rightType.getResult(0)) {
      op.emitOpError(
          "[TOPOS-E0804] compose_reductions '")
          << op.getSymName()
          << "': type mismatch in the chain. The result type of "
             "`right` (" << rightType.getResult(0)
          << ") does not equal the input type of `left` ("
          << leftType.getInput(0) << ").\n"
             "  fix: make sure both component reductions operate on "
             "places whose section layouts agree at the composition "
             "boundary.";
      return failure();
    }

    std::string composedName = (op.getSymName() + "__reduce").str();

    // Guard: do not overwrite an existing symbol.
    if (module.lookupSymbol(composedName)) {
      op.emitOpError(
          "[TOPOS-E0805] compose_reductions '")
          << op.getSymName()
          << "': a `func.func @" << composedName
          << "` already exists in the module.\n"
             "  fix: choose a distinct `sym_name` for this "
             "composition.";
      return failure();
    }

    // The composition takes ALL of right's inputs and returns left's result.
    auto composedType = builder.getFunctionType(
        rightType.getInputs(), {leftType.getResult(0)});

    builder.setInsertionPointToEnd(module.getBody());
    auto fn = builder.create<func::FuncOp>(op.getLoc(), composedName,
                                           composedType);

    // The composition inherits the `lawful` and `coeffect_preserving`
    // attributes from BOTH components: left-exactness and coeffect
    // preservation are closed under categorical composition.
    if (leftFn->hasAttr("topos.reduction.lawful")
        && rightFn->hasAttr("topos.reduction.lawful"))
      fn->setAttr("topos.reduction.lawful", builder.getUnitAttr());
    if (leftFn->hasAttr("topos.reduction.coeffect_preserving")
        && rightFn->hasAttr("topos.reduction.coeffect_preserving"))
      fn->setAttr("topos.reduction.coeffect_preserving",
                  builder.getUnitAttr());

    Block *entry = fn.addEntryBlock();
    builder.setInsertionPointToStart(entry);
    // Forward ALL composition arguments to `right` (it may be multi-input);
    // `right`'s single result feeds the unary `left`.
    SmallVector<Value> rightArgs;
    for (Value a : entry->getArguments()) rightArgs.push_back(a);
    auto callRight = builder.create<func::CallOp>(
        op.getLoc(), rightFn, rightArgs);
    auto callLeft = builder.create<func::CallOp>(
        op.getLoc(), leftFn, callRight.getResults());
    builder.create<func::ReturnOp>(op.getLoc(),
                                   callLeft.getResults());

    op.erase();
  }

  return success();
}

//===----------------------------------------------------------------------===//
// Family 2 — Yoneda probes.
//
// A Yoneda probe is, at the source level:
//
//   %p = topos.probe_construct "op_name" on %instance
//        : (!topos.section<P>) -> !topos.probe<src -> dst>
//   %r = topos.probe_apply %p(%arg)
//        : (!topos.probe<src -> dst>, src) -> dst
//
// The probe is semantically a closure `(code_ptr, captured_instance)`.
// To express a closure in the Standard MLIR layer one needs either a
// `tuple` type (limited dialect support) or a `memref<2 x ptr>` with
// explicit function-pointer manipulation (only possible in the LLVM
// dialect). Both options bypass the natural representation.
//
// We adopt instead a peephole strategy that closes the probe into a
// direct `topos.op_apply` whenever the probe is constructed and
// applied within the same function. This is sound because, for the
// patterns that arise from Yon source code, the probe lifetime is
// always local (Tortoise stages 7-8, "CPS conversion + closure
// conversion", are scheduled as a follow-up; until then, escaping
// probes are rejected with a diagnostic that tells the user exactly
// what is missing).
//
// `probe_collapse %instance` is defined in the dialect as the
// devirtualisation directive that the runtime representation of
// `%instance` is already flat. After F2 has fused every local
// `probe_construct` + `probe_apply` pair, `probe_collapse` is
// redundant on its operand; we replace it with the operand. This is
// the runtime identity the dialect documentation explicitly states.
//
// The transformations live inline in the pass driver (a direct walk).
// See the runOnOperation step 1.
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Family 5a — Erase compile-time-only declarations.
//
// These ops carry information consumed entirely by the verifier layer
// (purity, sharing, class membership, topos-theoretic structure, ...)
// and have no runtime semantics. Once verification has succeeded they
// are removed.
//
// NOTE on `class`/`instance`: a future dictionary-passing pass should
// rewrite uses of class operations to receive an explicit dictionary
// argument. Until that pass exists, we erase here; downstream consumers
// of class operations will fail loudly via the ConversionTarget.
//===----------------------------------------------------------------------===//

template <typename Op>
struct EraseOp : public OpConversionPattern<Op> {
  using OpConversionPattern<Op>::OpConversionPattern;
  LogicalResult matchAndRewrite(
      Op op, typename OpConversionPattern<Op>::OpAdaptor /*adaptor*/,
      ConversionPatternRewriter &rewriter) const override {
    rewriter.eraseOp(op);
    return success();
  }
};

//===----------------------------------------------------------------------===//
// Family 5b — Identity coercions (Turbak 11.3, 15.4).
//
// `topos.the T E` and `topos.dselect θ E` are runtime-identity:
// at the compile-time layer they record information for the type
// checker, but at runtime they just yield their operand unchanged.
//===----------------------------------------------------------------------===//

template <typename Op>
struct IdentityCoerceOp : public OpConversionPattern<Op> {
  using OpConversionPattern<Op>::OpConversionPattern;
  LogicalResult matchAndRewrite(
      Op op, typename OpConversionPattern<Op>::OpAdaptor adaptor,
      ConversionPatternRewriter &rewriter) const override {
    rewriter.replaceOp(op, adaptor.getOperands()[0]);
    return success();
  }
};

//===----------------------------------------------------------------------===//
// Family 5c — Runtime calls (no heap allocation; MPHF-resolved).
//
// `load_world` resolves a serialized world by file path; the runtime
// returns a handle (an i64 token in the lowered form). The path is
// encoded as a deterministic hash so the runtime can resolve it
// through its MPHF index without heap allocation.
//
// `coeffect_pure / extract / extend` are the comonad operations
// (Petricek-Orchard 2014 §4): `pure` boxes a value at the unit grade;
// `extract` unboxes at the unit grade; `extend` composes a coeffected
// value with a continuation, producing a coeffected result at the
// composite grade. In the runtime they are emitted as calls to small
// trampolines; the grade composition is delegated to a downstream
// indexed-comonad analysis pass.
//===----------------------------------------------------------------------===//

struct LoadWorldLowering : public OpConversionPattern<LoadWorldOp> {
  using OpConversionPattern<LoadWorldOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(LoadWorldOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto mod = op->getParentOfType<ModuleOp>();
    if (!mod)
      return failure();

    auto i64 = rewriter.getIntegerType(64);

    // Encode the path string as an i64 hash (stable, deterministic).
    // The runtime side will resolve the hash through its MPHF index.
    StringRef path = op.getPath();
    uint64_t hash = (uint64_t)llvm::hash_value(path);
    Value pathHash = rewriter.create<arith::ConstantOp>(
        loc, i64, rewriter.getIntegerAttr(i64, (int64_t)hash));

    auto fnType = rewriter.getFunctionType({i64}, {i64});
    auto fn = ensureRuntimeFunc(mod, "yon_load_world", fnType);

    auto call = rewriter.create<func::CallOp>(
        loc, fn, ValueRange{pathHash});
    rewriter.replaceOp(op, call.getResults());
    return success();
  }
};

struct CoeffectPureLowering
    : public OpConversionPattern<CoeffectPureOp> {
  using OpConversionPattern<CoeffectPureOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(CoeffectPureOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto mod = op->getParentOfType<ModuleOp>();
    if (!mod) return failure();

    Value v = adaptor.getValue();
    Type t = v.getType();

    auto fnType = rewriter.getFunctionType({t}, {t});
    auto fn = ensureRuntimeFunc(mod, "yon_coeffect_pure", fnType);
    auto call = rewriter.create<func::CallOp>(loc, fn, ValueRange{v});
    rewriter.replaceOp(op, call.getResults());
    return success();
  }
};

struct CoeffectExtractLowering
    : public OpConversionPattern<CoeffectExtractOp> {
  using OpConversionPattern<CoeffectExtractOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(CoeffectExtractOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto mod = op->getParentOfType<ModuleOp>();
    if (!mod) return failure();

    Value c = adaptor.getCoeffected();
    Type srcT = c.getType();
    Type dstT = op.getValue().getType();

    auto fnType = rewriter.getFunctionType({srcT}, {dstT});
    auto fn = ensureRuntimeFunc(mod, "yon_coeffect_extract", fnType);
    auto call = rewriter.create<func::CallOp>(loc, fn, ValueRange{c});
    rewriter.replaceOp(op, call.getResults());
    return success();
  }
};

struct CoeffectExtendLowering
    : public OpConversionPattern<CoeffectExtendOp> {
  using OpConversionPattern<CoeffectExtendOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(CoeffectExtendOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto mod = op->getParentOfType<ModuleOp>();
    if (!mod) return failure();

    Value c = adaptor.getCoeffected();
    Value k = adaptor.getContinuation();
    Type cT = c.getType();
    Type kT = k.getType();
    Type rT = op.getResult().getType();

    auto fnType = rewriter.getFunctionType({cT, kT}, {rT});
    auto fn = ensureRuntimeFunc(mod, "yon_coeffect_extend", fnType);
    auto call = rewriter.create<func::CallOp>(loc, fn,
                                              ValueRange{c, k});
    rewriter.replaceOp(op, call.getResults());
    return success();
  }
};

// `topos.promote %value to @target_space` is the explicit promotion
// of an inhabitant from the current Space to an outer Space with
// strictly larger lifetime.
//
// The value being promoted is an xcoord (the local HexHeap slot in the source
// Space). The runtime call
// `yon_space_request_alloc(target_space_id, src_heap_id, src_xcoord)`
// performs the cross-Space copy via the target Space's mailbox:
// the source Space serialises the payload and dispatches a
// YON_MSG_ALLOC message; the target Space receives it, runs its
// own yon_hexheap_alloc on the local arena, and replies with the
// new xcoord. The reply slot is read back synchronously.
//
// The result type at the dialect level is still `!topos.section<P>`
// (xcoord). The HeapRef wrapping happens implicitly when the
// surface compiler decides to make the cross-Space-ness explicit
// in the type system (deferred to a future dialect extension).
//
// The target_space name is hashed at compile time; the runtime
// resolves the hash through its MPHF index of registered Spaces.
struct PromoteLowering : public OpConversionPattern<PromoteOp> {
  using OpConversionPattern<PromoteOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(PromoteOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto mod = op->getParentOfType<ModuleOp>();
    if (!mod) return failure();

    Value v = adaptor.getValue();
    Type vT = v.getType();
    // Use the dialect-level result type directly. The subsequent
    // --lower-topos-to-standard pass will convert any leftover
    // !topos.section in the runtime call signature.
    Type rT = op.getResult().getType();

    auto i64 = rewriter.getIntegerType(64);
    StringRef target = op.getTargetSpace();
    uint64_t hash = (uint64_t)llvm::hash_value(target);
    Value targetHash = rewriter.create<arith::ConstantOp>(
        loc, i64, rewriter.getIntegerAttr(i64, (int64_t)hash));

    // Signature: yon_space_request_alloc(target_space_id, value) -> result.
    // The runtime extracts the source heap+xcoord from `value` and
    // dispatches a YON_MSG_ALLOC to the target Space; the reply
    // yields the new xcoord/HeapRef in the target Space's heap.
    auto fnType = rewriter.getFunctionType({i64, vT}, {rT});
    auto fn = ensureRuntimeFunc(mod, "yon_space_request_alloc", fnType);

    auto call = rewriter.create<func::CallOp>(
        loc, fn, ValueRange{targetHash, v});
    rewriter.replaceOp(op, call.getResults());
    return success();
  }
};

//===----------------------------------------------------------------------===//
// Pass driver
//===----------------------------------------------------------------------===//

struct LowerToposExtensionsPass
    : public PassWrapper<LowerToposExtensionsPass,
                         OperationPass<ModuleOp>> {

  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(LowerToposExtensionsPass)

  StringRef getArgument() const override {
    return "lower-topos-extensions";
  }
  StringRef getDescription() const override {
    return "Lower the remaining Topos ops not covered by "
           "lower-topos-to-standard. This delivery covers Yoneda "
           "probes (F2: local probe fusion + collapse identity), "
           "reduction composition (F3: compose_reductions -> "
           "func.func chaining the two component reductions), "
           "and the verifier-layer ops (F5: erase + identity coerce + "
           "runtime calls). GC-free: no heap allocation; "
           "cross-Space pieces become MPHF-resolved runtime calls. "
           "Heyting implies (F1) and reduce materialisation live "
           "in lower-topos-to-standard.";
  }
  void getDependentDialects(DialectRegistry &registry) const override {
    registry.insert<arith::ArithDialect, func::FuncDialect,
                    memref::MemRefDialect>();
  }

  void runOnOperation() override {
    auto *ctx = &getContext();
    (void)ctx;
    auto module = getOperation();

    // ----------------------------------------------------------------
    // Step 1: F2 — fuse local probe pairs (direct walk).
    //
    // We use a direct walk rather than `applyPatternsGreedily`
    // because the greedy driver performs unconditional dead-code
    // elimination on pure ops with no SSA uses before any pattern
    // can match. That heuristic would silently delete
    // `topos.compose_reductions` (Pure, no result) and the
    // `topos.probe_construct` results once the apply they feed
    // disappears. A walk-based rewrite is the right primitive for
    // both F2 and F3 here.
    //
    // The transformation matches each (probe_construct, probe_apply)
    // pair and replaces it with a single `topos.op_apply`.
    //
    // Reachability note (2026-06): the canonical frontend (emit_mlir)
    // does NOT emit `topos.probe_construct`; this fusion is dialect-
    // level support exercised only by hand-written MLIR. A
    // `probe_construct` whose uses are not all `probe_apply` is an
    // escaping probe: it is LEFT in place here (no E0701 check exists —
    // closure conversion / F2b is RETIRED with the arena model). If one
    // ever survived, the `addIllegalOp<ProbeConstructOp, ProbeApplyOp>`
    // guard in LowerToposToStandard fails the conversion. We do not
    // fail here.
    // ----------------------------------------------------------------
    {
      // Iterate over every `topos.probe_construct`. For each one,
      // every use must be a `topos.probe_apply`. We synthesise a
      // `topos.op_apply` per use (no longer requiring a single
      // use: multi-use probes are perfectly fine, since a probe
      // is a referential function — applying it N times is N
      // independent calls), then erase the construct.
      //
      // A use that is not a `probe_apply` indicates an escaping
      // probe (the probe is stored, returned, or passed to a
      // function that accepts a `!topos.probe`); such a construct is
      // left in place (see reachability note above) and, if it ever
      // reaches LowerToposToStandard, is caught by the illegal-op guard
      // there. No stranded-probe diagnostic is emitted in this pass.
      SmallVector<ProbeConstructOp> constructs;
      module.walk([&](ProbeConstructOp c) { constructs.push_back(c); });

      for (ProbeConstructOp construct : constructs) {
        // Snapshot the uses before we start mutating the IR.
        SmallVector<ProbeApplyOp> usesAsApply;
        bool hasNonApplyUse = false;
        for (Operation *user : construct.getResult().getUsers()) {
          if (auto apply = dyn_cast<ProbeApplyOp>(user))
            usesAsApply.push_back(apply);
          else
            hasNonApplyUse = true;
        }

        // If any use is not a probe_apply, the probe escapes;
        // leave the construct in place (the illegal-op guard in
        // LowerToposToStandard fails the conversion if it survives).
        if (hasNonApplyUse)
          continue;

        // Synthesise a topos.op_apply per use.
        for (ProbeApplyOp apply : usesAsApply) {
          OpBuilder builder(apply);
          SmallVector<Value, 1> args{apply.getStage()};
          auto opApply = builder.create<OpApplyOp>(
              apply.getLoc(),
              apply.getResult().getType(),
              construct.getMemberName(),
              construct.getInstance(),
              ValueRange(args));
          apply.getResult().replaceAllUsesWith(opApply.getResult());
          apply.erase();
        }
        construct.erase();
      }

      // Note: a `topos.probe_apply` that consumes a probe NOT
      // produced by a local `topos.probe_construct` (e.g. a block
      // argument) is not an error at this stage; it is left in place.
      // F2b (closure conversion + runtime dispatcher) is RETIRED with
      // the arena model, so there is no downstream rewrite into
      // `@yon_probe_dispatch`. Such an apply, if it ever appeared,
      // would be rejected by the illegal-op guard in
      // LowerToposToStandard. The canonical frontend never produces it.

      // probe_collapse %instance is the devirtualisation directive
      // that the instance is already flat. After F2 has fused the
      // probes, this op is the identity on its operand.
      SmallVector<ProbeCollapseOp> collapses;
      module.walk([&](ProbeCollapseOp c) { collapses.push_back(c); });
      for (ProbeCollapseOp c : collapses) {
        c.getResult().replaceAllUsesWith(c.getInstance());
        c.erase();
      }
    }

    // Note: a `topos.probe_construct` that escapes its function (its
    // uses are not all `topos.probe_apply`) is left in place. F2b
    // (closure conversion / trampoline) is RETIRED; the illegal-op
    // guard in LowerToposToStandard catches any survivor. The canonical
    // frontend never emits probe_construct, so this never fires.

    // ----------------------------------------------------------------
    // Step 2: F3 — lower `topos.compose_reductions` to chained
    // `func.func` declarations.
    // ----------------------------------------------------------------
    if (failed(lowerComposeReductions(module))) {
      signalPassFailure();
      return;
    }

    // ----------------------------------------------------------------
    // Step 2b: 81b — inline hermetic scopes (structural, pre-conversion).
    //
    // The arena model is RETIRED (resolution 2026-06-03): the formal
    // content of topos.scope / topos.scope_with_yield lives entirely in
    // the verifier (IsolatedFromAbove forces every outer dependency
    // through an explicit capture), which has already accepted the
    // module by the time this pass runs. The lowering is therefore a
    // pure inline: substitute captures for block arguments, splice the
    // body, and for scope_with_yield forward the yielded values as the
    // op's results — the pushforward (\iota_S)_* is the identity.
    //
    // Done here as a direct walk (NOT in the dialect conversion of
    // LowerToposToStandard): inlining is purely structural, and doing
    // it before any type conversion avoids dangling-materialization
    // issues when a yielded value has a dialect type (e.g. a
    // proposition) whose defining op is converted later.
    //
    // module.walk is post-order, so nested scopes inline before their
    // parents.
    // ----------------------------------------------------------------
    {
      SmallVector<Operation *, 8> scopeOps;
      module.walk([&](Operation *op) {
        if (isa<ScopeOp, ScopeWithYieldOp>(op))
          scopeOps.push_back(op);
      });
      for (Operation *raw : scopeOps) {
        Block *dest = raw->getBlock();
        Region *bodyRegion = &raw->getRegion(0);
        Block &src = bodyRegion->front();

        // Captures -> block arguments substitution.
        ValueRange captures =
            isa<ScopeOp>(raw) ? cast<ScopeOp>(raw).getCaptures()
                              : cast<ScopeWithYieldOp>(raw).getCaptures();
        for (auto pair : llvm::zip(src.getArguments(), captures))
          std::get<0>(pair).replaceAllUsesWith(std::get<1>(pair));

        // For scope_with_yield: detach the terminator and remember the
        // yielded values, to become the op's replacement results.
        SmallVector<Value, 4> yielded;
        if (auto swy = dyn_cast<ScopeWithYieldOp>(raw)) {
          Operation *term = src.getTerminator();
          auto yieldOp = dyn_cast_or_null<ScopeYieldOp>(term);
          if (!yieldOp) {
            raw->emitError("[TOPOS-E1104] topos.scope_with_yield body "
                           "must end with topos.scope_yield");
            signalPassFailure();
            return;
          }
          yielded.append(yieldOp.getValues().begin(),
                         yieldOp.getValues().end());
          term->erase();
        }

        // Splice the body ops right before the scope op, then retire it.
        dest->getOperations().splice(Block::iterator(raw),
                                     src.getOperations());
        if (!yielded.empty())
          raw->replaceAllUsesWith(yielded);
        raw->erase();
      }
    }

    // ----------------------------------------------------------------
    // Step 3: F5 — erase compile-time-only ops, identity-coerce ops,
    // emit runtime calls. Run as a dialect conversion so the legality
    // target catches anything we missed.
    // ----------------------------------------------------------------
    ConversionTarget target(*ctx);
    target.addLegalDialect<arith::ArithDialect, func::FuncDialect,
                           memref::MemRefDialect>();
    target.addLegalOp<ModuleOp>();

    // Family 5a — erase (no runtime semantics).
    target.addIllegalOp<
        PabsOp, PabsBoundedOp, DepPropositionOp,
        SharingConstraintOp, ClassOp, InstanceOp,
        FromSiteOp, CanonicalSiteOp, CechNerveOp,
        KripkeJoyalForcingOp, CanonicalSubplaceOp,
        SplitFibrationOp, PlaceDependentOp, InvertOp,
        OrIntroOp, ExistsIntroOp>();

    // Family 5b — identity coerce.
    target.addIllegalOp<TheOp, DselectOp>();

    // Family 5c — runtime calls.
    target.addIllegalOp<LoadWorldOp, CoeffectPureOp,
                        CoeffectExtractOp, CoeffectExtendOp,
                        PromoteOp>();

    RewritePatternSet patterns(ctx);

    // F1 lives in LowerToposToStandard.cpp.
    // F2 and F3 have been applied above (steps 1 and 2).

    // F5a — erase
    patterns.add<EraseOp<PabsOp>>(ctx);
    patterns.add<EraseOp<PabsBoundedOp>>(ctx);
    patterns.add<EraseOp<DepPropositionOp>>(ctx);
    patterns.add<EraseOp<SharingConstraintOp>>(ctx);
    patterns.add<EraseOp<ClassOp>>(ctx);
    patterns.add<EraseOp<InstanceOp>>(ctx);
    patterns.add<EraseOp<FromSiteOp>>(ctx);
    patterns.add<EraseOp<CanonicalSiteOp>>(ctx);
    patterns.add<EraseOp<CechNerveOp>>(ctx);
    patterns.add<EraseOp<KripkeJoyalForcingOp>>(ctx);
    patterns.add<EraseOp<CanonicalSubplaceOp>>(ctx);
    patterns.add<EraseOp<SplitFibrationOp>>(ctx);
    patterns.add<EraseOp<PlaceDependentOp>>(ctx);
    patterns.add<EraseOp<InvertOp>>(ctx);
    patterns.add<EraseOp<OrIntroOp>>(ctx);
    patterns.add<EraseOp<ExistsIntroOp>>(ctx);

    // F5b — identity coerce
    patterns.add<IdentityCoerceOp<TheOp>>(ctx);
    patterns.add<IdentityCoerceOp<DselectOp>>(ctx);

    // F5c — runtime calls
    patterns.add<LoadWorldLowering>(ctx);
    patterns.add<CoeffectPureLowering>(ctx);
    patterns.add<CoeffectExtractLowering>(ctx);
    patterns.add<CoeffectExtendLowering>(ctx);
    patterns.add<PromoteLowering>(ctx);

    if (failed(applyPartialConversion(module, target,
                                      std::move(patterns)))) {
      signalPassFailure();
    }
  }
};

} // namespace

//===----------------------------------------------------------------------===//
// Factory + registration
//===----------------------------------------------------------------------===//

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createLowerToposExtensionsPass() {
  return std::make_unique<LowerToposExtensionsPass>();
}

void registerLowerToposExtensionsPass() {
  PassRegistration<LowerToposExtensionsPass>();
}

} // namespace topos
} // namespace mlir
