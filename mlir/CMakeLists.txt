# CMakeLists.txt for the Topos MLIR dialect.
#
# Generates the C++ scaffolding from TopOps.td with mlir-tblgen, then builds
# the dialect library MLIRTopos, the pass library MLIRToposPasses and the
# driver topos-opt.

cmake_minimum_required(VERSION 3.20)
project(ToposDialect LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Trova MLIR/LLVM installato sul sistema.
# Tipicamente: sudo apt install llvm-18-dev libmlir-18-dev mlir-18-tools
find_package(MLIR REQUIRED CONFIG)
find_package(LLVM REQUIRED CONFIG)

message(STATUS "Using MLIRConfig.cmake in: ${MLIR_DIR}")
message(STATUS "Using LLVMConfig.cmake in: ${LLVM_DIR}")

include_directories(${LLVM_INCLUDE_DIRS})
include_directories(${MLIR_INCLUDE_DIRS})
include_directories(${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${CMAKE_CURRENT_BINARY_DIR})

list(APPEND CMAKE_MODULE_PATH "${MLIR_CMAKE_DIR}")
list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
include(TableGen)
include(AddLLVM)
include(AddMLIR)

# Generazione dei file .inc dal dialect.
set(LLVM_TARGET_DEFINITIONS TopOps.td)

# Operazioni
mlir_tablegen(TopOps.h.inc -gen-op-decls)
mlir_tablegen(TopOps.cpp.inc -gen-op-defs)

# Tipi
mlir_tablegen(TopTypes.h.inc -gen-typedef-decls)
mlir_tablegen(TopTypes.cpp.inc -gen-typedef-defs)

# Enums (gli unici "attributi" del dialect sono enum-based)
mlir_tablegen(TopEnums.h.inc -gen-enum-decls)
mlir_tablegen(TopEnums.cpp.inc -gen-enum-defs)

# Dialect
mlir_tablegen(TopDialect.h.inc -gen-dialect-decls -dialect=topos)
mlir_tablegen(TopDialect.cpp.inc -gen-dialect-defs -dialect=topos)

add_public_tablegen_target(ToposDialectIncGen)

# Libreria del dialect.
add_mlir_dialect_library(MLIRTopos
  TopDialect.cpp
  TopOps.cpp

  PARTIAL_SOURCES_INTENDED

  ADDITIONAL_HEADER_DIRS
  ${CMAKE_CURRENT_SOURCE_DIR}

  DEPENDS
  ToposDialectIncGen

  LINK_LIBS PUBLIC
  MLIRIR
  MLIRSupport
  MLIRInferTypeOpInterface
  MLIRSideEffectInterfaces
)

# Esponiamo gli include directory ai consumer della libreria.
target_include_directories(MLIRTopos PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_BINARY_DIR}
)

# Libreria dei pass di lowering, separata dalla libreria del dialect;
# topos-opt linka entrambe.
add_mlir_library(MLIRToposPasses
  passes/LowerToposToStandard.cpp
  passes/LowerToposExtensions.cpp
  passes/LowerToposToLLVM.cpp
  passes/HeytingShortCircuit.cpp
  passes/CoherenceElimination.cpp
  passes/WorldSpecialization.cpp
  passes/MoveComposition.cpp
  passes/CPSConversion.cpp
  passes/PlaceFusion.cpp
  passes/AlgebraVerifier.cpp
  passes/StructuralVN.cpp
  passes/CCCEquationsCheck.cpp
  passes/StructuralPasses.cpp

  PARTIAL_SOURCES_INTENDED

  ADDITIONAL_HEADER_DIRS
  ${CMAKE_CURRENT_SOURCE_DIR}

  DEPENDS
  ToposDialectIncGen

  LINK_LIBS PUBLIC
  MLIRTopos
  MLIRArithDialect
  MLIRFuncDialect
  MLIRFuncTransforms
  MLIRMemRefDialect
  MLIRPass
  MLIRTransforms
  MLIRTransformUtils
)

target_include_directories(MLIRToposPasses PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_BINARY_DIR}
)

# Eseguibile di test che dimostra l'uso del dialect.
add_executable(topos-test topos-test.cpp)
target_link_libraries(topos-test
  PRIVATE
  MLIRTopos
  MLIRIR
  MLIRSupport
  MLIRParser
  MLIRControlFlowInterfaces
)

# Standalone mlir-opt driver con dialect Topos pre-registrato.
# Permette di parsare/printare/validare file .mlir.
add_executable(topos-opt topos-opt.cpp)
target_link_libraries(topos-opt
  PRIVATE
  MLIRTopos
  MLIRToposPasses
  MLIRIR
  MLIRSupport
  MLIROptLib
  MLIRParser
  MLIRPass
  MLIRTransforms
  MLIRArithDialect
  MLIRControlFlowDialect
  MLIRFuncDialect
  MLIRLLVMDialect
  MLIRMemRefDialect
  MLIRSCFDialect
  # Conversion passes upstream (lowering verso LLVM dialect)
  MLIRArithToLLVM
  MLIRControlFlowToLLVM
  MLIRFuncToLLVM
  MLIRMemRefToLLVM
  MLIRSCFToControlFlow
  MLIRSCFTransforms
  MLIRReconcileUnrealizedCasts
)
