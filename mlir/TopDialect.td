//===- TopDialect.td - Yon Topos dialect base ----------*- tablegen -*-===//
//
// Main TableGen file that includes the operation specification.
// Generation: mlir-tblgen produces:
//   - TopOps.h.inc, TopOps.cpp.inc       (operation classes)
//   - TopTypes.h.inc, TopTypes.cpp.inc   (type classes)
//   - TopAttrs.h.inc, TopAttrs.cpp.inc   (attribute classes)
//   - TopEnums.h.inc, TopEnums.cpp.inc   (enum attribute support)
//   - TopDialect.h.inc, TopDialect.cpp.inc (dialect registration)
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_DIALECT
#define TOPOS_DIALECT

include "TopOps.td"

#endif // TOPOS_DIALECT
