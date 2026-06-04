//===- TopOps.td - Yon Topos dialect operations -----------*- tablegen -*-===//
//
// This file is part of the Yon project.
//
// TableGen specification of the Topos MLIR dialect.
//
// The Topos dialect is high-level: each operation is faithful to a construct
// of the Yon language (place, move, reduction, geometric morphism, cell,
// topology, forces, ...). The optimizations that collapse these structures
// toward native code happen in the lowering passes, not at the emit level.
//
// Memory representation: inhabitants follow the Yoneda representation, that is,
// each object is represented by its family of probes (maps from T to the
// object). The dialect operations manipulate these probes structurally.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_OPS
#define TOPOS_OPS

include "mlir/IR/OpBase.td"
include "mlir/IR/AttrTypeBase.td"
include "mlir/IR/BuiltinAttributes.td"
include "mlir/IR/EnumAttr.td"
include "mlir/IR/SymbolInterfaces.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/Interfaces/InferTypeOpInterface.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"

//===----------------------------------------------------------------------===//
// Dialect definition
//===----------------------------------------------------------------------===//

def Topos_Dialect : Dialect {
  let name = "topos";
  let cppNamespace = "::mlir::topos";
  let summary = "High-level Yon constructs as first-class MLIR operations";
  let description = [{
    The Topos dialect exposes Yon's categorical structures as first-class MLIR
    operations:

      - world : a category object (a Grothendieck site)
      - place : an object of a world
      - cell  : cellular generators of arbitrary dimension
      - move  : a morphism between places
      - reduction : geometric morphism con direzione e politica
      - geom_morphism : a formal morphism between topoi
      - topology : Lawvere-Tierney topology
      - forces  : Kripke-Joyal forcing

    Memory representation: Yoneda-rep. Each inhabitant of a place P is
    represented as a collection of probes `T -> P`, that is, incoming
    morphisms. Operations like `topos.field_get` or `topos.op_apply` are probe
    applications.

    Tutti i dati attraversano i boundary di chiamata via copy-on-call +
    borrow read-only; mutazioni esplicite richiedono `topos.promote`.
  }];

  let useDefaultTypePrinterParser = 1;
  let useDefaultAttributePrinterParser = 0;
  let usePropertiesForAttributes = 0;
  let hasOperationAttrVerify = 1;
}

//===----------------------------------------------------------------------===//
// Type definitions
//===----------------------------------------------------------------------===//

class Topos_Type<string name, string typeMnemonic, list<Trait> traits = []>
    : TypeDef<Topos_Dialect, name, traits> {
  let mnemonic = typeMnemonic;
}

// !topos.world<"Region">
// Represents the Grothendieck site "Region". An abstract type, used
// as a parameter of operations that declare place, move, ...
def Topos_WorldType : Topos_Type<"World", "world"> {
  let summary = "A Grothendieck site (Yon world)";
  let parameters = (ins StringRefParameter<"world name">:$name);
  let assemblyFormat = "`<` $name `>`";
}

// !topos.place<"Account", "Region">
// Rappresenta il place "Account" in world "Region". Tipo di un
// inhabitant del place.
def Topos_PlaceType : Topos_Type<"Place", "place"> {
  let summary = "An object of a Yon world (a place)";
  let parameters = (ins
    StringRefParameter<"place name">:$name,
    StringRefParameter<"world name">:$world
  );
  let assemblyFormat = "`<` $name `,` $world `>`";
}

// !topos.section<"Order">
// Global section of a sheaf (a place evaluated in a world). Used for
// materialized inhabitants not yet located in a Space.
def Topos_SectionType : Topos_Type<"Section", "section"> {
  let summary = "A global section of a sheaf (materialized inhabitant)";
  let parameters = (ins
    StringRefParameter<"place name">:$placeName
  );
  let assemblyFormat = "`<` $placeName `>`";
}

// !topos.probe<src_type, dst_type>
// Categorical probe (morphism) from src to dst. Elementary Yoneda-rep.
def Topos_ProbeType : Topos_Type<"Probe", "probe"> {
  let summary = "Yoneda probe (a categorical morphism T -> X)";
  let parameters = (ins
    "::mlir::Type":$srcType,
    "::mlir::Type":$dstType
  );
  let assemblyFormat = "`<` $srcType `->` $dstType `>`";
}

// !topos.cell<dim, "name">
// Cell of dimension `dim` with a canonical name.
def Topos_CellType : Topos_Type<"Cell", "cell"> {
  let summary = "A k-cell of an (infinity,1)-category attached to a place";
  let parameters = (ins
    "unsigned":$dimension,
    StringRefParameter<"cell name">:$name
  );
  let assemblyFormat = "`<` $dimension `,` $name `>`";
}

// !topos.proposition
// Subobject classifier Omega. Heyting tri-value: true / false / unknown.
def Topos_PropositionType : Topos_Type<"Proposition", "proposition"> {
  let summary = "Subobject classifier (Omega) with Heyting tri-value";
}

// !topos.heyt_int<N>
// Heyt-int parametrico su N trit.
// Each trit is {Present, Absent, Unknown}.
// Rappresentazione runtime: tuple<i64, i64> = (value, mask).
//   value[i] = il bit "se Present allora 1 altrimenti 0"
//   mask[i]  = 1 if trit i is Unknown, 0 otherwise
// Constraint: 1 <= N <= 64.
def Topos_HeytIntType : Topos_Type<"HeytInt", "heyt_int"> {
  let summary = "Heyting-valued integer with N trits {Present, Absent, Unknown}";
  let parameters = (ins
    "unsigned":$numTrits
  );
  let assemblyFormat = "`<` $numTrits `>`";
}

//===----------------------------------------------------------------------===//
// Attribute definitions
//===----------------------------------------------------------------------===//

class Topos_Attr<string name, string attrMnemonic, list<Trait> traits = []>
    : AttrDef<Topos_Dialect, name, traits> {
  let mnemonic = attrMnemonic;
}

// Direction di una reduction.
def Topos_ReductionDirection : I32EnumAttr<
    "ReductionDirection", "Direction of a reduction (geometric morphism)",
    [
      I32EnumAttrCase<"Forward",  0, "forward">,
      I32EnumAttrCase<"Backward", 1, "backward">,
      I32EnumAttrCase<"Bi",       2, "bi">
    ]> {
  let cppNamespace = "::mlir::topos";
}

// Policy distribuita di una reduction.
def Topos_ReductionPolicy : I32EnumAttr<
    "ReductionPolicy", "Distributed materialization policy",
    [
      I32EnumAttrCase<"Direct",          0, "direct">,
      I32EnumAttrCase<"Sharded",         1, "sharded">,
      I32EnumAttrCase<"ReplicatedPaxos", 2, "paxos">,
      I32EnumAttrCase<"EventualCRDT",    3, "crdt">
    ]> {
  let cppNamespace = "::mlir::topos";
}

// Effect ordering per multi-shot reductions.
def Topos_ShotOrdering : I32EnumAttr<
    "ShotOrdering", "Ordering of multi-shot effects",
    [
      I32EnumAttrCase<"Sequential", 0, "sequential">,
      I32EnumAttrCase<"Parallel",   1, "parallel">,
      I32EnumAttrCase<"ByPriority", 2, "by_priority">
    ]> {
  let cppNamespace = "::mlir::topos";
}

// Valore Heyting tri-valued di una proposition.
def Topos_HeytingValue : I32EnumAttr<
    "HeytingValue", "Heyting tri-valued logic constant",
    [
      I32EnumAttrCase<"True",    0, "true">,
      I32EnumAttrCase<"False",   1, "false">,
      I32EnumAttrCase<"Unknown", 2, "unknown">
    ]> {
  let cppNamespace = "::mlir::topos";
}

//===----------------------------------------------------------------------===//
// Operation base class
//===----------------------------------------------------------------------===//

class Topos_Op<string mnemonic, list<Trait> traits = []>
    : Op<Topos_Dialect, mnemonic, traits>;

//===----------------------------------------------------------------------===//
// World, place, section operations
//===----------------------------------------------------------------------===//

// topos.world @name { ... }
// Dichiara un Grothendieck site con i suoi place interni.
// Has the Symbol trait to be referenced by name from other operations.
def Topos_WorldOp : Topos_Op<"world", [
    IsolatedFromAbove,
    Symbol,
    SymbolTable,
    NoTerminator
  ]> {
  let summary = "Declare a Yon world (Grothendieck site)";
  let description = [{
    Definisce un world Yon come container di place, move, reduction.
    L'attributo `sym_name` rende il world referenziabile come simbolo.

    Optional attributes per costruzioni universali:
      - `product_of` : array di world names; prodotto cartesiano
      - `coproduct_of` : array di world names; coproduct
      - `quotient_of` : (world, relation); quoziente
      - `subset_of` : world; sub-world (inclusione sub-topos)
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    OptionalAttr<StrArrayAttr>:$product_of,
    OptionalAttr<StrArrayAttr>:$coproduct_of,
    OptionalAttr<StrAttr>:$quotient_of_world,
    OptionalAttr<StrAttr>:$quotient_relation,
    OptionalAttr<StrAttr>:$subset_of
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = "$sym_name attr-dict-with-keyword $body";
}

// topos.place @name in @world { ... }
// Declares a place inside a world. The body contains field, op, cell.
def Topos_PlaceOp : Topos_Op<"place", [
    Symbol,
    SymbolTable,
    NoTerminator,
    HasParent<"WorldOp">
  ]> {
  let summary = "Declare a place in a Yon world";
  let description = [{
    Defines a place as an object of a world. The body contains:
      - `topos.field` : 0-cells (field implicito)
      - `topos.operation` : 1-cells (operation implicita)
      - `topos.cell` : k-cells custom (k >= 1)

    Optional attributes:
      - `with_effects` : il place ammette operation (1-cells)
      - `over` : name of the base place (slice category C/X)
      - `qualifier` : "dogma" | "relational" | "term" (default "term").
                       Restricts the place to one of the three categories
                       associated with the type theory (Lambek-Scott Part II
                       ch. 11): D(L) "dogma" = pure type judgments only;
                       A(L) "relational" = adds propositions (Omega);
                       T(L) "term" = full, with term-forming ops.
                       Verifier in `[TOPOS-E0960..E0962]`.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world,
    UnitAttr:$with_effects,
    OptionalAttr<FlatSymbolRefAttr>:$over,
    OptionalAttr<StrAttr>:$coeffect_algebra,
    OptionalAttr<StrAttr>:$qualifier
  );
  let regions = (region SizedRegion<1>:$body);  // exactly 1 block (possibly empty: terminal object 1)
  let assemblyFormat = [{
    $sym_name `in` $world attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

// topos.field @name : !type
// Dichiara un field (0-cell) di un place.
def Topos_FieldOp : Topos_Op<"field", [
    Symbol,
    HasParent<"PlaceOp">
  ]> {
  let summary = "Declare a field of a place (a 0-cell)";
  let description = [{
    A field is a 0-cell of the place, that is, a passive observation
    sull'instance. L'attributo `is_private` marca un
    field as representation-hidden: its type may not appear
    nei result type delle OperationOp pubbliche del place.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    TypeAttr:$field_type,
    UnitAttr:$is_private
  );
  let assemblyFormat = "$sym_name `:` $field_type attr-dict";
}

// topos.operation @name(args) -> result
// Dichiara un'operation (1-cell) di un place.
def Topos_OperationOp : Topos_Op<"operation", [
    Symbol,
    NoTerminator,
    HasParent<"PlaceOp">
  ]> {
  let summary = "Declare an operation of a place (a 1-cell)";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    TypeArrayAttr:$arg_types,
    TypeAttr:$result_type,
    UnitAttr:$functorial
  );
  let regions = (region AnyRegion:$body);
  let assemblyFormat = [{
    $sym_name `(` $arg_types `)` `->` $result_type attr-dict-with-keyword $body
  }];
}

// topos.cell<dim> @name from @src to @tgt
// Dichiara una cell custom di dimensione `dim`.
def Topos_CellOp : Topos_Op<"cell", [
    Symbol,
    HasParent<"PlaceOp">
  ]> {
  let summary = "Declare a custom k-cell (path constructor or higher)";
  let description = [{
    Custom cell for HIT, suspension, path constructor.
    Example S^1:
      topos.cell<1> @loop from @base to @base

    The optional `n_connective_lvl` attribute: if present,
    declares the level n of n-connectivity of the cell. The cell must
    be "n-connective", that is, have trivial homotopy groups up to level n.
    For dimension k, we need n >= k (otherwise the cell cannot exist as a
    k-cell in an n-connected space).
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    I32Attr:$dimension,
    FlatSymbolRefAttr:$source,
    FlatSymbolRefAttr:$target,
    OptionalAttr<I32Attr>:$n_connective_lvl
  );
  let assemblyFormat = [{
    `<` $dimension `>` $sym_name `from` $source `to` $target attr-dict
  }];
  let hasVerifier = 1;
}

// topos.section %v : !topos.place<...>
// Materializes an inhabitant of a place as a global section.
def Topos_SectionOp : Topos_Op<"section", [Pure]> {
  let summary = "Materialize a global section (an inhabitant)";
  let arguments = (ins
    FlatSymbolRefAttr:$place,
    Variadic<AnyType>:$field_values
  );
  let results = (outs Topos_SectionType:$result);
  let assemblyFormat = [{
    $place `(` $field_values `)` `:` functional-type(operands, results) attr-dict
  }];
}

//===----------------------------------------------------------------------===//
// Restrict, glue, move operations
//===----------------------------------------------------------------------===//

// topos.restrict %section to @subplace
// Restricts a global section to a sub-place. f^* in the category.
def Topos_RestrictOp : Topos_Op<"restrict", [Pure]> {
  let summary = "Restrict a section to a subobject (pullback / f^*)";
  let arguments = (ins
    Topos_SectionType:$source,
    FlatSymbolRefAttr:$subplace
  );
  let results = (outs Topos_SectionType:$result);
  let assemblyFormat = [{
    $source `to` $subplace `:` functional-type(operands, results) attr-dict
  }];
}

// topos.field_load %section, "field_name" : !topos.section<"P"> -> ResultTy
//
// Reads the value of a named field from a section. It is the operational
// realization of `obj.field` in the Yon surface syntax.
//
// Lowering: materialized as a call to a runtime function
// `<Place>__get_<field>(section_ptr) -> FieldTy` generated by the downstream
// lowering. The runtime function defaults to identity-zero (returns 0 for
// number, false for boolean, etc.) until cross-space access is closed; with
// the XLeech2 backend active, the runtime function is replaced via symbol
// resolution.
//
// Verifier: the referenced place must exist and have a field with the given
// name; the field type must match the result type.
// topos.subtype_cast %sub : section<Sub> to section<Super>
// Logical cast between compatible place section types (width subtyping).
// Sub <: Super if Sub has all of Super's fields (and possibly more).
// Operationally identity: the runtime does not distinguish, the physical
// structure is compatible by the layout invariant.
//
// Minimal verifier: source and target must be SectionType. The true width
// compatibility is enforced by the frontend type checker.
def Topos_SubtypeCastOp : Topos_Op<"subtype_cast", [Pure]> {
  let summary = "Cast a section to a supertype (width subtyping)";
  let arguments = (ins Topos_SectionType:$source);
  let results = (outs Topos_SectionType:$result);
  let assemblyFormat = "$source attr-dict `:` type($source) `to` type($result)";
}

def Topos_FieldLoadOp : Topos_Op<"field_load", [Pure]> {
  let summary = "Load the value of a named field from a section";
  let description = [{
    Reads the value of a declared field from a section. The result
    type must match the declared type of the field in the place
    declaration. Verifier: [TOPOS-E1020]..[TOPOS-E1022].
  }];
  let arguments = (ins
    Topos_SectionType:$section,
    StrAttr:$field_name
  );
  let results = (outs AnyType:$result);
  let assemblyFormat = [{
    $section `,` $field_name `:` type($section) `->` type($result) attr-dict
  }];
  let hasVerifier = 1;
}

// topos.glue %sections... over @covering
// Glue local sections into a global one. Sheaf condition.
def Topos_GlueOp : Topos_Op<"glue", [Pure]> {
  let summary = "Glue local sections into a global one (sheaf condition)";
  let description = [{
    Given local sections compatible on a covering, builds the unique global
    section by the sheaf descent principle. The verifier checks that the
    sections are compatible on the intersections.
  }];
  let arguments = (ins
    Variadic<Topos_SectionType>:$local_sections,
    FlatSymbolRefAttr:$covering
  );
  let results = (outs Topos_SectionType:$result);
  let assemblyFormat = [{
    $local_sections `over` $covering `:` functional-type(operands, results)
    attr-dict
  }];
}

// topos.move @sym_name from @source to @target
//   [attributes { policy = [...] }]
//
// Declares a morphism (a pure declaration) between two places. A move is a
// categorical entity: it has no computational "body" nor inline code. Complex
// moves (a non-identity Co_0 word) are expressed as a MoveOp plus a separate
// runtime function associated via symbol lookup. For now each move is
// implemented as identity, and the declaration suffices.
def Topos_MoveOp : Topos_Op<"move", [Symbol]> {
  let summary = "Declare a move (morphism between places)";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$source_place,
    FlatSymbolRefAttr:$target_place,
    OptionalAttr<StrArrayAttr>:$policy
  );
  let assemblyFormat = [{
    $sym_name `from` $source_place `to` $target_place attr-dict-with-keyword
  }];
  let hasVerifier = 1;
}

// topos.apply_move @move %src : !src_type -> !dst_type
// Applies a move to a concrete section.
def Topos_ApplyMoveOp : Topos_Op<"apply_move", [Pure]> {
  let summary = "Apply a declared move to a concrete section";
  let arguments = (ins
    FlatSymbolRefAttr:$move,
    Topos_SectionType:$source
  );
  let results = (outs Topos_SectionType:$result);
  let assemblyFormat = [{
    $move $source `:` functional-type(operands, results) attr-dict
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// View, reduce, scope operations
//===----------------------------------------------------------------------===//

// topos.view @name on @place { ... }
// Proiezione/vista derivata di un place. Body contiene show items.
def Topos_ViewOp : Topos_Op<"view", [
    Symbol,
    NoTerminator
  ]> {
  let summary = "Declare a view (derived projection) of a place";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$on_place
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $sym_name `on` $on_place attr-dict-with-keyword $body
  }];
}

// topos.reduce @name of @place { on op: ... }
// Dichiara una reduction (geometric morphism con politica).
def Topos_ReduceOp : Topos_Op<"reduce", [
    Symbol,
    NoTerminator
  ]> {
  let summary = "Declare a reduction (geometric morphism with policy)";
  let description = [{
    A reduction is a geometric morphism from the place to another
    place (target implicito) o verso una semantica concreta.

    Attributi:
      - `direction` : forward / backward / bi
      - `policy` : direct / sharded / paxos / crdt
      - `lawful` : richiede left-exactness check
      - `invertible` : richiede check di equivalenza (univalence)
      - `multi_shot` + `shot_ordering` : multi-handler con ordering
      - `type_params` : reduction polimorfica
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$of_place,
    Topos_ReductionDirection:$direction,
    Topos_ReductionPolicy:$policy,
    Topos_ShotOrdering:$shot_ordering,
    UnitAttr:$lawful,
    UnitAttr:$invertible,
    UnitAttr:$multi_shot,
    UnitAttr:$coeffect_preserving,
    OptionalAttr<StrArrayAttr>:$type_params
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $sym_name `of` $of_place attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

// topos.compose_reductions @result = @left . @right
// Explicit composition of two reductions.
def Topos_ComposeReductionsOp : Topos_Op<"compose_reductions", [Pure]> {
  let summary = "Explicit composition of two reductions";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$left,
    FlatSymbolRefAttr:$right
  );
  let assemblyFormat = [{
    $sym_name `=` $left `compose` $right attr-dict
  }];
}

// topos.scope (captures...) { ^bb0(%cap0, %cap1, ...): ... }
//
// Opens a Space (a dedicated region/arena allocator). Optional captures allow
// passing SSA values from the enclosing context into the hermetic scope body,
// as block arguments. This works around the IsolatedFromAbove constraint
// explicitly: each passed value must be declared as a capture, not referred to
// implicitly.
//
// Closure conversion (Tortoise ch. 17.10): a MoveOp/ScopeOp with free
// variables in the body is turned into a scope with explicit captures that
// receive those variables.
def Topos_ScopeOp : Topos_Op<"scope", [
    IsolatedFromAbove,
    NoTerminator,
    SingleBlock
  ]> {
  let summary = "Open a Yon Space (hermetic arena region)";
  let description = [{
    Creates a new hermetic Space. All allocations inside the body happen in
    this Space's arena. When the body ends, the arena decays in a bulk free.

    Model: a bump-pointer arena. No cross-Space refs by construction.

    Trait IsolatedFromAbove: the scope body may NOT refer to SSA values defined
    outside the scope implicitly. To pass values explicitly, use `captures`:
    each operand passed becomes a block argument of the body.

    Example:
      %a = arith.constant 42 : i32
      topos.scope (%a : i32) {
      ^bb0(%captured_a: i32):
        // here we use %captured_a, not %a
        ...
      }
  }];
  let arguments = (ins
    Variadic<AnyType>:$captures,
    OptionalAttr<StrAttr>:$debug_name
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    (`(` $captures^ `:` type($captures) `)`)?
    attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// scope with values yielded to the parent topos
//===----------------------------------------------------------------------===//
//
// `topos.scope_with_yield` opens a hermetic scope (like topos.scope) that also
// produces one or more values "promoted" to the parent topos at exit. Models:
//
//   <v>_S -> v   when v lifts to (\iota_S)_*
//
// where (\iota_S)_* is the pushforward (deep-copy to the parent arena before
// destroying the scope's arena).
//
// Trait IsolatedFromAbove + SingleBlockImplicitTerminator<"ScopeYieldOp">:
// the body is a hermetic single-block region terminated by
// `topos.scope_yield %v_1, ..., %v_n`. The yielded types must match the op's
// result types.
//
// Lowering: yon_arena_create, body inlined with the inner arena's SSA, each
// yielded value promoted (deep-copy via yon_arena_get + yon_arena_alloc) to the
// parent arena BEFORE the yon_arena_destroy of the inner arena.
def Topos_ScopeWithYieldOp : Topos_Op<"scope_with_yield", [
    IsolatedFromAbove,
    SingleBlockImplicitTerminator<"ScopeYieldOp">
  ]> {
  let summary = "Open a hermetic Space that yields values to the parent";
  let description = [{
    Version of `topos.scope` that produces values to the parent topos.

    Semantics:
      result = (\iota_S)_*(body_value)

    The yielded value must be "liftable", that is, representable in the parent
    arena. The lowering implements the lift as a deep-copy of the slot before
    destroying the inner arena.

    For probe escape, the body runs probe_construct in the scope's arena, then
    yields the probe; the lowering promotes the closure to the parent arena and
    updates the HeapRef.

    Captures: like ScopeOp, supports SSA values explicitly passed to the body as
    block arguments. Needed for closure conversion of a reduction chain where
    the intermediate values must flow between nested scopes.
  }];
  let arguments = (ins
    Variadic<AnyType>:$captures,
    OptionalAttr<StrAttr>:$debug_name
  );
  let results = (outs Variadic<AnyType>:$results);
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    (`(` $captures^ `:` type($captures) `)`)?
    (`->` qualified(type($results))^)? attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

// Terminator implicito di topos.scope_with_yield.
def Topos_ScopeYieldOp : Topos_Op<"scope_yield", [
    Pure,
    Terminator,
    HasParent<"ScopeWithYieldOp">,
    ReturnLike
  ]> {
  let summary = "Yield values from a topos.scope_with_yield region";
  let description = [{
    Implicit terminator of `topos.scope_with_yield`. The yielded values
    are promoted (deep-copy) to the parent arena at lowering.

    The number and types of the operands must match the result types of the
    enclosing scope_with_yield.
  }];
  let arguments = (ins Variadic<AnyType>:$values);
  let builders = [
    // Default builder used by SingleBlockImplicitTerminator when the
    // scope_with_yield body has no explicit terminator.
    OpBuilder<(ins), [{
      // No-op: ValueRange{} is handled automatically by Variadic.
    }]>
  ];
  let assemblyFormat = [{
    ($values^ `:` qualified(type($values)))? attr-dict
  }];
}

//===----------------------------------------------------------------------===//
// With handler, Heyting, coherence, path operations
//===----------------------------------------------------------------------===//

// topos.with_handler @reduction { ... }
// Activates a handler (reduction) for the duration of the body.
def Topos_WithHandlerOp : Topos_Op<"with_handler", [
    NoTerminator,
    SingleBlock
  ]> {
  let summary = "Install a reduction handler for the duration of a block";
  let description = [{
    Equivalent of `with R of P { ... }` in Yon surface. Pushes the handler on
    the stack (LIFO); pops at the end of the body. Operations invoked inside the
    body use this handler for the lookup.
  }];
  let arguments = (ins
    FlatSymbolRefAttr:$reduction,
    OptionalAttr<FlatSymbolRefAttr>:$of_place
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $reduction (`of` $of_place^)? attr-dict-with-keyword $body
  }];
}

// topos.op_apply @op on %instance(%args...)
// Invokes an operation of a place on an instance. Goes through the stack of
// active handlers.
def Topos_OpApplyOp : Topos_Op<"op_apply"> {
  let summary = "Apply an operation of a place on an instance";
  let arguments = (ins
    FlatSymbolRefAttr:$op_ref,
    Topos_SectionType:$instance,
    Variadic<AnyType>:$args
  );
  let results = (outs AnyType:$result);
  let assemblyFormat = [{
    $op_ref `on` $instance `(` $args `)` `:`
    functional-type(operands, results) attr-dict
  }];
  let hasVerifier = 1;
}

// topos.heyt @value
// Costante Heyting tri-valued (true / false / unknown).
def Topos_HeytOp : Topos_Op<"heyt", [Pure]> {
  let summary = "Heyting tri-valued constant";
  let arguments = (ins Topos_HeytingValue:$value);
  let results = (outs Topos_PropositionType:$result);
  let assemblyFormat = "$value attr-dict `:` type(results)";
}

// topos.heyt_and %a, %b -> %result
// Three-valued AND. Heyting truth table.
def Topos_HeytAndOp : Topos_Op<"heyt_and", [Pure, Commutative]> {
  let summary = "Heyting tri-valued AND";
  let arguments = (ins
    Topos_PropositionType:$lhs,
    Topos_PropositionType:$rhs
  );
  let results = (outs Topos_PropositionType:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type(results)";
}

// topos.heyt_or %a, %b -> %result
// Three-valued OR.
def Topos_HeytOrOp : Topos_Op<"heyt_or", [Pure, Commutative]> {
  let summary = "Heyting tri-valued OR";
  let arguments = (ins
    Topos_PropositionType:$lhs,
    Topos_PropositionType:$rhs
  );
  let results = (outs Topos_PropositionType:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type(results)";
}

// topos.heyt_not %a -> %result
// Three-valued NOT. NOT(U) = U (fixed point).
def Topos_HeytNotOp : Topos_Op<"heyt_not", [Pure]> {
  let summary = "Heyting tri-valued NOT";
  let arguments = (ins Topos_PropositionType:$operand);
  let results = (outs Topos_PropositionType:$result);
  let assemblyFormat = "$operand attr-dict `:` type(results)";
}

// topos.heyt_implies %a, %b -> %result
// IMPLIES Heyting: a -> b == NOT a OR b (definable as max(neg(a), b)
// nell'encoding scelto, ma realizzato direttamente per chiarezza).
def Topos_HeytImpliesOp : Topos_Op<"heyt_implies", [Pure]> {
  let summary = "Heyting tri-valued IMPLIES";
  let arguments = (ins
    Topos_PropositionType:$lhs,
    Topos_PropositionType:$rhs
  );
  let results = (outs Topos_PropositionType:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type(results)";
}

//===----------------------------------------------------------------------===//
// Heyt-int ops
//
// Bitwise intuizionista vero su Heyt-int<N>.
// Representation: each Heyt-int<N> has N trits, each in {P, A, U}.
// Internal encoding: tuple (value:i64, mask:i64) where
//   - value[i] = 1 iff trit i is Present (irrelevant if mask[i] = 1)
//   - mask[i]  = 1 iff trit i is Unknown
//
// Bit-by-bit Heyting tables:
//   AND: A&x=A, P&P=P, P&U=U, U&U=U
//   OR:  P|x=P, A|A=A, A|U=U, U|U=U
//   XOR: known certain bit - propagates U: U^x=U
//   NOT: flip value, mask unchanged (~P=A, ~A=P, ~U=U)
//===----------------------------------------------------------------------===//

// topos.heyt_int_make %value, %mask : !topos.heyt_int<N>
// Constructor: assembles a Heyt-int from value bits + mask bits.
def Topos_HeytIntMakeOp : Topos_Op<"heyt_int_make", [Pure]> {
  let summary = "Construct a Heyt-int from value and mask bit-vectors";
  let arguments = (ins I64:$value, I64:$mask);
  let results = (outs Topos_HeytIntType:$result);
  let assemblyFormat = "$value `,` $mask attr-dict `:` type(results)";
}

// topos.heyt_int_value %h : i64
// Proiezione: estrae il bit-vector value (interpretazione bit certi).
def Topos_HeytIntValueOp : Topos_Op<"heyt_int_value", [Pure]> {
  let summary = "Extract the value bit-vector from a Heyt-int";
  let arguments = (ins Topos_HeytIntType:$operand);
  let results = (outs I64:$result);
  let assemblyFormat = "$operand `:` type($operand) attr-dict";
}

// topos.heyt_int_mask %h : i64
// Projection: extracts the mask bit-vector (1 iff Unknown).
def Topos_HeytIntMaskOp : Topos_Op<"heyt_int_mask", [Pure]> {
  let summary = "Extract the unknown-mask bit-vector from a Heyt-int";
  let arguments = (ins Topos_HeytIntType:$operand);
  let results = (outs I64:$result);
  let assemblyFormat = "$operand `:` type($operand) attr-dict";
}

// topos.heyt_int_and %a, %b -> !topos.heyt_int<N>
// AND bit-per-bit:
//   result_value = (a.v & b.v) & ~result_mask
//   result_mask  = (a.m | b.m) & ~((a.v=0 & ~a.m) | (b.v=0 & ~b.m))
//   that is, U if both non-A; A if one is certainly A.
def Topos_HeytIntAndOp : Topos_Op<"heyt_int_and", [Pure, Commutative, SameOperandsAndResultType]> {
  let summary = "Bit-wise Heyting AND on Heyt-int";
  let arguments = (ins Topos_HeytIntType:$lhs, Topos_HeytIntType:$rhs);
  let results = (outs Topos_HeytIntType:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

// topos.heyt_int_or %a, %b -> !topos.heyt_int<N>
// OR bit-per-bit (duale di AND).
def Topos_HeytIntOrOp : Topos_Op<"heyt_int_or", [Pure, Commutative, SameOperandsAndResultType]> {
  let summary = "Bit-wise Heyting OR on Heyt-int";
  let arguments = (ins Topos_HeytIntType:$lhs, Topos_HeytIntType:$rhs);
  let results = (outs Topos_HeytIntType:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

// topos.heyt_int_xor %a, %b -> !topos.heyt_int<N>
// XOR bit-per-bit:
//   result_value = a.v ^ b.v (irrelevant where mask=1)
//   result_mask  = a.m | b.m  (U propaga in XOR)
def Topos_HeytIntXorOp : Topos_Op<"heyt_int_xor", [Pure, Commutative, SameOperandsAndResultType]> {
  let summary = "Bit-wise Heyting XOR on Heyt-int";
  let arguments = (ins Topos_HeytIntType:$lhs, Topos_HeytIntType:$rhs);
  let results = (outs Topos_HeytIntType:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type($result)";
}

// topos.heyt_int_not %a -> !topos.heyt_int<N>
// NOT bit-per-bit:
//   result_value = ~a.v
//   result_mask  = a.m   (U resta U)
def Topos_HeytIntNotOp : Topos_Op<"heyt_int_not", [Pure, SameOperandsAndResultType]> {
  let summary = "Bit-wise Heyting NOT on Heyt-int";
  let arguments = (ins Topos_HeytIntType:$operand);
  let results = (outs Topos_HeytIntType:$result);
  let assemblyFormat = "$operand attr-dict `:` type($result)";
}

// topos.section_to_xcoord %s : i64
// Extracts the underlying encoding (heap_id<<32 | xcoord) from a section.
// Cross-space: section is now i64 (packed heap_id + xcoord); the op keeps the
// historical name for syntactic compatibility.
// Identity after conversion (typeConverter maps section -> i64).
def Topos_SectionToXcoordOp : Topos_Op<"section_to_xcoord", [Pure]> {
  let summary = "Extract the underlying (heap_id, xcoord) encoding from a section";
  let arguments = (ins AnyType:$section);
  let results = (outs I64:$result);
  let assemblyFormat = "$section attr-dict `:` type($section) `to` type($result)";
}

// topos.xcoord_to_section %xc : !topos.section<"P">
// Builds a section from an i64 encoding (heap_id<<32 | xcoord).
// Identity dopo conversion.
def Topos_XcoordToSectionOp : Topos_Op<"xcoord_to_section", [Pure]> {
  let summary = "Construct a section from a raw i64 (heap_id+xcoord packed)";
  let arguments = (ins I64:$xcoord);
  let results = (outs AnyType:$result);
  let assemblyFormat = "$xcoord attr-dict `:` type($result)";
}

// topos.heyt_to_i32 %a : i32
// Canonical conversion proposition --> i32. The encoding (T=0, F=1, U=2)
// extends to i32 via zero-extension. Needed for the exit code of main when the
// function returns a proposition.
def Topos_HeytToI32Op : Topos_Op<"heyt_to_i32", [Pure]> {
  let summary = "Convert a Heyting proposition to i32 (zero-extend payload)";
  let arguments = (ins Topos_PropositionType:$value);
  let results = (outs I32:$result);
  let assemblyFormat = "$value attr-dict `:` type(results)";
}

// topos.heyt_from_i8 %a : !topos.proposition
// Inverse conversion: i8 -> proposition. Lossless: the i8 is interpreted as
// the encoding T=0, F=1, U=2 (other values are UB). Used by runtime calls that
// return i8 (e.g. yon_rt_to_prop).
def Topos_HeytFromI8Op : Topos_Op<"heyt_from_i8", [Pure]> {
  let summary = "Construct a Heyting proposition from i8 payload";
  let arguments = (ins I8:$value);
  let results = (outs Topos_PropositionType:$result);
  let assemblyFormat = "$value attr-dict `:` type(results)";
}

// topos.heyt_is %a, %b : i1
// Canonical pattern match over the 3 Heyting values. Compares two propositions
// for bit-wise equality (i.e. over the three canonical values
// True/False/Unknown). Returns i1 because the branch decision is classical even
// if the compared values are tri-valued: it is the canonical projection
// Omega -> 2.
//
// Lowering: arith.cmpi eq sul payload i8 (encoding T=0, F=1, U=2).
def Topos_HeytIsOp : Topos_Op<"heyt_is", [Pure, Commutative]> {
  let summary = "Heyting tri-valued equality (branch projection)";
  let arguments = (ins
    Topos_PropositionType:$lhs,
    Topos_PropositionType:$rhs
  );
  let results = (outs I1:$result);
  let assemblyFormat = "$lhs `,` $rhs attr-dict `:` type(results)";
}

// topos.coherence %a, %b : !type
// Coherence proof between two equivalent terms. Needed for Cubical and for
// moves that cross high-dimensional coherences.
def Topos_CoherenceOp : Topos_Op<"coherence", [Pure]> {
  let summary = "Witness of coherence between two equivalent terms";
  let arguments = (ins
    AnyType:$lhs,
    AnyType:$rhs
  );
  let results = (outs Topos_CellType:$witness);
  let assemblyFormat = [{
    $lhs `,` $rhs `:` functional-type(operands, results) attr-dict
  }];
}

// topos.path<dim> %src, %tgt : !type
// k-dimensional path between two terms. Generalizes Coherence to cells of
// arbitrary dimension.
def Topos_PathOp : Topos_Op<"path", [Pure]> {
  let summary = "A k-dimensional path between two terms";
  let arguments = (ins
    I32Attr:$dimension,
    AnyType:$source,
    AnyType:$target
  );
  let results = (outs Topos_CellType:$path);
  let assemblyFormat = [{
    `<` $dimension `>` $source `,` $target `:` functional-type(operands, results) attr-dict
  }];
}

//===----------------------------------------------------------------------===//
// P7 extended: pullback, pushout, topology, geom_morphism, forces
//===----------------------------------------------------------------------===//

// topos.pullback @name = @f, @g
// A place defined as the pullback of two morphisms.
def Topos_PullbackOp : Topos_Op<"pullback", [Symbol]> {
  let summary = "Define a place as the pullback of two morphisms";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$f,
    FlatSymbolRefAttr:$g
  );
  let assemblyFormat = "$sym_name `=` $f `,` $g attr-dict";
  let hasVerifier = 1;
}

// topos.pushout — analogously.
def Topos_PushoutOp : Topos_Op<"pushout", [Symbol]> {
  let summary = "Define a place as the pushout of two morphisms";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$f,
    FlatSymbolRefAttr:$g
  );
  let assemblyFormat = "$sym_name `=` $f `,` $g attr-dict";
  let hasVerifier = 1;
}

// topos.coproduct @name = [@P1, @P2, ..., @Pn]
//
// Defines a place as the coproduct (a categorical colimit of discrete shape)
// of N source places. Dual of `topos.product` (which in Yon is part of the
// Pullback/restrict-to-product pattern).
//
// Categorical semantics (Lurie 4.4.1):
//   - for each i in {1..N} there is a canonical injection inj_i : Pi -> coprod
//   - for each place Q and family of morphisms {f_i : Pi -> Q}, there is a
//     unique [f_1,...,f_n] : coprod -> Q such that [f_1,...,f_n] o inj_i = f_i
//   - mapping space: Map(coprod, Q) ~= prod_i Map(Pi, Q) in H
//
// Verifier (codes [TOPOS-E0950..E0951]):
//   - N >= 1 (no empty coproduct in single-Space: the true "0" will be the
//     `topos.initial`)
//   - all Pi must resolve to existing `topos.place`
//   - all Pi must belong to the same enclosing world (cross-space coproduct is
//     deferred)
//
// Lowering: currently a structural declaration (like Pullback/Pushout). The
// operational lowering will come with the place-fusion pass or with
// cross-space.
def Topos_CoproductOp : Topos_Op<"coproduct", [Symbol]> {
  let summary = "Define a place as the coproduct of N places";
  let description = [{
    `topos.coproduct @C = [@P1, @P2, ..., @Pn]` declares a place `C`
    that is the categorical coproduct of `P1..Pn`. Canonical injections
    `inj_i : Pi -> C` are implicit (not emitted as SSA values); they
    can be invoked as `topos.move inj_<C>_<i>` if needed in derived
    constructions.

    Dual of `topos.pullback` over the discrete shape on N objects.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefArrayAttr:$components
  );
  let assemblyFormat = "$sym_name `=` $components attr-dict";
  let hasVerifier = 1;
}

// topos.coequalizer @C = @f, @g over @P -> @Q  yields_move @q
//
// Given a parallel pair of morphisms `f, g : P -> Q`, declares a place `C`
// with a canonical move `q : Q -> C` such that `q o f = q o g` and universal
// (Lurie 4.4.3, Proposition 4.4.3.2).
//
// In single-space Yon, the coequalizer corresponds to the quotient of Q by the
// equivalence relation generated by `f(x) ~ g(x) for all x in P`.
//
// Verifier (codes [TOPOS-E0952..E0953]):
//   - f and g must be parallel: same source `P` and same target `Q` (a
//     structural check via symbol lookup)
//   - all objects must live in the same enclosing world
//   - the resulting move `q` is introduced as a new symbol in the world;
//     colliding with other symbols is an error
//
// Lowering: like Coproduct, currently structural. The true quotient requires a
// representation of equivalence classes that comes with the world quotient + a
// dedicated pass.
def Topos_CoequalizerOp : Topos_Op<"coequalizer", [Symbol]> {
  let summary = "Define a place as the coequalizer of two parallel morphisms";
  let description = [{
    `topos.coequalizer @C = @f, @g yields_move @q` declares a place
    `C` and a canonical quotient morphism `q : Q -> C` where `f, g : P -> Q`
    are parallel and `q o f = q o g`. Universal among all such q'.

    Dual of `topos.equalizer` (which in Yon is encoded as a particular
    `topos.pullback` of `(f, g) : P -> Q x Q` against the diagonal).
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$f,
    FlatSymbolRefAttr:$g,
    FlatSymbolRefAttr:$quotient_move
  );
  let assemblyFormat = [{
    $sym_name `=` $f `,` $g `yields_move` $quotient_move attr-dict
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// CDT Hagino layer (Hagino 1987 — A Categorical Programming Language)
//
// Yon adopts Hagino's declaration mechanism as the base categorical sub-layer.
// The hierarchy is:
//
//   topos.terminal     == right_object con N=M=0 (oggetto terminale 1)
//   topos.initial      == left_object  con N=M=0 (oggetto iniziale 0)
//   topos.right_object == declaration generale di right object
//                          (constructors = factorizer, destructors = nat_trans)
//   topos.left_object  == declaration generale di left object
//                          (constructors = nat_trans, destructors = factorizer)
//   topos.exponential  == right_object con factorizer `curry` e nat_trans `eval`
//   topos.bang         == canonical move A -> 1 (for every A)
//   topos.absurd       == canonical move 0 -> A (for every A)
//   topos.cpl_element  == section with type 1 -> A (CPL element)
//
// Codici errore: [TOPOS-E0970..E0982]
//===----------------------------------------------------------------------===//

// topos.terminal @name in @world
//
// Declares the terminal object `1` of the enclosing world. Hagino:
//   right object 1 with ! end   (N=0 parameters, M=0 nat trans)
// Universally: for every place A, there is a unique move `!_A : A -> 1`.
//
// Verifier:
//   - the world exists
//   - uniqueness: only one terminal per world
def Topos_TerminalOp : Topos_Op<"terminal", [Symbol]> {
  let summary = "Terminal object 1 of a world (Hagino degenerate right object)";
  let description = [{
    Categorical terminal object. Universal property:
    for every place A in the same world, there exists a unique
    morphism `!_A : A -> 1`. In Hagino notation:
    `right object 1 with ! end` (N=M=0).
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world
  );
  let assemblyFormat = "$sym_name `in` $world attr-dict";
  let hasVerifier = 1;
}

// topos.initial @name in @world
//
// Dual: initial object `0`. Hagino:
//   left object 0 with !! end   (N=0 parameters, M=0 nat trans)
// Universally: for every place A, there is a unique move `!!_A : 0 -> A`.
def Topos_InitialOp : Topos_Op<"initial", [Symbol]> {
  let summary = "Initial object 0 of a world (Hagino degenerate left object)";
  let description = [{
    Categorical initial object. Universal property:
    for every place A in the same world, there exists a unique
    morphism `!!_A : 0 -> A`. In Hagino notation:
    `left object 0 with !! end` (N=M=0).
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world
  );
  let assemblyFormat = "$sym_name `in` $world attr-dict";
  let hasVerifier = 1;
}

// topos.bang @name from @src to @terminal
//
// Canonical move A -> 1 (for any A). It is the realization of the universal
// "!". The verifier checks that the target is a TerminalOp.
//
// For each place A in the world, there is only one bang to the terminal:
// uniqueness is guaranteed declaratively (you cannot declare two bangs with the
// same src and terminal tgt).
def Topos_BangOp : Topos_Op<"bang", [Symbol]> {
  let summary = "Unique morphism A -> 1 (terminal universality)";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$src,
    FlatSymbolRefAttr:$terminal
  );
  let assemblyFormat = "$sym_name `from` $src `to` $terminal attr-dict";
  let hasVerifier = 1;
}

// topos.absurd @name from @initial to @tgt
//
// Canonical move 0 -> A (for any A). Realization of the universal "!!". The
// verifier checks that the source is an InitialOp.
def Topos_AbsurdOp : Topos_Op<"absurd", [Symbol]> {
  let summary = "Unique morphism 0 -> A (initial universality)";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$initial,
    FlatSymbolRefAttr:$tgt
  );
  let assemblyFormat = "$sym_name `from` $initial `to` $tgt attr-dict";
  let hasVerifier = 1;
}

// topos.right_object @name params [@P1, ..., @Pn]
//                    factorizer @psi
//                    nat_trans { ... }
//
// General right object declaration (Hagino ch. 3.2). N functorial parameters
// (place), a factorizer as the canonical move (constructor), and a region that
// declares M nat_trans `alpha_i` as destructors.
//
// Verifier:
//   - all params must exist as places
//   - the factorizer must be a declared MoveOp and have this right_object's
//     name as its target
//   - the internal nat_trans must have this right_object's name as their
//     source
//
// Example (product):
//   topos.right_object @prod params [@X, @Y]
//                      factorizer @pair
//                      nat_trans {
//     topos.nat_trans @pi1 from "prod" to "X" arity 1
//     topos.nat_trans @pi2 from "prod" to "Y" arity 1
//   }
def Topos_RightObjectOp : Topos_Op<"right_object", [
    Symbol, SymbolTable, NoTerminator
  ]> {
  let summary = "Hagino right object declaration (CDT mechanism)";
  let description = [{
    Declares a right object L with N functorial parameters and M
    canonical destructor natural transformations alpha_i : E_i -> E'_i.
    The factorizer psi is the unique constructor: any cone is factored
    through psi. Dual of `topos.left_object`.

    Hagino 3.2:
      right object L(X_1,...,X_n) with psi is
          alpha_1 : E_1 -> E'_1
          ...
          alpha_m : E_m -> E'_m
      end object
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world,
    FlatSymbolRefArrayAttr:$params,
    FlatSymbolRefAttr:$factorizer
  );
  let regions = (region SizedRegion<1>:$nat_trans);
  let assemblyFormat = [{
    $sym_name `in` $world `params` $params
    `factorizer` $factorizer
    `nat_trans` attr-dict-with-keyword $nat_trans
  }];
  let hasVerifier = 1;
}

// topos.left_object — dual: nat_trans are the canonical constructors,
// the factorizer is the destructor (case-analysis).
def Topos_LeftObjectOp : Topos_Op<"left_object", [
    Symbol, SymbolTable, NoTerminator
  ]> {
  let summary = "Hagino left object declaration (CDT mechanism)";
  let description = [{
    Declares a left object L with N functorial parameters. The N nat_trans
    alpha_i are the canonical constructors; the factorizer psi is the unique
    destructor (case-analysis / fold). Dual of `topos.right_object`.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world,
    FlatSymbolRefArrayAttr:$params,
    FlatSymbolRefAttr:$factorizer
  );
  let regions = (region SizedRegion<1>:$nat_trans);
  let assemblyFormat = [{
    $sym_name `in` $world `params` $params
    `factorizer` $factorizer
    `nat_trans` attr-dict-with-keyword $nat_trans
  }];
  let hasVerifier = 1;
}

// topos.nat_trans @name from <src_functor_expr> to <tgt_functor_expr> arity N
//
// Natural transformation internal to a right/left object. The "functor
// expressions" are strings (CSL syntax) — the structural check is delegated to
// the enclosing object's verifier, which knows the grammar.
//
// arity = the number of argument positions of the nat_trans as a morphism. In
// the vast majority of cases it is 1.
def Topos_NatTransOp : Topos_Op<"nat_trans", [
    Symbol,
    ParentOneOf<["RightObjectOp", "LeftObjectOp"]>
  ]> {
  let summary = "Natural transformation inside a right/left object";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    StrAttr:$src_expr,
    StrAttr:$tgt_expr,
    I32Attr:$arity
  );
  let assemblyFormat = [{
    $sym_name `from` $src_expr `to` $tgt_expr `arity` $arity attr-dict
  }];
  // No hasVerifier: structural check happens in parent's verifier.
}

// topos.exponential @name in @world base @A target @B factorizer @curry eval @eval
//
// Right object speciale: B^A con factorizer curry e una nat_trans eval.
// Special case of topos.right_object — emitted as such by the lowering of
// future passes, but useful as a declaration
// shortcut nei sorgenti MLIR.
def Topos_ExponentialOp : Topos_Op<"exponential", [Symbol]> {
  let summary = "Exponential B^A as a Hagino right object";
  let description = [{
    Declares `B^A` (exponential / function space) as a right object
    with factorizer `curry: prod(B^A, A) -> B  =>  X -> B^A` and
    nat_trans `eval: prod(B^A, A) -> B`. Hagino 3.2 example.

    In Yon, the exponential is the categorical interpretation of
    `(A) -> B` arrow types; it lives in the world's enclosing topos.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world,
    FlatSymbolRefAttr:$base,            // A
    FlatSymbolRefAttr:$target,          // B
    FlatSymbolRefAttr:$curry_factorizer,
    FlatSymbolRefAttr:$eval_nat_trans
  );
  let assemblyFormat = [{
    $sym_name `in` $world
    `base` $base `target` $target
    `factorizer` $curry_factorizer
    `eval` $eval_nat_trans attr-dict
  }];
  let hasVerifier = 1;
}

// topos.cpl_element @name : section_to @A
//
// CPL element (Hagino ch. 4): morphism 1 -> A.
// In Yon it corresponds to a `topos.section` but with the structural
// constraint that the "source" is the terminal of the world.
//
// Verifier: the enclosing world must have a TerminalOp; the target must be an
// existing place.
def Topos_CplElementOp : Topos_Op<"cpl_element", [Symbol]> {
  let summary = "CPL element: morphism 1 -> A (canonical element of A)";
  let description = [{
    Hagino CPL element (cap 4). Represents a global element of a
    place: a morphism from the terminal `1` to a target place `A`.
    Requires a TerminalOp to exist in the enclosing world.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world,
    FlatSymbolRefAttr:$target
  );
  let assemblyFormat = "$sym_name `in` $world `to` $target attr-dict";
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// T |- L adjoint certification (Lambek-Scott Part II, sections 15-16:
// the adjunction between intuitionistic type theories and toposes; section 15
// "Toposes with canonical subobjects")
//===----------------------------------------------------------------------===//

// topos.adjoint_check @world
//
// Certifies that the world `@world` satisfies the structural conditions for
// membership in Top_0 (the subcategory of Top with canonical subobjects), and
// hence for being an object of the adjunction T |- L with Lang (Lambek-Scott
// Part II, sections 15-16; there is no single "Theorem 15.4" — the result is
// the pair of adjoint functors developed across sections 12-16).
//
// The checks are structural (the full verification "T(L(F)) ~= F" would
// require an entire homotopy theory, left to future passes). What we do here
// is:
//
//   (a) Top_0 membership: the world must have
//       - exactly one TerminalOp        (presence of 1)
//       - exactly one InitialOp         (presence of 0)
//       - at least one RightObjectOp    (exists product/exp/right limit)
//       - at least one LeftObjectOp     (exists coproduct/left colimit)
//       Without one of these, the world is not a Hagino-complete elementary
//       topos and the adjunction T |- L does not apply (errors
//       [TOPOS-E0990..E0993]).
//
//   (b) Lang correspondence: each ReduceOp in the world must have a
//       corresponding MoveOp with the same source/target (the reduction
//       "lives in the term theory L" iff the move "lives in the topos theory
//       T"). Error [TOPOS-E0994].
//
//   (c) Canonical subobjects (Lambek-Scott 27o): for now the check is
//       deferred; it requires an explicit declaration of a canonical subplace
//       for each subobject. When the flag `--strict-canonical` is passed,
//       adjoint_check requires it; otherwise it emits warning [TOPOS-W0995].
//
// adjoint_check does NOT prove T(L(F)) ~= F: it only rejects worlds that
// structurally cannot belong to Top_0. It is a declarative certification, not
// a homotopy proof.
def Topos_AdjointCheckOp : Topos_Op<"adjoint_check", [Symbol]> {
  let summary = "Certify Top_0 membership for T |- L adjoint (Lambek-Scott Part II, sec. 15-16)";
  let description = [{
    Structural certification that the named world satisfies the
    Top_0 conditions for the T |- L adjunction (Lambek-Scott Part II
    Part II, sec. 15-16). Does NOT compute T(L(F)) ~= F; rejects worlds
    that cannot be in Top_0 due to missing canonical infrastructure
    (terminal, initial, right_object, left_object, canonical subobjects).
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$world
  );
  let assemblyFormat = "$sym_name `for` $world attr-dict";
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// Fibrations Hermida (Hermida 1993 — Fibrations, logical predicates and
// indeterminates).
//
// A fibration `p: E -> B` realizes the pattern "a category varying continuously
// over a base": for each I in B there is a fiber `E_I` and for each `u: I -> J`
// a reindexing functor `u*: E_J -> E_I`.
//
// In Yon, base and total are both `topos.world`:
//   - base    = the world of "type contexts" (or "indices")
//   - total   = the world of "indexed types" (objects that live in a context)
//
// The fibers E_I are subcategories of the total world identified via the
// reindexing functor. The generic object (present iff the fibration is a
// lambda-arrow fibration) parametrizes the polymorphism.
//
// Codici errore: [TOPOS-E1000..E1009]
//===----------------------------------------------------------------------===//

// topos.fibration @p over @base total @total [generic_object @G]
//
// Declares a fibration between two worlds. The generic_object is optional: if
// present, it certifies that the fibration is a lambda-arrow fibration (Hermida
// 2.x) — the basis for categorical polymorphism.
def Topos_FibrationOp : Topos_Op<"fibration", [Symbol]> {
  let summary = "Hermida fibration p: E -> B between two worlds";
  let description = [{
    Declares a Hermida fibration `p: total -> base`. Both `base` and
    `total` are existing `topos.world`s. If `generic_object` is
    present, the fibration is certified as a lambda-arrow-fibration
    (Hermida 1993 cap 2), enabling categorical polymorphism.

    Reindexing functors are NOT declared inline here; they are
    introduced by `topos.reindex` for each base morphism that needs
    a lift, and verified to be cartesian against this fibration.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$base,
    FlatSymbolRefAttr:$total,
    OptionalAttr<FlatSymbolRefAttr>:$generic_object
  );
  let assemblyFormat = [{
    $sym_name `over` $base `total` $total
    (`generic_object` $generic_object^)?  attr-dict
  }];
  let hasVerifier = 1;
}

// topos.reindex @uS from @p along @u
//
// Reindexing functor (pullback functor) `u*: E_J -> E_I` induced by
// `u: I -> J` in the base, along the fibration `p`. Hermida 1.1.x.
//
// Internally, it is a declaration: the name `uS` identifies the functor between
// fibers as a "logical" morphism of the total world. Verifier
// check that:
//   - `p` exists as a FibrationOp
//   - `u` exists as a MoveOp in the base world of `p`
//   - the name `uS` does not collide with other reindexing functors
def Topos_ReindexOp : Topos_Op<"reindex", [Symbol]> {
  let summary = "Reindexing functor u* along a base morphism u";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$fibration,
    FlatSymbolRefAttr:$base_morphism
  );
  let assemblyFormat = [{
    $sym_name `from` $fibration `along` $base_morphism attr-dict
  }];
  let hasVerifier = 1;
}

// topos.indeterminate @x : @I in @base
//
// Category with an indeterminate (polynomial category) `B[x : I]`
// (Hermida 5.2): formally adds a global element `x : 1 -> I` to the base
// category. Universal property: every F: B -> C that preserves products, and
// every `a: F1 -> FI`, induces a unique `(F, a): B[x : I] -> C` with
// `(F, a) o eta = F`.
//
// In MLIR Yon, declares in the `base` world a new CplElement-like with name `x`
// of target `I`, but with the constraint that it is "indeterminate": the
// verifier rejects cpl_element declarations of the same name in the source.
def Topos_IndeterminateOp : Topos_Op<"indeterminate", [Symbol]> {
  let summary = "Polynomial extension B[x:I] (Hermida 5.2)";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$type_place,
    FlatSymbolRefAttr:$base_world
  );
  let assemblyFormat = [{
    $sym_name `:` $type_place `in` $base_world attr-dict
  }];
  let hasVerifier = 1;
}

// topos.kleisli @K of_comonad @G in @world
//
// Kleisli object of a comonad `G` (seen as a self-loop reduction
// of the world). Hermida 5.3-5.4: the Kleisli object is `B_G = B[x : i]`
// when G = - x I (Proposition 5.3.12, PCK condition).
//
// In the Yon dialect, the Kleisli object is materialized as a new place in the
// enclosing world with factorizer = counit of G.
def Topos_KleisliOp : Topos_Op<"kleisli", [Symbol]> {
  let summary = "Kleisli object of a comonad (Hermida 5.3-5.4)";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$comonad_reduction,
    FlatSymbolRefAttr:$world
  );
  let assemblyFormat = [{
    $sym_name `of_comonad` $comonad_reduction `in` $world attr-dict
  }];
  let hasVerifier = 1;
}

// topos.topology @name of @place { ... }
// Lawvere-Tierney topology on a place (a pure declaration).
// In Yon a topology is identified by its `j`-morphism, which is declared
// separately as a MoveOp; this op is only the topology-name -> place binding.
def Topos_TopologyOp : Topos_Op<"topology", [Symbol]> {
  let summary = "Lawvere-Tierney topology on a place";
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$of_place
  );
  let assemblyFormat = "$sym_name `of` $of_place attr-dict-with-keyword";
  let hasVerifier = 1;
}

// topos.geom_morphism @name from @src_site to @dst_site
// Geometric morphism first-class — declaration pura.
//
// A pair of adjoint functors pull |- push, with pull left-exact.
// In Yon it is the construct that governs the passing of parameters and return
// values between hermetic Spaces. Pull = copy-in (f^*), push = copy-out (f_*).
//
// The pull and push functors are declared separately as MoveOp (or runtime
// functions) and referenced by name via symbols; the GeomMorphismOp is a
// binding between worlds, not a container of code. This separates the
// categorical identity (the pair of worlds) from the implementation (the
// runtime functions f^*, f_*).
def Topos_GeomMorphismOp : Topos_Op<"geom_morphism", [Symbol]> {
  let summary = "First-class geometric morphism between topoi";
  let description = [{
    A pair of adjoint functors pull |- push between two worlds. The declaration
    carries no inline code: the functors are materialized in the lowering as
    functions `<name>__pull` and `<name>__push` that the backend uses for
    cross-space copy-in and copy-out.

    The attribute `proper_base_change_attested` certifies that the pull is
    left-exact; without the attestation, the left-exactness check is left to a
    dedicated pass.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$source_site,
    FlatSymbolRefAttr:$target_site,
    UnitAttr:$proper_base_change_attested
  );
  let assemblyFormat = [{
    $sym_name `from` $source_site `to` $target_site attr-dict-with-keyword
  }];
  let hasVerifier = 1;
}

// topos.promote %value to @target_space
// Promote esplicito di un inhabitant a uno Space di lifetime superiore.
def Topos_PromoteOp : Topos_Op<"promote"> {
  let summary = "Explicit promotion of an inhabitant to an outer Space";
  let description = [{
    Moves `value` from the current Space to the Space `target_space` with a
    longer lifetime. Implementation: deep-copy into the outer Space's arena,
    with a static check that `value` contains no dangling refs to unpromoted
    child Spaces.
  }];
  let arguments = (ins
    AnyType:$value,
    FlatSymbolRefAttr:$target_space
  );
  let results = (outs AnyType:$promoted);
  let assemblyFormat = [{
    $value `to` $target_space `:` functional-type($value, $promoted) attr-dict
  }];
}

// topos.forces @stage, %condition { ... }
// Kripke-Joyal forcing: il body esegue se lo stage forza la condition.
def Topos_ForcesOp : Topos_Op<"forces", [
    NoTerminator,
    SingleBlock
  ]> {
  let summary = "Kripke-Joyal forcing block";
  let arguments = (ins
    FlatSymbolRefAttr:$stage,
    Topos_PropositionType:$condition
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $stage `,` $condition attr-dict-with-keyword $body
  }];
}

//===----------------------------------------------------------------------===//
// Yoneda-rep primitive operations
//===----------------------------------------------------------------------===//

// topos.probe_construct (probe-functions)
// Creates a probe-function: given a member name and the instance, produces the
// value of that member. It is the atomic element of Yoneda-rep.
def Topos_ProbeConstructOp : Topos_Op<"probe_construct", [Pure]> {
  let summary = "Construct a Yoneda probe (member-access function)";
  let arguments = (ins
    StrAttr:$member_name,
    Topos_SectionType:$instance
  );
  let results = (outs Topos_ProbeType:$probe);
  let assemblyFormat = [{
    $member_name `on` $instance `:` functional-type(operands, results) attr-dict
  }];
}

// topos.probe_apply %probe(%arg) : !result_type
// Applica un probe a un argomento (apertura del Yoneda lemma).
def Topos_ProbeApplyOp : Topos_Op<"probe_apply"> {
  let summary = "Apply a Yoneda probe at a stage";
  let arguments = (ins
    Topos_ProbeType:$probe,
    AnyType:$stage
  );
  let results = (outs AnyType:$result);
  let assemblyFormat = [{
    $probe `(` $stage `)` `:` functional-type(operands, results) attr-dict
  }];
}

// topos.probe_collapse %instance : !struct_type
// Pass-only operation: tells the compiler that the instance can be
// represented as a flat struct (Yoneda-rep devirtualization).
// Generated by the optimization passes when provably safe.
def Topos_ProbeCollapseOp : Topos_Op<"probe_collapse", [Pure]> {
  let summary = "Collapse Yoneda-rep into a flat struct (post-optimization)";
  let arguments = (ins Topos_SectionType:$instance);
  let results = (outs AnyType:$flat_repr);
  let assemblyFormat = [{
    $instance `:` functional-type(operands, results) attr-dict
  }];
}

//===----------------------------------------------------------------------===//
// topos.pabs (universal polymorphism abstraction)
//
// Reference: Turbak 12.2.2 [forall-intro] with a purity restriction.
//
// Syntax:
//   topos.pabs ["s", "t"] {
//     ^bb0:
//       <pure body>
//   } : !result_type
//
// The body must be syntactically pure (Turbak Figure 13.25). Without this
// restriction, a pabs with a side effect would have semantics dependent on the
// evaluation order of the pcalls, breaking parametricity.
//===----------------------------------------------------------------------===//

def Topos_PabsOp : Topos_Op<"pabs", [
    NoTerminator,
    IsolatedFromAbove
  ]> {
  let summary = "Universal polymorphism abstraction (pabs of FLEX/SP)";
  let description = [{
    Creates a polymorphic value parametrized over the type identifiers
    `type_params`. The body is the polymorphic value. The introduction rule
    [forall-intro] (Turbak 12.2.2) requires the body to be pure: no observable
    side effect.

    Verifier: checks the syntactic purity of the body.
  }];
  let arguments = (ins
    StrArrayAttr:$type_params
  );
  let results = (outs AnyType:$polymorphic_value);
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $type_params $body `:` type($polymorphic_value) attr-dict
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// topos.dselect (dependent type constructor select)
//
// Riferimento: Turbak 15.4.4 [moduleof-elim] purity restriction.
//
// (dselect theta E_place) selects the type constructor `tc_name` from
// `module_expr` (a place or module). The verifier requires `module_expr` to be
// syntactically pure: otherwise the dependent type system would attribute
// different types to the same expression at different times (breaking
// soundness).
//===----------------------------------------------------------------------===//

def Topos_DselectOp : Topos_Op<"dselect"> {
  let summary = "Dependent type constructor selection on a place/module";
  let description = [{
    Extracts the type constructor named `tc_name` from the module/place
    denoted by `module_expr`. Usage pattern:

      %place_val = ... : !topos.place<"L", "W">
      %t = topos.dselect "listof" of %place_val
            : (!topos.place<"L", "W">) -> !topos.world<"W">

    Verifier: `module_expr` must be pure (Turbak 15.4.4 purity restriction on
    [moduleof-elim]).
  }];
  let arguments = (ins
    StrAttr:$tc_name,
    AnyType:$module_expr
  );
  let results = (outs AnyType:$selected_type);
  let assemblyFormat = [{
    $tc_name `of` $module_expr `:` functional-type(operands, results)
    attr-dict
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// topos.dep_proposition (pure dependent prop)
//
// Riferimento: Lambek-Scott Part II cap 3-4 (Internal Language, Peano
// rules) + Turbak 14.5.2 (dependent types).
//
// A `dep_proposition` is a proposition guaranteed pure, used as a predicate for
// a dependent decision (e.g. a dependent if where the branches have distinct
// types). The body is a region that computes the !topos.proposition value and
// must be syntactically pure: without purity, the dependent type system would
// attribute different types to the same proposition at different times.
//
// Distinct from `topos.heyt` (constant tri-valued) because it can contain
// computation (e.g. heyt_and of sub-propositions) but with purity guaranteed.
//===----------------------------------------------------------------------===//

def Topos_DepPropositionOp : Topos_Op<"dep_proposition", [
    NoTerminator
  ]> {
  let summary = "Pure proposition usable as a dependent predicate";
  let description = [{
    Declares a proposition `sym_name` whose evaluation is purely semantic (no
    side effect). The body produces a !topos.proposition.

    Example:
      topos.dep_proposition @balance_positive {
        %z = topos.heyt true : !topos.proposition
        // ... pure combinations of heyt_and, heyt_or, etc.
      }
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = "$sym_name attr-dict-with-keyword $body";
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// topos.or_intro, topos.exists_intro
//
// Riferimento: Lambek-Scott Part II cap 20 (Freyd cover, disjunction
// property Prop 20.2, existence property Prop 20.5).
//
// Constructive witness: a proof construction for (P OR Q) or for
// (exists x. P(x)) MUST exhibit the witness explicitly, not derive it
// classically via double negation.
//
// - topos.or_intro: the attribute `side` in {"left", "right"} declares which of
//   the two disjuncts is proven. The witness is the proof of the chosen side,
//   passed as an operand.
// - topos.exists_intro: the witness `a` (of type `witness_type`) is passed as
//   an explicit operand. The resulting proposition holds if P(a) is proven.
//===----------------------------------------------------------------------===//

def Topos_OrIntroOp : Topos_Op<"or_intro", [Pure]> {
  let summary = "Constructive disjunction introduction (with explicit side)";
  let description = [{
    Builds a proof of (P OR Q) by exhibiting which of the two sides is
    proven. Without making the side explicit, it would be a classical
    derivation (e.g. NOT NOT (P OR Q) => (P OR Q)) that does not hold in the
    free topos.

    L'attributo `side` deve essere "left" o "right".
  }];
  let arguments = (ins
    Topos_PropositionType:$proven_side,
    StrAttr:$side
  );
  let results = (outs Topos_PropositionType:$disjunction);
  let assemblyFormat = [{
    $proven_side `,` $side `:` type($proven_side) `->` type($disjunction)
    attr-dict
  }];
  let hasVerifier = 1;
}

def Topos_ExistsIntroOp : Topos_Op<"exists_intro", [Pure]> {
  let summary = "Constructive existence introduction (with explicit witness)";
  let description = [{
    Builds a proof of (exists x. P(x)) by exhibiting the witness `a` and the
    proof `P(a)`. Without an explicit witness it would be a classical
    derivation (e.g. NOT forall x. NOT P(x) => exists x. P(x)).
  }];
  let arguments = (ins
    AnyType:$witness,
    Topos_PropositionType:$predicate_at_witness
  );
  let results = (outs Topos_PropositionType:$exists_proof);
  let assemblyFormat = [{
    $witness `,` $predicate_at_witness `:` type($witness) `,`
    type($predicate_at_witness) `->` type($exists_proof) attr-dict
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// topos.sharing_constraint
//
// Riferimento: Turbak 15.7.3 (coherence problem, sharing by
// specification SML-style).
//
// Declares that two places in two worlds (or in the same world) share a type
// constructor with the same implementation. Without this declaration, two
// places with separate `abstract AST` are distinct types to the type checker —
// even if the user knows they are the same AST.
//
// Syntax:
//   topos.sharing_constraint "AST" between @parser, @codegen
//
// Verifier: both referenced places exist, and both declare a type constructor
// named `tc_name`.
//===----------------------------------------------------------------------===//

def Topos_SharingConstraintOp : Topos_Op<"sharing_constraint"> {
  let summary = "Declare that two places share an abstract type constructor";
  let description = [{
    SML-style sharing declaration. Tells the type checker that two places
    (e.g. parser and codegen) share a type constructor (e.g. AST) with the same
    implementation, even though each declares it as abstract in its own
    interface.
  }];
  let arguments = (ins
    StrAttr:$tc_name,
    FlatSymbolRefAttr:$place_a,
    FlatSymbolRefAttr:$place_b
  );
  let assemblyFormat = [{
    $tc_name `between` $place_a `,` $place_b attr-dict
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// BATCH A — 12 new operations
//
// Each op here has let hasVerifier = 1 and a verify() implementation in
// TopOps.cpp. The ops are grouped by area:
//   - subtype coercion + bounded quantification + type classes
//   - costruzioni topos-teoretiche (P2-bis)
//   - costruzioni su world / coeffect (P5-bis)
//===----------------------------------------------------------------------===//

// explicit subtype coercion.
def Topos_TheOp : Topos_Op<"the"> {
  let summary = "Explicit subtype coercion from source type to target type";
  let description = [{
    Applies an explicit subtype coercion: takes `source` of some type
    S and returns it tagged at type `target_type`. The verifier
    enforces (for now) syntactic type equality between source and
    target; a downstream pass extends to the full set of subtype
    rules (arrow co/contra, record/oneof width+depth, forall, μ).
  }];
  let arguments = (ins
    AnyType:$source,
    TypeAttr:$target_type
  );
  let results = (outs AnyType:$coerced);
  let assemblyFormat = [{
    $target_type $source `:` type($source) `->` type($coerced) attr-dict
  }];
  let hasVerifier = 1;
}

// bounded universal quantification (kernel F-sub).
def Topos_PabsBoundedOp : Topos_Op<"pabs_bounded", [
    NoTerminator,
    IsolatedFromAbove
  ]> {
  let summary = "Bounded universal polymorphism abstraction (kernel F<:)";
  let description = [{
    Like `topos.pabs`, but each type parameter is paired with an
    upper bound. `type_params` is an array of strings naming the
    type variables; `bounds` is a parallel array of TypeAttr giving
    the upper bound for each parameter. Same arity is required.
    Body must be syntactically pure (same purity restriction as
    `topos.pabs`).
  }];
  let arguments = (ins
    StrArrayAttr:$type_params,
    TypeArrayAttr:$bounds
  );
  let results = (outs AnyType:$polymorphic_value);
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $type_params `subtype_of` $bounds $body `:` type($polymorphic_value)
    attr-dict
  }];
  let hasVerifier = 1;
}

// Type class declaration.
def Topos_ClassOp : Topos_Op<"class", [
    Symbol,
    NoTerminator
  ]> {
  let summary = "Declare a type class (Haskell-style ad-hoc polymorphism)";
  let description = [{
    Declares a type class `sym_name` parameterised by a single type
    variable `type_param`. The body region contains operation
    signatures (declared as `topos.operation` ops, no body) that
    every instance must implement.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    StrAttr:$type_param
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = "$sym_name $type_param attr-dict-with-keyword $body";
  let hasVerifier = 1;
}

// Type class instance.
def Topos_InstanceOp : Topos_Op<"instance", [
    NoTerminator
  ]> {
  let summary = "Provide a class instance for a specific type";
  let description = [{
    Declares that the type referred to by `for_type` implements the
    class `class_name`. The body region holds the implementations
    of the class's operations for this specific type.
  }];
  let arguments = (ins
    FlatSymbolRefAttr:$class_name,
    TypeAttr:$for_type
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $class_name `for` $for_type attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

// Grothendieck site -> topos construction.
def Topos_FromSiteOp : Topos_Op<"from_site", [Symbol, NoTerminator]> {
  let summary = "Build a topos from a Grothendieck site (sheaves over C, J)";
  let description = [{
    Declares a new world `sym_name` constructed as the topos of
    sheaves over a site. The `base_category` field names the
    underlying small category (another world acting as a small
    category), and `topology` names the coverage. The body region
    is for any additional structure (e.g. a chosen generator set).
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$base_category,
    FlatSymbolRefAttr:$topology
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $sym_name `from` $base_category `,` $topology
    attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

// canonical site extraction from a topos.
def Topos_CanonicalSiteOp : Topos_Op<"canonical_site"> {
  let summary = "Extract the canonical (sub-)site from a topos";
  let description = [{
    Yields a handle to the canonical site of `world_name`. Used by
    downstream passes that want to reason about a topos in terms of
    its presheaves over the canonical generators.
  }];
  let arguments = (ins FlatSymbolRefAttr:$world_name);
  let results = (outs AnyType:$site_handle);
  let assemblyFormat = [{
    $world_name `:` type($site_handle) attr-dict
  }];
  let hasVerifier = 1;
}

// Čech nerve for an effective epimorphism.
def Topos_CechNerveOp : Topos_Op<"cech_nerve"> {
  let summary = "Čech nerve of a covering family (effective epi witness)";
  let description = [{
    Given an effective epimorphism `cover_morphism` (a move tagged
    as a covering map), produces the Čech nerve as a simplicial
    object. The result handle is used by glueing operations that
    require an effective covering.
  }];
  let arguments = (ins
    FlatSymbolRefAttr:$cover_morphism
  );
  let results = (outs AnyType:$nerve_handle);
  let assemblyFormat = [{
    $cover_morphism `:` type($nerve_handle) attr-dict
  }];
  let hasVerifier = 1;
}

// Kripke-Joyal forcing check.
def Topos_KripkeJoyalForcingOp : Topos_Op<"kripke_joyal_forcing"> {
  let summary = "Kripke-Joyal forcing relation at a stage";
  let description = [{
    Asserts that `proposition` is forced at `stage` (an object of
    the underlying site). Verifier requires stage and proposition
    to be present and the connective (AND, OR, ->, forall, exists) named in
    `connective` to be one of the supported tags.
  }];
  let arguments = (ins
    AnyType:$stage,
    Topos_PropositionType:$proposition,
    StrAttr:$connective
  );
  let results = (outs I1:$forced);
  let assemblyFormat = [{
    $stage `forces` $proposition `,` $connective `:` type($stage) `->`
    type($forced) attr-dict
  }];
  let hasVerifier = 1;
}

// canonical subobject postulate-bearing op.
def Topos_CanonicalSubplaceOp : Topos_Op<"canonical_subplace", [
    Symbol
  ]> {
  let summary = "Declare a place as a canonical subobject of a parent place";
  let description = [{
    Declares `sym_name` as a canonical subobject of `parent_place`,
    classified by `classifier`. Verifier checks parent existence
    and that classifier is of `!topos.proposition` type.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$parent_place,
    AnyType:$classifier
  );
  let assemblyFormat = [{
    $sym_name `of` $parent_place `by` $classifier `:` type($classifier)
    attr-dict
  }];
  let hasVerifier = 1;
}

// split fibration declaration.
def Topos_SplitFibrationOp : Topos_Op<"split_fibration"> {
  let summary = "Declare a split fibration between two worlds";
  let description = [{
    A split fibration p : E -> B with a chosen splitting (functorial
    choice of cartesian liftings). Verifier checks that both worlds
    exist and that `total` and `base` are distinct.
  }];
  let arguments = (ins
    FlatSymbolRefAttr:$total,
    FlatSymbolRefAttr:$base
  );
  let assemblyFormat = [{
    $total `over` $base attr-dict
  }];
  let hasVerifier = 1;
}

// place dependent on a world parameter.
def Topos_PlaceDependentOp : Topos_Op<"place_dependent", [
    Symbol,
    NoTerminator
  ]> {
  let summary = "Declare a place parametric in a world (dependent place)";
  let description = [{
    A place whose interior depends on the choice of a world
    parameter `world_param`. Verifier checks the parameter is named
    and the body is non-empty.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    StrAttr:$world_param
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $sym_name `(` $world_param `)` attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

// invert (topos of fractions) for a set of reductions.
def Topos_InvertOp : Topos_Op<"invert", [Symbol, NoTerminator]> {
  let summary = "Declare a world by inverting a set of reductions";
  let description = [{
    Declares world `sym_name` as the result of formally inverting
    every reduction listed in `reductions_to_invert` inside the
    source world `source_world`. Verifier checks that source exists
    and that the reductions list is non-empty.
  }];
  let arguments = (ins
    SymbolNameAttr:$sym_name,
    FlatSymbolRefAttr:$source_world,
    StrArrayAttr:$reductions_to_invert
  );
  let regions = (region SizedRegion<1>:$body);
  let assemblyFormat = [{
    $sym_name `=` `invert` `(` $source_world `,` $reductions_to_invert `)`
    attr-dict-with-keyword $body
  }];
  let hasVerifier = 1;
}

// load world from file.
def Topos_LoadWorldOp : Topos_Op<"load_world"> {
  let summary = "Load a world from an external file";
  let description = [{
    Loads a serialized world from file path `path`, expecting it to
    have type `expected_world`. The verifier checks that `path` is
    non-empty and that `expected_world` refers to a declared world
    symbol used as a type tag for the load result.
  }];
  let arguments = (ins
    StrAttr:$path,
    FlatSymbolRefAttr:$expected_world,
    OptionalAttr<StrAttr>:$version_hash
  );
  let results = (outs AnyType:$loaded);
  let assemblyFormat = [{
    $path `as` $expected_world `:` type($loaded) attr-dict
  }];
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// indexed comonad operations for coeffect tracking
//
// Three operations that together model an indexed comonad on coeffect
// algebras (Petricek-Orchard 2014):
//
//   coeffect_pure   : ()         -> Coeffected[1, a]
//   coeffect_extract: Coeffected[1, a]  -> a
//   coeffect_extend : Coeffected[r, a]
//                     * (Coeffected[s, a] -> b)
//                     -> Coeffected[r ⊗ s, b]
//
// The verifier enforces structural arity; the algebraic laws of the
// comonad are checked by an analysis pass.
//===----------------------------------------------------------------------===//

def Topos_CoeffectPureOp : Topos_Op<"coeffect_pure"> {
  let summary = "Unit of the coeffect-indexed comonad";
  let description = [{
    Lifts a value into a coeffected context at the algebra's unit
    grade (1). The grade attribute names the algebra (must match a
    `coeffect_algebra` declared on the enclosing place).
  }];
  let arguments = (ins
    AnyType:$value,
    StrAttr:$algebra
  );
  let results = (outs AnyType:$coeffected);
  let assemblyFormat = [{
    $value `,` $algebra `:` type($value) `->` type($coeffected)
    attr-dict
  }];
  let hasVerifier = 1;
}

def Topos_CoeffectExtractOp : Topos_Op<"coeffect_extract"> {
  let summary = "Counit of the coeffect-indexed comonad";
  let description = [{
    Extracts a value from a coeffected context. The grade must be the
    algebra's unit (1); otherwise the underlying coeffect would be
    discarded silently.
  }];
  let arguments = (ins
    AnyType:$coeffected,
    StrAttr:$algebra
  );
  let results = (outs AnyType:$value);
  let assemblyFormat = [{
    $coeffected `,` $algebra `:` type($coeffected) `->` type($value)
    attr-dict
  }];
  let hasVerifier = 1;
}

def Topos_CoeffectExtendOp : Topos_Op<"coeffect_extend"> {
  let summary = "Cobind (extension) of the coeffect-indexed comonad";
  let description = [{
    Sequencing operation: given a coeffected value of grade r and a
    continuation that consumes a coeffected value of grade s, returns
    a coeffected result of grade r ⊗ s. The composition law (r ⊗ s)
    is left implicit at this layer and validated by a downstream
    analysis pass.
  }];
  let arguments = (ins
    AnyType:$coeffected,
    AnyType:$continuation,
    StrAttr:$algebra
  );
  let results = (outs AnyType:$result);
  let assemblyFormat = [{
    $coeffected `,` $continuation `,` $algebra `:`
    functional-type(operands, results) attr-dict
  }];
  let hasVerifier = 1;
}

#endif // TOPOS_OPS
