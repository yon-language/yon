/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* leech_theta.h — the Leech lattice constants the runtime is sized by, kept as
 * a single source of truth and shared across the runtime translation units.
 *
 * YON_LEECH_TYPE2_COUNT is the kissing number of the Leech lattice: the number
 * of vectors of norm 4, i.e. theta_coeff(2) of the Leech theta series
 * (Theta = E_12 - (65520/691) Delta, a weight-12 modular form). It is a
 * theorem, verified independently in the compiler by
 * frontend/test_leech_theta.ml through Ramanujan's sigma_11 and tau.
 *
 * It is the exact size of the XSet bitmap and the domain of the MPHF. Every
 * structure that ranges over the type-2 vectors derives its bound from here,
 * so the count has one place to live and one place to be checked against. */
#ifndef YON_LEECH_THETA_H
#define YON_LEECH_THETA_H

#define YON_LEECH_TYPE2_COUNT 196560u

#endif /* YON_LEECH_THETA_H */
