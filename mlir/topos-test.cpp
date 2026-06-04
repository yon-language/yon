//===- topos-test.cpp - Test executable for Topos dialect ---*- C++ -*-===//
//
// Test executable demonstrating that the Topos dialect is registrable,
// instantiable, and that the operations can be created programmatically.
//
// Compilation: see CMakeLists.txt (target topos-test).
//
//===----------------------------------------------------------------------===//

#include "TopDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/Verifier.h"
#include "llvm/Support/raw_ostream.h"
#include <iostream>

using namespace mlir;

int main() {
  llvm::outs() << "=== Yon Topos dialect test ===\n\n";

  // Create an MLIRContext and register the Topos dialect.
  MLIRContext context;
  context.loadDialect<topos::ToposDialect>();
  context.loadDialect<BuiltinDialect>();

  // Verify that the dialect is registered.
  Dialect *toposDialect = context.getOrLoadDialect("topos");
  if (!toposDialect) {
    llvm::errs() << "ERROR: Topos dialect not registered.\n";
    return 1;
  }
  llvm::outs() << "[1] Topos dialect registered: " 
               << toposDialect->getNamespace() << "\n";

  // Create the dialect types.
  auto worldType = topos::WorldType::get(&context, "Region");
  auto placeType = topos::PlaceType::get(&context, "Account", "Region");
  auto sectionType = topos::SectionType::get(&context, "Account");
  auto propType = topos::PropositionType::get(&context);
  auto cellType = topos::CellType::get(&context, /*dim=*/2, "homotopy");

  llvm::outs() << "[2] Types created:\n";
  llvm::outs() << "    " << worldType << "\n";
  llvm::outs() << "    " << placeType << "\n";
  llvm::outs() << "    " << sectionType << "\n";
  llvm::outs() << "    " << propType << "\n";
  llvm::outs() << "    " << cellType << "\n";

  // Create an MLIR module with a WorldOp inside.
  OpBuilder builder(&context);
  Location loc = builder.getUnknownLoc();
  auto module = ModuleOp::create(loc);

  builder.setInsertionPointToStart(module.getBody());

  // Create topos.world @Region { ... }
  auto worldOp = builder.create<topos::WorldOp>(
      loc,
      builder.getStringAttr("Region"),    // sym_name
      ArrayAttr(),                          // product_of
      ArrayAttr(),                          // coproduct_of
      StringAttr(),                         // quotient_of_world
      StringAttr(),                         // quotient_relation
      StringAttr());                        // subset_of

  // Aggiungi un blocco al body del world.
  Block *worldBody = &worldOp.getBody().emplaceBlock();
  builder.setInsertionPointToStart(worldBody);

  // Create topos.place @Account in @Region { ... }
  auto placeOp = builder.create<topos::PlaceOp>(
      loc,
      builder.getStringAttr("Account"),         // sym_name
      SymbolRefAttr::get(&context, "Region"),   // world
      UnitAttr(),                               // with_effects (no)
      FlatSymbolRefAttr(),                      // over
      StringAttr(),                             // coeffect_algebra (none)
      StringAttr());                            // qualifier (default "term")

  Block *placeBody = &placeOp.getBody().emplaceBlock();
  builder.setInsertionPointToStart(placeBody);

  // Create topos.field @balance : f64
  builder.create<topos::FieldOp>(
      loc,
      builder.getStringAttr("balance"),
      TypeAttr::get(builder.getF64Type()),
      UnitAttr());                              // is_private (no)

  // Create topos.field @owner : i64
  builder.create<topos::FieldOp>(
      loc,
      builder.getStringAttr("owner"),
      TypeAttr::get(builder.getI64Type()),
      UnitAttr());                              // is_private (no)

  llvm::outs() << "[3] MLIR module built.\n";

  // Verify the module.
  if (failed(verify(module))) {
    llvm::errs() << "ERROR: Verification failed.\n";
    module.print(llvm::errs());
    return 1;
  }
  llvm::outs() << "[4] Module verified (verify passes).\n";

  // Print the module as textual .mlir.
  llvm::outs() << "\n=== Output MLIR ===\n";
  module.print(llvm::outs());
  llvm::outs() << "\n\n=== Test completato ===\n";

  return 0;
}
