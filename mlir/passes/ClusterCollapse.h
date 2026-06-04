//===- ClusterCollapse.h - SCT Theorem 1 as a compiler pass ----*- C++ -*-===//
//
// Pass: structural collapse (SCT Theorem 1, T = T_struct or T_comp).
// Brings into the COMPILER the pattern that the runtime/HSH realizes at
// runtime: provably-equal SSA values share a single computation, as the
// variables of one equivalence class share cluster_domains[cid].
//
// Concretely: structure-guided global value numbering. Two Pure operations with
// the same name, the same operands (by SSA identity), the same attributes and
// the same result types are "cluster-equivalent": the second and later ones are
// replaced by the first (canonical) one, and erased. This eliminates the
// redundant "propagation" (the recomputations).
//
// Primary target: topos.field_load from the same section on the same field (the
// paradigmatic case of Theorem 1), but the pass is general over any Pure op
// without side effects and without regions.
//
//===----------------------------------------------------------------------===//

#ifndef TOPOS_CLUSTER_COLLAPSE_H
#define TOPOS_CLUSTER_COLLAPSE_H

#include "mlir/Pass/Pass.h"
#include <memory>

namespace mlir {
namespace topos {

std::unique_ptr<Pass> createClusterCollapsePass();
void registerClusterCollapsePass();

} // namespace topos
} // namespace mlir

#endif
