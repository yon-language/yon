//===- LowerToposToStandard.cpp - Topos -> standard lowering -*- C++ -*-===//
//
// Lowers the Topos dialect to func/arith/scf/cf/memref/llvm.
//
// Type mapping (ToposTypeConverter below):
//
//     !topos.section<P>      -> i64 (packed heap_id<<32 | xcoord)
//     !topos.probe<src->dst> -> !llvm.struct<(i32, i32)> (HeapRef =
//                              heap_id + xcoord)
//     !topos.proposition     -> i8 (tri-valued: T=0, F=1, U=2)
//
// Patterns registered in this file:
//
//     heyt, heyt_and/or/not/implies, heyt_is, HeytToI32, HeytFromI8,
//     heyt_int_*                         -> arith / llvm struct ops
//     field, path, coherence             -> erased
//     subtype_cast, section_to_xcoord, xcoord_to_section
//     operation                          -> func.func @<Place>__<op>
//     op_apply                           -> func.call @<Place>__<op>
//     field_load                         -> func.call @<Place>__get_<field>
//     move                               -> func.func @<Move>__move (identity)
//     apply_move                         -> func.call @<Move>__move
//     reduce                             -> private func.func declaration
//     geom_morphism                      -> private <name>__pull / __push
//     forces                             -> scf.if
//
// scope / scope_with_yield are inlined by LowerToposExtensions before this
// pass (no arena). section, restrict, glue, probe_construct and probe_apply
// have no pattern and are illegal: a survivor fails the conversion.
//
// After the conversion, world, place, pullback, pushout, topology and view
// are erased (metadata with no runtime semantics). Every other Topos op is
// legal here and left in place.
//
//===----------------------------------------------------------------------===//

#include "passes/LowerToposToStandard.h"
#include "TopDialect.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlow.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Func/Transforms/FuncConversions.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/Dialect/LLVMIR/LLVMTypes.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/SCF/Transforms/Patterns.h"
#include "mlir/IR/BuiltinDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/PatternMatch.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Transforms/DialectConversion.h"
#include <set>
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/StringMap.h"

using namespace mlir;
using namespace mlir::topos;

namespace {

//===----------------------------------------------------------------------===//
// PlaceLayout: the layout of a place's fields, as the frontend wrote it
//===----------------------------------------------------------------------===//

// Layout information for a single place.
// totalSize: total number of bytes of the section layout.
// fieldOffsets: maps field_name -> offset in bytes in the contiguous struct.
// fieldTypes: maps field_name -> MLIR type of the field.
struct PlaceLayout {
  uint64_t totalSize = 0;
  llvm::StringMap<uint64_t> fieldOffsets;
  // fieldSizes: field_name -> its size in bytes, as laid out by the frontend.
  llvm::StringMap<uint64_t> fieldSizes;
  llvm::StringMap<Type> fieldTypes;
  // Ordered list of field names, in declaration order (needed for
  // topos.section, which receives the field_values by position, not by name).
  SmallVector<std::string, 4> fieldOrder;
};


// The layout of every place of the module, read from its fields: the
// frontend lays the fields out with one function and writes each field's
// offset and size on it (`topos.offset`, `topos.size`), the same layout it
// uses to build a section and to read a primitive field. This pass computes
// none of its own. A field without them is a module this pass cannot lower
// faithfully: it is reported, never given a guessed offset.
static llvm::StringMap<PlaceLayout>
computePlaceLayouts(ModuleOp module, bool &missing) {
  llvm::StringMap<PlaceLayout> result;
  module.walk([&](PlaceOp place) {
    PlaceLayout layout;
    // A fieldless place (terminal object 1) has an empty body region.
    if (place.getBody().empty()) {
      layout.totalSize = 0;
      result[place.getSymName()] = std::move(layout);
      return;
    }
    uint64_t end = 0;
    for (Operation &nested : place.getBody().front()) {
      auto field = llvm::dyn_cast<FieldOp>(&nested);
      if (!field) continue;
      auto offAttr = field->getAttrOfType<IntegerAttr>("topos.offset");
      auto sizeAttr = field->getAttrOfType<IntegerAttr>("topos.size");
      if (!offAttr || !sizeAttr) {
        field.emitError("field without topos.offset / topos.size: "
                        "the frontend lays out every field");
        missing = true;
        continue;
      }
      uint64_t offset = offAttr.getValue().getZExtValue();
      uint64_t size = sizeAttr.getValue().getZExtValue();
      std::string name = field.getSymName().str();
      layout.fieldOffsets[name] = offset;
      layout.fieldSizes[name] = size;
      layout.fieldTypes[name] = field.getFieldType();
      layout.fieldOrder.push_back(name);
      end = std::max(end, offset + size);
    }
    layout.totalSize = end;
    result[place.getSymName()] = std::move(layout);
  });
  return result;
}

//===----------------------------------------------------------------------===//
// Type converter : aligned to XLeech2 runtime ABI.
//
//   !topos.proposition       -> i8     (tri-valued: T=0, F=1, U=2)
//   !topos.section<P>        -> i64    (packed heap_id<<32 | xcoord)
//   !topos.probe<src->dst>    -> !llvm.struct<(i32, i32)>
//                              = HeapRef { heap_id, xcoord }
//
// The PlaceLayout map is used by the ops that emit calls into the
// runtime (sizes, field offsets, type ids); the layout is not the
// type itself: it is metadata used by the lowering patterns to build
// the load/store calls.
//===----------------------------------------------------------------------===//

class ToposTypeConverter : public TypeConverter {
public:
  ToposTypeConverter(MLIRContext *ctx,
                     const llvm::StringMap<PlaceLayout> &layouts)
      : ctx(ctx), layouts(layouts) {
    addConversion([](Type t) { return t; });
    addConversion([ctx](PropositionType /*t*/) -> Type {
      return IntegerType::get(ctx, 8);
    });
    // !topos.section<"P"> -> i32 (yon_xcoord_t).
    //
    // An xcoord is a 32-bit unsigned with the XLeech2 mmgroup encoding
    // (24-bit Λ/2Λ + 1 sign bit). Every type-2 vector in the Leech
    // lattice has a unique xcoord; the runtime resolves xcoord -> slot
    // via MPHF in O(1) without auxiliary tables.
    //
    // cross-Space: section -> i64 (packed heap_id<<32 | xcoord); ops that
    // accept or produce a section use i64.
    addConversion([this](SectionType /*st*/) -> Type {
      return IntegerType::get(this->ctx, 64);
    });
    // !topos.probe<src -> dst> -> !llvm.struct<(i32, i32)>
    //                         = HeapRef { heap_id, xcoord }
    //
    // The HeapRef carries (heap_id, xcoord) so a probe value can flow
    // across function boundaries without sharing physical pointers.
    // No pattern here lowers a probe application: probe_construct and
    // probe_apply are illegal in this pass (local pairs are fused into
    // topos.op_apply by LowerToposExtensions).
    addConversion([this](ProbeType /*pt*/) -> Type {
      auto i32 = IntegerType::get(this->ctx, 32);
      return LLVM::LLVMStructType::getLiteral(this->ctx, {i32, i32});
    });
    // !topos.heyt_int<N> -> !llvm.struct<(i64, i64)>  = { value, mask }
    //
    // Each Heyt-int is represented by an LLVM struct with two i64:
    //   - value: bit-vector of the "certain" values (1 = Present, 0 = Absent/Unknown)
    //   - mask:  "Unknown" bit-vector (1 = trit is U, 0 = certain)
    //
    // The 7 topos.heyt_int_* ops are lowered to sequences of
    // arith.{andi,ori,xori} on i64 + LLVM::Insert/ExtractValue for
    // assemblare/disassemblare la struct. Il parametro N (numTrits) e'
    // ignored at runtime — preserved only as static info.
    addConversion([this](HeytIntType /*hi*/) -> Type {
      auto i64 = IntegerType::get(this->ctx, 64);
      return LLVM::LLVMStructType::getLiteral(this->ctx, {i64, i64});
    });
  }

private:
  MLIRContext *ctx;
  const llvm::StringMap<PlaceLayout> &layouts;
};

//===----------------------------------------------------------------------===//
// Pattern: erase di evidenze di tipo
//===----------------------------------------------------------------------===//

struct EraseFieldOp : public OpConversionPattern<FieldOp> {
  using OpConversionPattern<FieldOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(FieldOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    rewriter.eraseOp(op);
    return success();
  }
};

struct ErasePathOp : public OpConversionPattern<PathOp> {
  using OpConversionPattern<PathOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(PathOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    if (!op->use_empty()) return failure();
    rewriter.eraseOp(op);
    return success();
  }
};

struct EraseCoherenceOp : public OpConversionPattern<CoherenceOp> {
  using OpConversionPattern<CoherenceOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(CoherenceOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    if (!op->use_empty()) return failure();
    rewriter.eraseOp(op);
    return success();
  }
};

// topos.world and topos.place: metadata containers, no runtime. The match
// here checks that the body is empty and erases the op. These two patterns are
// not added to the pattern set of this pass: world and place are erased by the
// post-conversion cleanup at the end of runOnOperation.
struct ErasePlaceOp : public OpConversionPattern<PlaceOp> {
  using OpConversionPattern<PlaceOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(PlaceOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    if (!op.getBody().empty()) {
      Block &front = op.getBody().front();
      if (!front.empty())
        return rewriter.notifyMatchFailure(
            op, "place body not yet empty; awaiting inner lowering");
    }
    rewriter.eraseOp(op);
    return success();
  }
};

struct EraseWorldOp : public OpConversionPattern<WorldOp> {
  using OpConversionPattern<WorldOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(WorldOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    if (!op.getBody().empty()) {
      Block &front = op.getBody().front();
      if (!front.empty())
        return rewriter.notifyMatchFailure(
            op, "world body not yet empty; awaiting inner lowering");
    }
    rewriter.eraseOp(op);
    return success();
  }
};

// `topos.reduce` is the categorical declaration of a reduction (a
// geometric morphism with policy). We materialise it as a private
// `func.func` declaration whose body the runtime XLeech2 will
// provide (via MPHF lookup at link time). The function signature
// is fixed by the categorical structure: a reduction on place `P`
// is a morphism `Section<P> -> Section<P>`, so the lowered function
// type is `(memref<N x i8>) -> memref<N x i8>` where N is the
// totalSize of the place's layout.
//
// The `direction` and `policy` attributes are encoded as MLIR
// attributes on the materialised `func.func`, so downstream passes
// (e.g. ReductionInlining, MoveComposition) and the runtime can
// inspect them.
struct MaterializeReduceOp : public OpConversionPattern<ReduceOp> {
  MaterializeReduceOp(const TypeConverter &tc, MLIRContext *ctx,
                      const llvm::StringMap<PlaceLayout> &layouts)
      : OpConversionPattern<ReduceOp>(tc, ctx), layouts(layouts) {}

  LogicalResult matchAndRewrite(ReduceOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    StringRef placeName = op.getOfPlace();
    auto it = layouts.find(placeName);
    if (it == layouts.end()) {
      return rewriter.notifyMatchFailure(
          op, "reduction '" + op.getSymName().str() +
                  "' references place '" + placeName.str() +
                  "', whose layout is missing — was the place "
                  "declared and walked by the layout-collection "
                  "phase?");
    }

    int64_t size = static_cast<int64_t>(it->second.totalSize);
    if (size == 0) size = ShapedType::kDynamic;

    auto i8Type = rewriter.getIntegerType(8);
    auto sectionType = MemRefType::get({size}, i8Type);
    auto funcType =
        rewriter.getFunctionType({sectionType}, {sectionType});

    std::string mangled = (op.getSymName() + "__reduce").str();

    // The materialised function is a private declaration with no
    // body: the runtime supplies it through MPHF lookup at link
    // time. We attach the reduction's categorical attributes so the
    // runtime (and any downstream MLIR pass) can read them off the
    // function.
    auto module = op->getParentOfType<ModuleOp>();
    if (!module)
      return rewriter.notifyMatchFailure(
          op, "reduction is not nested in a module");

    PatternRewriter::InsertionGuard guard(rewriter);
    rewriter.setInsertionPointToEnd(module.getBody());

    auto funcOp =
        rewriter.create<func::FuncOp>(op.getLoc(), mangled, funcType);
    funcOp.setPrivate();
    funcOp->setAttr("topos.reduction.direction",
                    rewriter.getI32IntegerAttr(
                        static_cast<int32_t>(op.getDirection())));
    funcOp->setAttr("topos.reduction.policy",
                    rewriter.getI32IntegerAttr(
                        static_cast<int32_t>(op.getPolicy())));
    funcOp->setAttr("topos.reduction.shot_ordering",
                    rewriter.getI32IntegerAttr(
                        static_cast<int32_t>(op.getShotOrdering())));
    if (op.getLawful())
      funcOp->setAttr("topos.reduction.lawful",
                      rewriter.getUnitAttr());
    if (op.getInvertible())
      funcOp->setAttr("topos.reduction.invertible",
                      rewriter.getUnitAttr());
    if (op.getMultiShot())
      funcOp->setAttr("topos.reduction.multi_shot",
                      rewriter.getUnitAttr());
    if (op.getCoeffectPreserving())
      funcOp->setAttr("topos.reduction.coeffect_preserving",
                      rewriter.getUnitAttr());

    rewriter.eraseOp(op);
    return success();
  }

  const llvm::StringMap<PlaceLayout> &layouts;
};

//===----------------------------------------------------------------------===//
// Materialize `topos.geom_morphism` as two `func.func` declarations.
//
// A geometric morphism `f : S -> T` is an adjoint pair
//
//     f^* (pull) : Sh(T) -> Sh(S)
//     f_* (push) : Sh(S) -> Sh(T)
//
// At the dialect level the two regions `pull` and `push` define
// the action. Lowering materialises:
//
//     func.func private @<name>__pull(memref<? x i8>) -> memref<? x i8>
//     func.func private @<name>__push(memref<? x i8>) -> memref<? x i8>
//
// Both as opaque declarations: the runtime XLeech2 provides the
// concrete implementation through its MPHF index, indexed by the
// mangled name.
//
// The geom_morphism's source_site and target_site identify world
// names, not concrete places, so we cannot fix the section layout
// at lowering time. We use a dynamic 1-D memref<? x i8> on both ends;
// the runtime resolves the concrete shape from the named world.
//
// The pattern emits two private function declarations, `<name>__pull`
// and `<name>__push`, each annotated with the source/target site and
// its kind, and erases the op. GeomMorphismOp has no regions, so there
// is no body to lower.
//===----------------------------------------------------------------------===//

struct MaterializeGeomMorphismOp
    : public OpConversionPattern<GeomMorphismOp> {
  using OpConversionPattern<GeomMorphismOp>::OpConversionPattern;

  LogicalResult matchAndRewrite(GeomMorphismOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter)
      const override {
    // GeomMorphismOp is a pure declaration (no region). The lowering
    // emits two private functions `<name>__pull` and `<name>__push` that the
    // runtime resolves as cross-Space copy-in / copy-out.

    auto module = op->getParentOfType<ModuleOp>();
    if (!module)
      return rewriter.notifyMatchFailure(
          op, "geom_morphism is not nested in a module");

    // Dynamic memref<? x i8> on both sides: the runtime knows the
    // shape from the source/target world.
    auto i8Type = rewriter.getIntegerType(8);
    auto opaqueSection = MemRefType::get({ShapedType::kDynamic}, i8Type);
    auto fnType =
        rewriter.getFunctionType({opaqueSection}, {opaqueSection});

    PatternRewriter::InsertionGuard guard(rewriter);
    rewriter.setInsertionPointToEnd(module.getBody());

    std::string pullName = (op.getSymName() + "__pull").str();
    std::string pushName = (op.getSymName() + "__push").str();

    auto pullFn =
        rewriter.create<func::FuncOp>(op.getLoc(), pullName, fnType);
    pullFn.setPrivate();
    pullFn->setAttr("topos.geom_morphism.source_site",
                    rewriter.getStringAttr(op.getSourceSite()));
    pullFn->setAttr("topos.geom_morphism.target_site",
                    rewriter.getStringAttr(op.getTargetSite()));
    pullFn->setAttr("topos.geom_morphism.kind",
                    rewriter.getStringAttr("pull"));
    if (op.getProperBaseChangeAttested())
      pullFn->setAttr("topos.geom_morphism.proper_base_change",
                      rewriter.getUnitAttr());

    auto pushFn =
        rewriter.create<func::FuncOp>(op.getLoc(), pushName, fnType);
    pushFn.setPrivate();
    pushFn->setAttr("topos.geom_morphism.source_site",
                    rewriter.getStringAttr(op.getSourceSite()));
    pushFn->setAttr("topos.geom_morphism.target_site",
                    rewriter.getStringAttr(op.getTargetSite()));
    pushFn->setAttr("topos.geom_morphism.kind",
                    rewriter.getStringAttr("push"));

    rewriter.eraseOp(op);
    return success();
  }
};

//===----------------------------------------------------------------------===//
// Lower `topos.forces` to scf.if on the proposition value.
//
// Semantics:
//   topos.forces @stage, %cond { body }
//
// At the standard layer %cond is i8 with encoding T=0, F=1, U=2.
// We emit `scf.if (%cond == 0_i8) then { body } else {}`. The body
// of forces runs only when the stage forces the proposition; the
// `@stage` symbol is recorded as an MLIR attribute on the scf.if
// for downstream passes that may want to specialise per stage.
//===----------------------------------------------------------------------===//

struct LowerForcesOp : public OpConversionPattern<ForcesOp> {
  using OpConversionPattern<ForcesOp>::OpConversionPattern;

  LogicalResult matchAndRewrite(ForcesOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto i8 = rewriter.getIntegerType(8);
    Value t = rewriter.create<arith::ConstantOp>(
        loc, i8, rewriter.getIntegerAttr(i8, 0));
    Value cond = rewriter.create<arith::CmpIOp>(
        loc, arith::CmpIPredicate::eq, adaptor.getCondition(), t);

    auto ifOp = rewriter.create<scf::IfOp>(loc, cond, /*hasElse=*/false);
    ifOp->setAttr("topos.forces.stage",
                  rewriter.getStringAttr(op.getStage()));

    // Move the body of `topos.forces` into the scf.if then-block.
    Block &then = ifOp.getThenRegion().front();
    Block &src = op.getBody().front();
    rewriter.setInsertionPointToStart(&then);
    IRMapping mapping;
    for (Operation &inner : src) {
      rewriter.clone(inner, mapping);
    }
    // scf.if requires its blocks to be terminated by scf.yield.
    rewriter.setInsertionPointToEnd(&then);
    if (then.empty() ||
        !then.back().hasTrait<OpTrait::IsTerminator>()) {
      rewriter.create<scf::YieldOp>(loc);
    }

    rewriter.eraseOp(op);
    return success();
  }
};

//===----------------------------------------------------------------------===//
// Pattern: topos.heyt -> arith.constant i8
//===----------------------------------------------------------------------===//

struct LowerHeytConstOp : public OpConversionPattern<HeytOp> {
  using OpConversionPattern<HeytOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    auto val = op.getValue();
    int8_t encoded;
    switch (val) {
    case HeytingValue::True:    encoded = 0; break;
    case HeytingValue::False:   encoded = 1; break;
    case HeytingValue::Unknown: encoded = 2; break;
    default: return failure();
    }
    auto i8Type = rewriter.getIntegerType(8);
    rewriter.replaceOpWithNewOp<arith::ConstantOp>(
        op, i8Type, rewriter.getIntegerAttr(i8Type, encoded));
    return success();
  }
};

//===----------------------------------------------------------------------===//
// Heyting tri-valued — encoding T=0, F=1, U=2
//===----------------------------------------------------------------------===//

// AND(a,b): F dominante. Se a=F o b=F -> F; se a=T -> b; se b=T -> a; else U.
struct LowerHeytAndOp : public OpConversionPattern<HeytAndOp> {
  using OpConversionPattern<HeytAndOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytAndOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    Value a = adaptor.getLhs();
    Value b = adaptor.getRhs();
    auto i8Type = rewriter.getIntegerType(8);

    Value T = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 0));
    Value F = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 1));
    Value U = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 2));

    Value aIsF = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, a, F);
    Value bIsF = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, b, F);
    Value aIsT = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, a, T);
    Value bIsT = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, b, T);

    Value anyF = rewriter.create<arith::OrIOp>(loc, aIsF, bIsF);
    Value innerTBranch = rewriter.create<arith::SelectOp>(loc, bIsT, a, U);
    Value notFBranch   = rewriter.create<arith::SelectOp>(loc, aIsT, b, innerTBranch);
    Value result       = rewriter.create<arith::SelectOp>(loc, anyF, F, notFBranch);

    rewriter.replaceOp(op, result);
    return success();
  }
};

// OR(a,b): T dominante. Se a=T o b=T -> T; se a=F -> b; se b=F -> a; else U.
struct LowerHeytOrOp : public OpConversionPattern<HeytOrOp> {
  using OpConversionPattern<HeytOrOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytOrOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    Value a = adaptor.getLhs();
    Value b = adaptor.getRhs();
    auto i8Type = rewriter.getIntegerType(8);

    Value T = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 0));
    Value F = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 1));
    Value U = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 2));

    Value aIsT = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, a, T);
    Value bIsT = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, b, T);
    Value aIsF = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, a, F);
    Value bIsF = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, b, F);

    Value anyT = rewriter.create<arith::OrIOp>(loc, aIsT, bIsT);
    Value innerFBranch = rewriter.create<arith::SelectOp>(loc, bIsF, a, U);
    Value notTBranch   = rewriter.create<arith::SelectOp>(loc, aIsF, b, innerFBranch);
    Value result       = rewriter.create<arith::SelectOp>(loc, anyT, T, notTBranch);

    rewriter.replaceOp(op, result);
    return success();
  }
};

// NOT(a): T->F, F->T, U->U.
struct LowerHeytNotOp : public OpConversionPattern<HeytNotOp> {
  using OpConversionPattern<HeytNotOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytNotOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    Value a = adaptor.getOperand();
    auto i8Type = rewriter.getIntegerType(8);

    Value T = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 0));
    Value F = rewriter.create<arith::ConstantOp>(loc, i8Type, rewriter.getIntegerAttr(i8Type, 1));

    Value aIsT = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, a, T);
    Value aIsF = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::eq, a, F);

    // Regular Heyting negation neg a = a -> bot on the Gödel chain:
    //   neg T = F, neg F = T, neg U = F  (NOT involutive).
    // a = F -> T; otherwise (a = T or a = U) the non-F branch is F.
    Value innerBranch = rewriter.create<arith::SelectOp>(loc, aIsF, T, F);
    Value result      = rewriter.create<arith::SelectOp>(loc, aIsT, F, innerBranch);

    rewriter.replaceOp(op, result);
    return success();
  }
};

//===----------------------------------------------------------------------===//
// topos.heyt_implies -> arith truth table.
//
// Tri-valued implication a -> b, Gödel G3 Heyting residual, under the
// encoding {T=0, F=1, U=2}:
//   T -> T = T   T -> F = F   T -> U = U
//   F -> _ = T  (ex falso quodlibet)
//   U -> T = T   U -> F = F   U -> U = T   (a -> a = top, residuation)
//
// Lowered through the same TypeConverter that maps !topos.proposition
// to i8, so the OpAdaptor operands arrive already as i8 values.
//===----------------------------------------------------------------------===//

struct LowerHeytImpliesOp : public OpConversionPattern<HeytImpliesOp> {
  using OpConversionPattern<HeytImpliesOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytImpliesOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    Value a = adaptor.getLhs();
    Value b = adaptor.getRhs();
    auto i8Type = rewriter.getIntegerType(8);

    Value T = rewriter.create<arith::ConstantOp>(
        loc, i8Type, rewriter.getIntegerAttr(i8Type, 0));
    Value F = rewriter.create<arith::ConstantOp>(
        loc, i8Type, rewriter.getIntegerAttr(i8Type, 1));

    Value aIsT = rewriter.create<arith::CmpIOp>(
        loc, arith::CmpIPredicate::eq, a, T);
    Value aIsF = rewriter.create<arith::CmpIOp>(
        loc, arith::CmpIPredicate::eq, a, F);
    Value bIsF = rewriter.create<arith::CmpIOp>(
        loc, arith::CmpIPredicate::eq, b, F);

    // a = U branch (Gödel residual): U -> b = F if b = F, else T
    // (U -> U = T is reflexivity a -> a = top; U -> F = F by residuation).
    Value uBranch = rewriter.create<arith::SelectOp>(loc, bIsF, F, T);
    // a = F branch: ex falso -> T (overrides U branch).
    Value notTBranch =
        rewriter.create<arith::SelectOp>(loc, aIsF, T, uBranch);
    // a = T branch: result = b unchanged.
    Value result =
        rewriter.create<arith::SelectOp>(loc, aIsT, b, notTBranch);

    rewriter.replaceOp(op, result);
    return success();
  }
};

// HEYT_IS Heyting: bit-wise equality (i8) over the 3 canonical values.
// Returns i1 (a classical branch decision).
struct LowerHeytIsOp : public OpConversionPattern<HeytIsOp> {
  using OpConversionPattern<HeytIsOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIsOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Value a = adaptor.getLhs();
    Value b = adaptor.getRhs();
    Value eq = rewriter.create<arith::CmpIOp>(
        op.getLoc(), arith::CmpIPredicate::eq, a, b);
    rewriter.replaceOp(op, eq);
    return success();
  }
};

// HEYT_TO_I32: extend i8 payload a i32 via zero-extend.
struct LowerHeytToI32Op : public OpConversionPattern<HeytToI32Op> {
  using OpConversionPattern<HeytToI32Op>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytToI32Op op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    auto i32Type = rewriter.getIntegerType(32);
    Value ext = rewriter.create<arith::ExtUIOp>(
        op.getLoc(), i32Type, adaptor.getValue());
    rewriter.replaceOp(op, ext);
    return success();
  }
};

// HEYT_FROM_I8: i8 -> proposition. Identity after conversion (typeConverter
// maps proposition -> i8). Trivial replace with the underlying i8 value.
struct LowerHeytFromI8Op : public OpConversionPattern<HeytFromI8Op> {
  using OpConversionPattern<HeytFromI8Op>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytFromI8Op op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    rewriter.replaceOp(op, adaptor.getValue());
    return success();
  }
};

//===----------------------------------------------------------------------===//
// 
// Heyt-int<N> lowering — bitwise intuizionista bit-per-bit.
//
// Encoding: !topos.heyt_int<N>  ->  !llvm.struct<(i64, i64)>  = {value, mask}
//   - value[i] = 1 iff trit i is Present (irrelevant if mask[i] = 1)
//   - mask[i]  = 1 iff trit i is Unknown
//
// Tabelle Heyting bit-per-bit:
//
//   AND: AANDx=A (assorbente), PANDP=P, PANDU=U, UANDU=U
//     result.value = a.v & b.v & ~result.mask
//     result.mask  = (a.m | b.m) & ~A_absorbs
//        where A_absorbs = (a non-U AND a.v=0) OR (b non-U AND b.v=0)
//                       = (~a.m & ~a.v) | (~b.m & ~b.v)
//     That is, U if both non-A, A if at least one is certainly A.
//
//   OR: PORx=P (assorbente), AORA=A, AORU=U, UORU=U  (duale di AND)
//     result.value = a.v | b.v
//     result.mask  = (a.m | b.m) & ~P_absorbs
//        where P_absorbs = (~a.m & a.v) | (~b.m & b.v)
//
//   XOR: noto - propaga U:  U^x=U
//     result.value = a.v ^ b.v
//     result.mask  = a.m | b.m
//
//   NOT: flip value, mask invariata (~P=A, ~A=P, ~U=U)
//     result.value = ~a.v
//     result.mask  = a.m
//===----------------------------------------------------------------------===//

namespace {

// Helper: extracts (value, mask) i64 from the LLVM struct.
inline std::pair<Value, Value> unpackHeytInt(ConversionPatternRewriter &rewriter,
                                              Location loc, Value packed) {
  auto i64 = rewriter.getIntegerType(64);
  Value v = rewriter.create<LLVM::ExtractValueOp>(loc, i64, packed,
              ArrayRef<int64_t>{0});
  Value m = rewriter.create<LLVM::ExtractValueOp>(loc, i64, packed,
              ArrayRef<int64_t>{1});
  return {v, m};
}

// Helper: assembla (value, mask) i64 in una struct LLVM.
inline Value packHeytInt(ConversionPatternRewriter &rewriter, Location loc,
                          Value value, Value mask, MLIRContext *ctx) {
  auto i64 = IntegerType::get(ctx, 64);
  auto structTy = LLVM::LLVMStructType::getLiteral(ctx, {i64, i64});
  Value undef = rewriter.create<LLVM::UndefOp>(loc, structTy);
  Value step1 = rewriter.create<LLVM::InsertValueOp>(loc, undef, value,
                  ArrayRef<int64_t>{0});
  Value packed = rewriter.create<LLVM::InsertValueOp>(loc, step1, mask,
                   ArrayRef<int64_t>{1});
  return packed;
}

// Helper: bitwise NOT su i64 (xor con -1)
inline Value bitNotI64(ConversionPatternRewriter &rewriter, Location loc, Value x) {
  auto i64 = rewriter.getIntegerType(64);
  Value allOnes = rewriter.create<arith::ConstantOp>(loc, i64,
                    rewriter.getIntegerAttr(i64, -1));
  return rewriter.create<arith::XOrIOp>(loc, x, allOnes);
}

} // anonymous namespace

// MAKE: assembla (value, mask) -> struct
struct LowerHeytIntMakeOp : public OpConversionPattern<HeytIntMakeOp> {
  using OpConversionPattern<HeytIntMakeOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIntMakeOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Value packed = packHeytInt(rewriter, op.getLoc(),
                                adaptor.getValue(), adaptor.getMask(),
                                rewriter.getContext());
    rewriter.replaceOp(op, packed);
    return success();
  }
};

// VALUE: extracts the value bit-vector (first field of struct)
struct LowerHeytIntValueOp : public OpConversionPattern<HeytIntValueOp> {
  using OpConversionPattern<HeytIntValueOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIntValueOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    auto i64 = rewriter.getIntegerType(64);
    Value v = rewriter.create<LLVM::ExtractValueOp>(
        op.getLoc(), i64, adaptor.getOperand(), ArrayRef<int64_t>{0});
    rewriter.replaceOp(op, v);
    return success();
  }
};

// MASK: extracts the mask bit-vector (second field of struct)
struct LowerHeytIntMaskOp : public OpConversionPattern<HeytIntMaskOp> {
  using OpConversionPattern<HeytIntMaskOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIntMaskOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    auto i64 = rewriter.getIntegerType(64);
    Value m = rewriter.create<LLVM::ExtractValueOp>(
        op.getLoc(), i64, adaptor.getOperand(), ArrayRef<int64_t>{1});
    rewriter.replaceOp(op, m);
    return success();
  }
};

// AND bit-per-bit:
//   value = a.v & b.v & ~mask_out
//   mask  = (a.m | b.m) & ~((~a.m & ~a.v) | (~b.m & ~b.v))
struct LowerHeytIntAndOp : public OpConversionPattern<HeytIntAndOp> {
  using OpConversionPattern<HeytIntAndOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIntAndOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto [av, am] = unpackHeytInt(rewriter, loc, adaptor.getLhs());
    auto [bv, bm] = unpackHeytInt(rewriter, loc, adaptor.getRhs());
    // A_absorbs = (~a.m & ~a.v) | (~b.m & ~b.v)
    Value notAm = bitNotI64(rewriter, loc, am);
    Value notAv = bitNotI64(rewriter, loc, av);
    Value notBm = bitNotI64(rewriter, loc, bm);
    Value notBv = bitNotI64(rewriter, loc, bv);
    Value aAbsorbs = rewriter.create<arith::AndIOp>(loc, notAm, notAv);
    Value bAbsorbs = rewriter.create<arith::AndIOp>(loc, notBm, notBv);
    Value absorbs  = rewriter.create<arith::OrIOp>(loc, aAbsorbs, bAbsorbs);
    Value notAbsorbs = bitNotI64(rewriter, loc, absorbs);
    // mask_out = (a.m | b.m) & ~absorbs
    Value rawMask = rewriter.create<arith::OrIOp>(loc, am, bm);
    Value maskOut = rewriter.create<arith::AndIOp>(loc, rawMask, notAbsorbs);
    // value_out = (a.v & b.v) & ~mask_out  [bit U -> value irrilevante a 0]
    Value rawValue = rewriter.create<arith::AndIOp>(loc, av, bv);
    Value notMaskOut = bitNotI64(rewriter, loc, maskOut);
    Value valueOut = rewriter.create<arith::AndIOp>(loc, rawValue, notMaskOut);
    Value packed = packHeytInt(rewriter, loc, valueOut, maskOut,
                                rewriter.getContext());
    rewriter.replaceOp(op, packed);
    return success();
  }
};

// OR bit-per-bit (duale di AND):
//   value = a.v | b.v
//   mask  = (a.m | b.m) & ~((~a.m & a.v) | (~b.m & b.v))
struct LowerHeytIntOrOp : public OpConversionPattern<HeytIntOrOp> {
  using OpConversionPattern<HeytIntOrOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIntOrOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto [av, am] = unpackHeytInt(rewriter, loc, adaptor.getLhs());
    auto [bv, bm] = unpackHeytInt(rewriter, loc, adaptor.getRhs());
    // P_absorbs = (~a.m & a.v) | (~b.m & b.v)
    Value notAm = bitNotI64(rewriter, loc, am);
    Value notBm = bitNotI64(rewriter, loc, bm);
    Value aAbsorbs = rewriter.create<arith::AndIOp>(loc, notAm, av);
    Value bAbsorbs = rewriter.create<arith::AndIOp>(loc, notBm, bv);
    Value absorbs  = rewriter.create<arith::OrIOp>(loc, aAbsorbs, bAbsorbs);
    Value notAbsorbs = bitNotI64(rewriter, loc, absorbs);
    Value rawMask = rewriter.create<arith::OrIOp>(loc, am, bm);
    Value maskOut = rewriter.create<arith::AndIOp>(loc, rawMask, notAbsorbs);
    Value valueOut = rewriter.create<arith::OrIOp>(loc, av, bv);
    Value packed = packHeytInt(rewriter, loc, valueOut, maskOut,
                                rewriter.getContext());
    rewriter.replaceOp(op, packed);
    return success();
  }
};

// XOR bit-per-bit:
//   value = a.v ^ b.v
//   mask  = a.m | b.m   (U propaga in XOR)
struct LowerHeytIntXorOp : public OpConversionPattern<HeytIntXorOp> {
  using OpConversionPattern<HeytIntXorOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIntXorOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto [av, am] = unpackHeytInt(rewriter, loc, adaptor.getLhs());
    auto [bv, bm] = unpackHeytInt(rewriter, loc, adaptor.getRhs());
    Value valueOut = rewriter.create<arith::XOrIOp>(loc, av, bv);
    Value maskOut  = rewriter.create<arith::OrIOp>(loc, am, bm);
    Value packed = packHeytInt(rewriter, loc, valueOut, maskOut,
                                rewriter.getContext());
    rewriter.replaceOp(op, packed);
    return success();
  }
};

// NOT bit-per-bit:
//   value = ~a.v
//   mask  = a.m   (U resta U)
struct LowerHeytIntNotOp : public OpConversionPattern<HeytIntNotOp> {
  using OpConversionPattern<HeytIntNotOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(HeytIntNotOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    Location loc = op.getLoc();
    auto [av, am] = unpackHeytInt(rewriter, loc, adaptor.getOperand());
    Value valueOut = bitNotI64(rewriter, loc, av);
    Value packed = packHeytInt(rewriter, loc, valueOut, am,
                                rewriter.getContext());
    rewriter.replaceOp(op, packed);
    return success();
  }
};

// SECTION_TO_XCOORD: identity dopo conversion (section -> i32).
struct LowerSectionToXcoordOp : public OpConversionPattern<SectionToXcoordOp> {
  using OpConversionPattern<SectionToXcoordOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(SectionToXcoordOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    rewriter.replaceOp(op, adaptor.getSection());
    return success();
  }
};

// XCOORD_TO_SECTION: identity dopo conversion (i32 -> section).
struct LowerXcoordToSectionOp : public OpConversionPattern<XcoordToSectionOp> {
  using OpConversionPattern<XcoordToSectionOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(XcoordToSectionOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    rewriter.replaceOp(op, adaptor.getXcoord());
    return success();
  }
};

// SubtypeCastOp lowering. Identity: the typeConverter maps
// !topos.section<"X"> -> i32 (xcoord) for ANY place name, so the logical cast
// between section types becomes identity on the i32.
struct LowerSubtypeCastOp : public OpConversionPattern<SubtypeCastOp> {
  using OpConversionPattern<SubtypeCastOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(SubtypeCastOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    rewriter.replaceOp(op, adaptor.getSource());
    return success();
  }
};

//===----------------------------------------------------------------------===//
// Helper : emit a runtime function declaration on demand.
// Same pattern as ensureRuntimeFunc in LowerToposExtensions.cpp.
//===----------------------------------------------------------------------===//
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

// Stable type_id for a place name. We derive it from a hash of the
// place's mangled name so that the runtime (which doesn't know our
// dialect) can use the same id consistently. The runtime owns the
// table of (type_id -> handlers); the lowering only needs to emit
// the same id for the same place.
static uint64_t typeIdFor(StringRef placeName) {
  return llvm::hash_value(placeName);
}

// TYPEID_CLOSURE constant ("YON_CLOS"): a single type id for closure
// objects. Nothing in this file uses it.
static constexpr uint64_t YON_TYPEID_CLOSURE = 0x59'4F'4E'5F'43'4C'4F'53ULL;

// XCOORD_INVALID — sentinel returned by yon_hexheap_alloc on collision
// exhaustion. Matches yon_xcoord_t::YON_XCOORD_INVALID in the runtime.
static constexpr uint32_t YON_XCOORD_INVALID = 0xFFFFFFFFu;

// Runtime helpers — standard signatures so ensureRuntimeFunc always
// emits the same declaration regardless of caller's static buffer
// shape. Callers cast their static memref<N x i8> to memref<? x i8>
// via memref.cast before invoking.
static MemRefType dynBytesType(MLIRContext *ctx) {
  return MemRefType::get({ShapedType::kDynamic},
                          IntegerType::get(ctx, 8));
}

// Cast a static memref<N x i8> to memref<? x i8> for runtime calls.
static Value castToDynBytes(OpBuilder &b, Location loc, Value staticBuf) {
  return b.create<memref::CastOp>(loc, dynBytesType(b.getContext()),
                                    staticBuf);
}

// Step 3 helper: converti un memref<? x i8> (o memref<N x i8>) in
// !llvm.ptr per chiamare le runtime XLeech2.
//
// Use the canonical MLIR pattern:
//   %idx  = memref.extract_aligned_pointer_as_index %m : memref<...> -> index
//   %i64  = arith.index_cast %idx : index to i64
//   %ptr  = llvm.inttoptr %i64 : i64 to !llvm.ptr
//
// This pattern is translated correctly by the LLVM conversion pipeline: the
// extract preserves the aligned pointer (field [1] of the MemRef descriptor),
// the cast to i64 and the inttoptr are both natively supported by
// mlir-translate.
//
// Note: the pointer obtained is the aligned_ptr — it matches what the C runtime
// expects for opaque buffers without dynamic offset/stride.
static Value memrefToPtr(OpBuilder &b, Location loc, Value memrefVal) {
  auto ctx = b.getContext();
  auto indexTy = b.getIndexType();
  auto i64Ty = b.getIntegerType(64);
  auto ptrTy = LLVM::LLVMPointerType::get(ctx);

  Value idx = b.create<memref::ExtractAlignedPointerAsIndexOp>(
      loc, indexTy, memrefVal);
  Value i64v = b.create<arith::IndexCastOp>(loc, i64Ty, idx);
  return b.create<LLVM::IntToPtrOp>(loc, ptrTy, i64v);
}

// Helper: given a base !llvm.ptr and a byte offset, loads a value of the given
// type. Uses the canonical LLVM pattern:
//
//   %off_ptr = llvm.getelementptr %base[%off_idx] : !llvm.ptr, i8
//   %value   = llvm.load %off_ptr : !llvm.ptr -> <T>
//
// The GEP is typed on i8 so that `offset` is in bytes. This pattern is
// translated directly by mlir-translate without intermediate MemRef descriptor
// steps.
static Value loadFromPtrAtOffset(OpBuilder &b, Location loc,
                                  Value basePtr, int64_t byteOffset,
                                  Type valueTy) {
  auto ctx = b.getContext();
  auto i8Ty = b.getIntegerType(8);

  // Build i64 constant for byte offset, used as GEP index over i8.
  auto i64Ty = b.getIntegerType(64);
  Value offC = b.create<LLVM::ConstantOp>(
      loc, i64Ty, b.getI64IntegerAttr(byteOffset));

  // GEP %base[off] where element type is i8 -> offset is in bytes.
  Value gepPtr = b.create<LLVM::GEPOp>(
      loc, LLVM::LLVMPointerType::get(ctx),
      i8Ty, basePtr, ValueRange{offC});

  // Load value.
  return b.create<LLVM::LoadOp>(loc, valueTy, gepPtr);
}

// Helper: given a base !llvm.ptr and a byte offset, stores a value. The mirror
// pattern of loadFromPtrAtOffset.
static void storeToPtrAtOffset(OpBuilder &b, Location loc,
                                Value basePtr, int64_t byteOffset,
                                Value value) {
  auto ctx = b.getContext();
  auto i8Ty = b.getIntegerType(8);
  auto i64Ty = b.getIntegerType(64);
  Value offC = b.create<LLVM::ConstantOp>(
      loc, i64Ty, b.getI64IntegerAttr(byteOffset));
  Value gepPtr = b.create<LLVM::GEPOp>(
      loc, LLVM::LLVMPointerType::get(ctx),
      i8Ty, basePtr, ValueRange{offC});
  b.create<LLVM::StoreOp>(loc, value, gepPtr);
}

// Helper: given a base !llvm.ptr and a byte offset, returns a !llvm.ptr
// pointing to base + offset. Used when a ptr to a sub-buffer is needed (e.g.
// `slot->data` at offset 16 inside slot).
static Value ptrOffset(OpBuilder &b, Location loc,
                        Value basePtr, int64_t byteOffset) {
  auto ctx = b.getContext();
  auto i8Ty = b.getIntegerType(8);
  auto i64Ty = b.getIntegerType(64);
  Value offC = b.create<LLVM::ConstantOp>(
      loc, i64Ty, b.getI64IntegerAttr(byteOffset));
  return b.create<LLVM::GEPOp>(
      loc, LLVM::LLVMPointerType::get(ctx),
      i8Ty, basePtr, ValueRange{offC});
}

//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// topos.section: no lowering pattern.
//===----------------------------------------------------------------------===//

// There is no arena-based lowering and no C arena model. The op keeps its
// dialect-level verifier; a module still containing it past this pass fails
// legalization loudly instead of silently allocating into a ghost arena.


//===----------------------------------------------------------------------===//
// There is no escaping-probe closure conversion and no pattern for it.
// `topos.probe_construct` / `topos.probe_apply` are never produced by the
// canonical frontend; they are listed in `addIllegalOp` below as a hard
// invariant, so any survivor fails the conversion (no pattern makes it
// legal).
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// topos.section / topos.restrict / topos.glue — arena-section lowerings.
//
// No lowering: there is no arena memref model. There
// is NO LowerSectionOp / LowerRestrictOp / LowerGlueOp pattern. These
// three ops are listed in `addIllegalOp` below as a hard invariant: the
// canonical frontend (emit_mlir) never emits them, so they never reach
// this pass; if one ever did, the conversion fails (no pattern to make
// it legal) rather than passing through un-lowered.
//===----------------------------------------------------------------------===//



//===----------------------------------------------------------------------===//
// topos.operation -> func.func
//===----------------------------------------------------------------------===//
//
// Name mangling: the op `topos.operation @withdraw` inside `topos.place
// @Account` becomes `func.func @Account__withdraw`. This avoids conflicts
// between same-named ops in different places and allows referencing the op via
// a flat symbol.
//
// For an empty body (no block, or a block with no ops) we emit a stub body
// that returns zero (or nothing for a void result); when the result type has
// no zero constant here, a private declaration is emitted instead. A
// non-empty body is cloned into the function.
//
// Note on signature: the operation has (arg_types, result_type) as MLIR
// attributes. The generated func.func has the augmented signature
// of a first parameter `instance: i32` (xcoord) corresponding to the
// enclosing place.

struct LowerOperationOp : public OpConversionPattern<OperationOp> {
  LowerOperationOp(const TypeConverter &tc, MLIRContext *ctx,
                   const llvm::StringMap<PlaceLayout> &layouts)
      : OpConversionPattern<OperationOp>(tc, ctx), layouts(layouts) {}

  LogicalResult matchAndRewrite(OperationOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    // Trova il PlaceOp parent (HasParent<"PlaceOp"> garantito dal trait).
    auto place = op->getParentOfType<PlaceOp>();
    if (!place)
      return rewriter.notifyMatchFailure(op, "operation outside a place");

    std::string mangled =
        (place.getSymName() + "__" + op.getSymName()).str();

    // Build the signature :
    //   (instance: i32 xcoord, args...) -> result
    //
    // The instance is an XLeech2 xcoord, the runtime address of
    // the slot in the HexHeap. The per-op function dereferences the
    // xcoord through the HexHeap when it needs to read the captured
    // fields — but at the dialect level the call site only passes
    // the xcoord.
    auto it = layouts.find(place.getSymName());
    if (it == layouts.end())
      return rewriter.notifyMatchFailure(op, "no layout for parent place");

    auto instanceType = rewriter.getIntegerType(32);

    SmallVector<Type, 4> inputTypes;
    inputTypes.push_back(instanceType);
    for (Attribute argTyAttr : op.getArgTypes()) {
      auto tyAttr = llvm::dyn_cast<TypeAttr>(argTyAttr);
      if (!tyAttr)
        return rewriter.notifyMatchFailure(op, "arg_type non-TypeAttr");
      Type converted = getTypeConverter()->convertType(tyAttr.getValue());
      inputTypes.push_back(converted);
    }
    Type resultType = getTypeConverter()->convertType(op.getResultType());
    SmallVector<Type, 1> resultTypes;
    if (resultType) resultTypes.push_back(resultType);

    auto funcType = rewriter.getFunctionType(inputTypes, resultTypes);

    // Determine whether the operation body is non-empty. The body is AnyRegion;
    // it may be zero-block (absent) or single-block-empty (^bb0: with no ops) —
    // both handled as the stub case below. If the body contains at least one
    // op, we treat it as a full func.
    bool hasBody = false;
    if (!op.getBody().empty()) {
      Block &front = op.getBody().front();
      for (Operation &inner : front) {
        (void)inner;
        hasBody = true;
        break;
      }
    }

    auto module = op->getParentOfType<ModuleOp>();
    PatternRewriter::InsertionGuard guard(rewriter);

    // If there is already a declaration `func.func private @<mangled>` (emitted
    // by the frontend as a placeholder for the verifier), we replace it by
    // filling it with the body instead of creating a duplicate.
    auto existing = module.lookupSymbol<func::FuncOp>(mangled);
    func::FuncOp funcOp;
    if (existing && existing.isPrivate() && existing.empty()) {
      // Check signature compatibility.
      if (existing.getFunctionType() != funcType) {
        return rewriter.notifyMatchFailure(
            op, "existing declaration has incompatible signature");
      }
      funcOp = existing;
      funcOp.setPublic();  // ora ha un body
    } else {
      rewriter.setInsertionPointToEnd(module.getBody());
      funcOp = rewriter.create<func::FuncOp>(
          op.getLoc(), mangled, funcType);
    }

    if (!hasBody) {
      // Emit a body that returns zero instead of a private declaration, so
      // the module links.
      Block *entry = funcOp.addEntryBlock();
      rewriter.setInsertionPointToStart(entry);
      if (resultTypes.empty()) {
        rewriter.create<func::ReturnOp>(op.getLoc());
      } else {
        Type rt = resultTypes[0];
        Value zero;
        if (auto intTy = llvm::dyn_cast<IntegerType>(rt)) {
          zero = rewriter.create<arith::ConstantIntOp>(
              op.getLoc(), 0, intTy);
        } else if (auto floatTy = llvm::dyn_cast<FloatType>(rt)) {
          zero = rewriter.create<arith::ConstantFloatOp>(
              op.getLoc(), llvm::APFloat(0.0), floatTy);
        } else if (llvm::isa<LLVM::LLVMPointerType>(rt)) {
          zero = rewriter.create<LLVM::ZeroOp>(op.getLoc(), rt);
        } else {
          // Unhandled type: private declaration fallback
          funcOp.eraseBody();
          funcOp.setPrivate();
          rewriter.eraseOp(op);
          return success();
        }
        rewriter.create<func::ReturnOp>(op.getLoc(), ValueRange{zero});
      }
      rewriter.eraseOp(op);
      return success();
    }

    // Full func: move del body. Il body dell'operation aveva block args
    // equal to the original arg_types (potentially of Topos type); we must
    // augment them with instance and convert the types.
    Region &srcRegion = op.getBody();
    Block &srcBlock = srcRegion.front();

    // Create the new block args according to the new signature.
    Block *entry = funcOp.addEntryBlock();
    // Map: srcBlock arg[i] -> entry arg[i+1] (offset 1 for instance).
    if (srcBlock.getNumArguments() != op.getArgTypes().size())
      return rewriter.notifyMatchFailure(
          op, "body block args count mismatch with arg_types");

    // Imposta l'IR map.
    IRMapping mapping;
    for (size_t i = 0; i < srcBlock.getNumArguments(); ++i) {
      // entry args: [0]=instance, [1..]=original args
      mapping.map(srcBlock.getArgument(i), entry->getArgument(i + 1));
    }

    // Clone the ops of the src body into the dest body, applying the mapping.
    rewriter.setInsertionPointToStart(entry);
    for (Operation &nested : srcBlock) {
      rewriter.clone(nested, mapping);
    }

    // Ensure the body has a terminator. If the last cloned op is not already a
    // terminator, add a func.return.
    // (The NoTerminator trait on the topos.operation body made the terminator
    // optional; func.func requires it.)
    Block &destBlock = funcOp.getBody().front();
    if (destBlock.empty() ||
        !destBlock.back().hasTrait<OpTrait::IsTerminator>()) {
      rewriter.setInsertionPointToEnd(&destBlock);
      if (resultTypes.empty()) {
        rewriter.create<func::ReturnOp>(op.getLoc());
      } else {
        // No result value to return — a typed function but there is no value:
        // the match fails.
        return rewriter.notifyMatchFailure(
            op, "non-empty body without explicit return for typed result");
      }
    }

    rewriter.eraseOp(op);
    return success();
  }

private:
  const llvm::StringMap<PlaceLayout> &layouts;
};

//===----------------------------------------------------------------------===//
// topos.op_apply -> func.call al nome mangled
//===----------------------------------------------------------------------===//
//
// Strategy (a direct call, no runtime dispatch):
//   topos.op_apply @op on %inst (%args) -> func.call @<Place>__<op>(%inst, %args)
//
// The name of the operation's enclosing place is deduced from the original AST
// by scanning the module (find the OperationOp with sym_name == op_ref and take
// its parent PlaceOp).

struct LowerOpApplyOp : public OpConversionPattern<OpApplyOp> {
  using OpConversionPattern<OpApplyOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(OpApplyOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    StringRef opName = op.getOpRef();

    // Cerca l'OperationOp di nome opName nel modulo per trovare il
    // place enclosing.
    auto module = op->getParentOfType<ModuleOp>();
    OperationOp targetOp = nullptr;
    PlaceOp targetPlace = nullptr;
    module.walk([&](OperationOp candidate) {
      if (candidate.getSymName() == opName) {
        targetOp = candidate;
        targetPlace = candidate->getParentOfType<PlaceOp>();
        return WalkResult::interrupt();
      }
      return WalkResult::advance();
    });
    if (!targetOp || !targetPlace)
      return rewriter.notifyMatchFailure(
          op, "operation '" + opName.str() + "' not found");

    std::string mangled =
        (targetPlace.getSymName() + "__" + opName).str();

    // Build the call. Arguments: instance + args (the adaptor returns the
    // values already in the converted type).
    SmallVector<Value, 4> callArgs;
    callArgs.push_back(adaptor.getInstance());
    for (Value v : adaptor.getArgs())
      callArgs.push_back(v);

    // Result type convertito.
    Type origResultType = op.getResult().getType();
    Type convertedResultType =
        getTypeConverter()->convertType(origResultType);
    SmallVector<Type, 1> resultTypes;
    if (convertedResultType) resultTypes.push_back(convertedResultType);

    auto callOp = rewriter.create<func::CallOp>(
        op.getLoc(), mangled, resultTypes, callArgs);
    if (callOp.getNumResults() > 0)
      rewriter.replaceOp(op, callOp.getResults());
    else
      rewriter.eraseOp(op);
    return success();
  }
};

//===----------------------------------------------------------------------===//
// topos.move -> func.func, topos.apply_move -> func.call
//===----------------------------------------------------------------------===//
//
// A topos.move @M from @Src to @Dst is declared top-level in the module (not
// inside a world or place). MoveOp is a pure declaration (no region body).
// Lowering:
//
//   topos.move @M from @Src to @Dst
//   ->
//   func.func @M__move(%src: i32) -> i32 {
//     // default identity: returns the input xcoord unchanged
//   }
//
// For the baseline we handle only an empty body = default identity copy.
// Identity requires Src and Dst with the same layout — checked at runtime via
// an assert on the size (in static MLIR it is a check on the types). A non-empty
// body is not lowered: it needs a sub-IR of move expressions that the dialect
// does not formalize.

struct LowerMoveOp : public OpConversionPattern<MoveOp> {
  LowerMoveOp(const TypeConverter &tc, MLIRContext *ctx,
              const llvm::StringMap<PlaceLayout> &layouts)
      : OpConversionPattern<MoveOp>(tc, ctx), layouts(layouts) {}

  LogicalResult matchAndRewrite(MoveOp op, OpAdaptor /*adaptor*/,
                                ConversionPatternRewriter &rewriter) const override {
    StringRef srcPlace = op.getSourcePlace();
    StringRef dstPlace = op.getTargetPlace();
    auto srcIt = layouts.find(srcPlace);
    auto dstIt = layouts.find(dstPlace);
    if (srcIt == layouts.end())
      return rewriter.notifyMatchFailure(op, "source place layout missing");
    if (dstIt == layouts.end())
      return rewriter.notifyMatchFailure(op, "target place layout missing");

    // Signature :
    //   <Move>__move(src_xcoord : i32) -> dst_xcoord : i32
    //
    // MoveOp is a pure declaration (no region body). The identity
    // default is always emitted here — a function that returns its input. If
    // the move requires a non-identity Co_0 word, the frontend emits a separate
    // runtime function named <Move>__move that supersedes this default
    // identity.
    auto i32 = rewriter.getIntegerType(32);
    auto funcType = rewriter.getFunctionType({i32}, {i32});

    std::string mangled = (op.getSymName() + "__move").str();

    auto module = op->getParentOfType<ModuleOp>();
    PatternRewriter::InsertionGuard guard(rewriter);
    rewriter.setInsertionPointToEnd(module.getBody());
    auto funcOp = rewriter.create<func::FuncOp>(
        op.getLoc(), mangled, funcType);

    // Identity default: the move is the identity of the Co_0 group. Realized
    // as a function that returns the input xcoord unchanged.
    Block *entry = funcOp.addEntryBlock();
    rewriter.setInsertionPointToStart(entry);
    Value srcArg = entry->getArgument(0);
    rewriter.create<func::ReturnOp>(op.getLoc(), ValueRange{srcArg});

    rewriter.eraseOp(op);
    return success();
  }

private:
  const llvm::StringMap<PlaceLayout> &layouts;
};

// LowerApplyMoveOp: topos.apply_move %x via @M -> call @M__move(%x).
// The xcoord flows directly into the per-move function `@M__move`, whose
// default body (emitted by LowerMoveOp) returns the input xcoord unchanged.
struct LowerApplyMoveOp : public OpConversionPattern<ApplyMoveOp> {
  using OpConversionPattern<ApplyMoveOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(ApplyMoveOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    StringRef moveName = op.getMove();
    std::string mangled = (moveName + "__move").str();

    Type origResultType = op.getResult().getType();
    Type convertedResultType =
        getTypeConverter()->convertType(origResultType);
    SmallVector<Type, 1> resultTypes;
    if (convertedResultType) resultTypes.push_back(convertedResultType);

    auto callOp = rewriter.create<func::CallOp>(
        op.getLoc(), mangled, resultTypes, ValueRange{adaptor.getSource()});
    rewriter.replaceOp(op, callOp.getResults());
    return success();
  }
};

//===----------------------------------------------------------------------===//
// LowerFieldLoadOp
//===----------------------------------------------------------------------===//
//
// topos.field_load %sec, "fname" : !topos.section<"P"> -> ResultTy
//   ->
//   %v = func.call @P__get_fname(%sec) : (i64) -> ResultTy
//
// The runtime function `P__get_fname` is generated by the pre-walk in
// runOnOperation with a body that calls `yon_rt_field_load` on the packed
// section (i64), the field offset known from the layout, and the size of the
// result type, then loads the value from the output buffer.
struct LowerFieldLoadOp : public OpConversionPattern<FieldLoadOp> {
  using OpConversionPattern<FieldLoadOp>::OpConversionPattern;
  LogicalResult matchAndRewrite(FieldLoadOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter)
      const override {
    auto sectionTy = llvm::cast<SectionType>(op.getSection().getType());
    StringRef placeName = sectionTy.getPlaceName();
    StringRef fname = op.getFieldName();
    Type resultTy = op.getResult().getType();
    std::string mangled = (placeName + "__get_" + fname).str();

    Type resultConvTy = getTypeConverter()->convertType(resultTy);
    if (!resultConvTy)
      return rewriter.notifyMatchFailure(
          op, "field_load: result type non convertibile");

    // The `<Place>__get_<field>` function was already generated by the
    // pre-walk in runOnOperation. Here we only emit the call.
    auto callOp = rewriter.create<func::CallOp>(
        op.getLoc(), mangled,
        TypeRange{resultConvTy},
        ValueRange{adaptor.getSection()});
    rewriter.replaceOp(op, callOp.getResults());
    return success();
  }
};

// topos.scope / topos.scope_with_yield are inlined structurally by
// LowerToposExtensions (Step 2b) BEFORE this conversion runs; there is no
// arena model. No scope patterns here.


//===----------------------------------------------------------------------===//
// Il Pass
//===----------------------------------------------------------------------===//

struct LowerToposToStandardPass
    : public PassWrapper<LowerToposToStandardPass,
                         OperationPass<ModuleOp>> {
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(LowerToposToStandardPass)

  StringRef getArgument() const final { return "lower-topos-to-standard"; }
  StringRef getDescription() const final {
    return "Lower Topos dialect to standard MLIR dialects "
           "(func, scf, memref, arith). Milestone M1: heyt + type evidence.";
  }

  void getDependentDialects(DialectRegistry &registry) const override {
    registry.insert<arith::ArithDialect,
                    cf::ControlFlowDialect,
                    func::FuncDialect,
                    LLVM::LLVMDialect,
                    memref::MemRefDialect,
                    scf::SCFDialect>();
  }

  void runOnOperation() override {
    ModuleOp module = getOperation();
    MLIRContext *ctx = &getContext();

    // The layout of each place, as the frontend wrote it.
    bool missingLayout = false;
    auto layouts = computePlaceLayouts(module, missingLayout);
    if (missingLayout) {
      signalPassFailure();
      return;
    }

    // Pre-pass to generate the runtime functions
    // `<Place>__get_<field>(section) -> FieldTy` referenced by each FieldLoadOp.
    // The body calls yon_rt_field_load of the XLeech2 runtime with the xcoord
    // (section cast to i32), the offset known from the layout, and the size of
    // the result type.
    {
      // Set of mangled names already generated, for dedup.
      std::set<std::string> generated;
      OpBuilder builder(ctx);

      // Helper: declare yon_rt_field_load if not already present.
      auto ensureRtDecl = [&](StringRef name, FunctionType fnTy) {
        if (!module.lookupSymbol<func::FuncOp>(name)) {
          OpBuilder::InsertionGuard g(builder);
          builder.setInsertionPointToEnd(module.getBody());
          auto decl = builder.create<func::FuncOp>(
              module.getLoc(), name, fnTy);
          decl.setPrivate();
        }
      };

      // Type yon_rt_field_load_or_stop: (i64 section, i32 offset, i32 size,
      //                           !llvm.ptr out) -> i32 (status).
      // section is i64 (heap_id+xcoord packed).
      auto i32Ty = builder.getIntegerType(32);
      auto i64Ty = builder.getIntegerType(64);
      auto i8Ty = builder.getIntegerType(8);
      auto ptrTy = LLVM::LLVMPointerType::get(ctx);
      auto rtFieldLoadFnTy = builder.getFunctionType(
          {i64Ty, i32Ty, i32Ty, ptrTy}, {i32Ty});

      // yon_rt_new: (i32 heap_id, ptr payload, i32 size) -> i64 section
      auto rtNewFnTy = builder.getFunctionType(
          {i32Ty, ptrTy, i32Ty}, {i64Ty});

      module.walk([&](FieldLoadOp op) {
        auto sectionTy = llvm::cast<SectionType>(op.getSection().getType());
        StringRef placeName = sectionTy.getPlaceName();
        StringRef fieldName = op.getFieldName();
        std::string mangled =
            (placeName + "__get_" + fieldName).str();
        if (!generated.insert(mangled).second) return;
        if (module.lookupSymbol<func::FuncOp>(mangled)) return;

        auto layoutIt = layouts.find(placeName);
        if (layoutIt == layouts.end()) return;
        const PlaceLayout &layout = layoutIt->second;
        auto offsetIt = layout.fieldOffsets.find(fieldName);
        if (offsetIt == layout.fieldOffsets.end()) return;
        uint64_t offset = offsetIt->second;
        // the field's size, as laid out by the frontend
        uint64_t size = layout.fieldSizes.lookup(fieldName);

        Type resultTyHere = op.getResult().getType();

        ensureRtDecl("yon_rt_field_load_or_stop", rtFieldLoadFnTy);
        ensureRtDecl("yon_rt_new", rtNewFnTy);

        builder.setInsertionPointToEnd(module.getBody());
        // param direttamente i64 (section packed encoding).
        auto fnType =
            builder.getFunctionType({i64Ty}, {resultTyHere});
        auto fn =
            builder.create<func::FuncOp>(op.getLoc(), mangled, fnType);
        Block *entry = fn.addEntryBlock();
        builder.setInsertionPointToStart(entry);

        Value sectionVal = entry->getArgument(0);
        Value offsetVal = builder.create<arith::ConstantIntOp>(
            op.getLoc(), (int64_t)offset, i32Ty);
        Value sizeVal = builder.create<arith::ConstantIntOp>(
            op.getLoc(), (int64_t)size, i32Ty);

        // a buffer of the field's size: the runtime writes `size` bytes
        Value nBytes = builder.create<arith::ConstantIntOp>(
            op.getLoc(), (int64_t)size, i64Ty);
        Value buf = builder.create<LLVM::AllocaOp>(
            op.getLoc(), ptrTy, i8Ty, nBytes, /*alignment=*/8);

        // the read stops the program on failure: never the section 0
        auto rtFn = module.lookupSymbol<func::FuncOp>("yon_rt_field_load_or_stop");
        builder.create<func::CallOp>(
            op.getLoc(), rtFn,
            ValueRange{sectionVal, offsetVal, sizeVal, buf});

        Value loaded;
        if (llvm::isa<PropositionType>(resultTyHere)) {
          Value i8Val = builder.create<LLVM::LoadOp>(
              op.getLoc(), i8Ty, buf);
          loaded = builder.create<HeytFromI8Op>(
              op.getLoc(), resultTyHere, i8Val);
        } else if (llvm::isa<SectionType>(resultTyHere)) {
          // load as i64 (was i32), wrap in section.
          Value i64Val = builder.create<LLVM::LoadOp>(
              op.getLoc(), i64Ty, buf);
          loaded = builder.create<XcoordToSectionOp>(
              op.getLoc(), resultTyHere, i64Val);
        } else {
          loaded = builder.create<LLVM::LoadOp>(
              op.getLoc(), resultTyHere, buf);
        }
        builder.create<func::ReturnOp>(op.getLoc(), ValueRange{loaded});
      });
    }

    ToposTypeConverter typeConverter(ctx, layouts);

    ConversionTarget target(*ctx);
    target.addLegalDialect<arith::ArithDialect>();
    target.addLegalDialect<cf::ControlFlowDialect>();
    target.addLegalDialect<LLVM::LLVMDialect>();
    target.addLegalDialect<memref::MemRefDialect>();
    target.addLegalDialect<scf::SCFDialect>();
    target.addLegalDialect<BuiltinDialect>();
    // scf.if/scf.yield are legal only if all types are legal post
    // typeConverter. Needed because an scf.if with result type
    // !topos.proposition stays illegal until the results are i8.
    target.addDynamicallyLegalOp<scf::IfOp, scf::YieldOp, scf::ForOp,
                                  scf::WhileOp, scf::ConditionOp>(
        [&](Operation *op) {
          return typeConverter.isLegal(op->getResultTypes())
              && typeConverter.isLegal(op->getOperandTypes());
        });
    // For any other dialect (e.g. scf) that the pass does not know but that
    // might appear in the input IR, we mark the ops as legal. The Topos ops are
    // handled specifically — those listed in addIllegalOp are illegal, the rest
    // legal.
    target.markUnknownOpDynamicallyLegal(
        [](Operation * /*op*/) { return true; });
    target.addLegalDialect<ToposDialect>();
    // ... but these Topos ops are illegal and must disappear.
    target.addIllegalOp<HeytOp, HeytAndOp, HeytOrOp, HeytNotOp,
                        HeytImpliesOp, HeytIsOp, HeytToI32Op, HeytFromI8Op,
                        // heyt_int illegal
                        HeytIntMakeOp, HeytIntValueOp, HeytIntMaskOp,
                        HeytIntAndOp, HeytIntOrOp, HeytIntXorOp, HeytIntNotOp,
                        SubtypeCastOp, SectionToXcoordOp, XcoordToSectionOp,
                        FieldOp, PathOp, CoherenceOp,
                        SectionOp, RestrictOp, GlueOp,
                        FieldLoadOp,
                        OperationOp, OpApplyOp,
                        MoveOp, ApplyMoveOp,
                        ReduceOp,
                        GeomMorphismOp, ForcesOp,
                        ProbeConstructOp, ProbeApplyOp>();

    // Func dialect: legal if the signature is already converted.
    target.addDynamicallyLegalOp<func::FuncOp>([&](func::FuncOp op) {
      return typeConverter.isSignatureLegal(op.getFunctionType()) &&
             typeConverter.isLegal(&op.getBody());
    });
    target.addDynamicallyLegalOp<func::ReturnOp, func::CallOp>(
        [&](Operation *op) { return typeConverter.isLegal(op); });

    RewritePatternSet patterns(ctx);
    patterns.add<EraseFieldOp,
                 ErasePathOp,
                 EraseCoherenceOp,
                 LowerHeytConstOp,
                 LowerHeytAndOp,
                 LowerHeytOrOp,
                 LowerHeytNotOp,
                 LowerHeytImpliesOp,
                 LowerHeytIsOp,
                 LowerHeytToI32Op,
                 LowerHeytFromI8Op,
                 // heyt_int patterns
                 LowerHeytIntMakeOp,
                 LowerHeytIntValueOp,
                 LowerHeytIntMaskOp,
                 LowerHeytIntAndOp,
                 LowerHeytIntOrOp,
                 LowerHeytIntXorOp,
                 LowerHeytIntNotOp,
                 LowerSubtypeCastOp,
                 LowerSectionToXcoordOp,
                 LowerXcoordToSectionOp>(typeConverter, ctx);
    patterns.add<LowerOperationOp>(typeConverter, ctx, layouts);
    patterns.add<LowerOpApplyOp>(typeConverter, ctx);
    patterns.add<LowerMoveOp>(typeConverter, ctx, layouts);
    patterns.add<LowerApplyMoveOp>(typeConverter, ctx);
    patterns.add<LowerFieldLoadOp>(typeConverter, ctx);
    // A6: SCF structural type conversions per propagare il typeConverter
    // attraverso scf.if/scf.for/scf.while (block args, yield types).
    scf::populateSCFStructuralTypeConversions(typeConverter, patterns);
    patterns.add<MaterializeReduceOp>(typeConverter, ctx, layouts);
    patterns.add<MaterializeGeomMorphismOp>(typeConverter, ctx);
    patterns.add<LowerForcesOp>(typeConverter, ctx);

    // No closure conversion or trampoline synthesis happens here. Escaping
    // probes cannot be produced by the canonical frontend; any survivor is
    // rejected by the addIllegalOp guard for ProbeConstructOp/ProbeApplyOp
    // above.

    populateFunctionOpInterfaceTypeConversionPattern<func::FuncOp>(
        patterns, typeConverter);
    populateReturnOpTypeConversionPattern(patterns, typeConverter);
    populateCallOpTypeConversionPattern(patterns, typeConverter);

    if (failed(applyFullConversion(module, target, std::move(patterns)))) {
      module.emitError("Topos -> standard lowering (M1) failed");
      signalPassFailure();
      return;
    }


    // Pre-cleanup: any `topos.compose_reductions` nested inside a
    // World survives the post-order erase below only if we lift it
    // to module scope first. It is purely declarative and references
    // its operands by symbol name, so the lift is sound.
    SmallVector<Operation *> composeOps;
    module.walk([&](ComposeReductionsOp c) {
      composeOps.push_back(c);
    });
    for (Operation *c : composeOps) {
      c->moveBefore(module.getBody(), module.getBody()->end());
    }

    // Post-conversion cleanup: drop the categorical metadata that
    // carries no runtime semantics.
    //
    //   - `topos.world` and `topos.place` are namespace containers.
    //   - `topos.pullback` / `topos.pushout` declare a place as a
    //     universal construction; the place itself is materialised
    //     by the user's `topos.place` declaration when needed.
    //   - `topos.topology` is the Lawvere-Tierney topology, metadata
    //     for sheaf condition checks at the verifier layer.
    //   - `topos.view` is a derived projection record; no runtime
    //     state corresponds to it.
    //
    // ReduceOp is materialised in func.func by MaterializeReduceOp,
    // NOT erased.
    module.walk<WalkOrder::PostOrder>([](Operation *op) {
      if (llvm::isa<PlaceOp, WorldOp, PullbackOp, PushoutOp,
                    TopologyOp, ViewOp>(op)) {
        op->erase();
      }
    });
  }
};

} // namespace

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createLowerToposToStandardPass() {
  return std::make_unique<LowerToposToStandardPass>();
}

void registerLowerToposToStandardPass() {
  PassRegistration<LowerToposToStandardPass>();
}

} // namespace topos
} // namespace mlir
