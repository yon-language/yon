// Warning: This file has been generated automatically. Do not change!
#ifndef MMGROUP_GENERATORS_H
#define MMGROUP_GENERATORS_H
/** @file mmgroup_generators.h

 The header file ``mmgroup_generators.h`` contains definitions for 
 the C files in the ``generator`` extension. This extension comprises 
 files ``mm_group_n.c``, ``gen_xi_functions.c``, and ``gen_leech.c``.

 In this header we also define an ``enum MMGROUP_ATOM_TAG_`` that
 specifies the format of an atom that acts as a generator of the
 monster group. 
*/










/** 
 In this header file we also define the tags for the atoms generating 
 the Monster group. An element of the monster group is represented
 as an array of integers of type ``uint32_t``, where each integer 
 represents an atom, i.e. an atomic element of the monster. An atom
 represents a triple ``(sign, tag, value)``, and is encoded in the 
 following bit fields of an unsigned 32-bit integer:

       Bit 31  | Bit 30,...,28  | Bit  27,...,0
       --------|----------------|----------------
        Sign   | Tag            | Value

 Standard tags and values are defined as in the constructor of the 
 Python class ``mmgroup.mm``, see section **The monster group**
 in the **API reference**. If the ``sign`` bit is set, this means
 that the atom bit given by the pair ``(tag, value)`` has to be 
 inverted. In ibid., a tag is given by a small letter. These small
 letters are converted to 3-bit numbers as follows:

       Tag  | Tag number | Range of possible values i
       -----|------------|----------------------------
        'd' |     1      |  0 <= i < 0x1000
        'p' |     2      |  0 <= i < 244823040
        'x' |     3      |  0 <= i < 0x2000
        'y' |     4      |  0 <= i < 0x2000
        't' |     5      |  0 <= i < 3
        'l' |     6      |  0 <= i < 3

 A tag with tag number 0 is interpreted as the neutral element.
 A tag with tag number 7 is illegal (and reserved for future use).
 
 Tags with other letters occuring in the constructor of class ``MM`` 
 are converted to a word of atoms with tags taken from the table 
 above.

 For tags 't' and 'l' the values 0 <= i <= 3 are legal on input. 
*/

enum MMGROUP_ATOM_TAG_ {
  /** Tag indicating the neutral element of the group */
  MMGROUP_ATOM_TAG_1  = 0x00000000UL,
  /** Tag indicating the neutral element of the group */
  MMGROUP_ATOM_TAG_I1  = 0x80000000UL,
  /** Tag corresponding to 'd' */
  MMGROUP_ATOM_TAG_D   = 0x10000000UL,
  /** Tag corresponding to inverse of tag 'd' */
  MMGROUP_ATOM_TAG_ID   = 0x90000000UL,
  /** Tag corresponding to 'p' */
  MMGROUP_ATOM_TAG_P   = 0x20000000UL,
  /** Tag corresponding to inverse of tag 'p' */
  MMGROUP_ATOM_TAG_IP   = 0xA0000000UL,
  /** Tag corresponding to 'x' */
  MMGROUP_ATOM_TAG_X   = 0x30000000UL,
  /** Tag corresponding to inverse of tag 'x' */
  MMGROUP_ATOM_TAG_IX   = 0xB0000000UL,
  /** Tag corresponding to 'y' */
  MMGROUP_ATOM_TAG_Y   = 0x40000000UL,
  /** Tag corresponding to inverse of tag 'y' */
  MMGROUP_ATOM_TAG_IY   = 0xC0000000UL,
  /** Tag corresponding to 't' */
  MMGROUP_ATOM_TAG_T   = 0x50000000UL,
  /** Tag corresponding to inverse of tag 't' */
  MMGROUP_ATOM_TAG_IT   = 0xD0000000UL,
  /** Tag corresponding to 'l' */
  MMGROUP_ATOM_TAG_L   = 0x60000000UL,
  /** Tag corresponding to inverse of tag 'l' */
  MMGROUP_ATOM_TAG_IL   = 0xE0000000UL,
};


/** Tag field of a monster group atom  */
#define MMGROUP_ATOM_TAG_ALL 0xF0000000UL


/** Data field of a monster group atom  */
#define MMGROUP_ATOM_DATA 0xFFFFFFFUL






/// @cond DO_NOT_DOCUMENT 
//  Definitions for using this header in a a DLL (or a shared library)

// Generic helper definitions for DLL (or shared library) support
#if defined(_WIN32) || defined(__CYGWIN__)
  #define MAT24_DLL_IMPORT __declspec(dllimport)
  #define MAT24_DLL_EXPORT __declspec(dllexport)
#elif (defined(__GNUC__) || defined(__clang__)) && defined(_WIN32)
  #define MAT24_DLL_IMPORT __attribute__((noinline,optimize("no-tree-vectorize"),visiblity("default")))
  #define MAT24_DLL_EXPORT __attribute__((noinline,optimize("no-tree-vectorize"),visiblity("default")))
#else
  #define MAT24_DLL_IMPORT
  #define MAT24_DLL_EXPORT
#endif

// Now we use the generic helper definitions above to define MAT24_API 
// MAT24_API is used for the public API symbols. It either DLL imports 
// or DLL exports 

#ifdef MAT24_DLL_EXPORTS // defined if we are building the MAT24 DLL 
  #define MAT24_API MAT24_DLL_EXPORT
#else                  // not defined if we are using the MAT24 DLL 
  #define MAT24_API  MAT24_DLL_IMPORT
#endif // MAT24_DLL_EXPORTS

/// @endcond
// %%FROM gen_xi_functions.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint32_t gen_xi_g_gray(uint32_t v);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_w2_gray(uint32_t v);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_g_cocode(uint32_t c);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_w2_cocode(uint32_t v);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_op_xi(uint32_t x, uint32_t e);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_op_xi_nosign(uint32_t x, uint32_t e);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_leech_to_short(uint32_t x);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_short_to_leech(uint32_t x);
// %%EXPORT px
MAT24_API
uint32_t gen_xi_op_xi_short(uint32_t x, uint32_t u);
// %%EXPORT p
MAT24_API
uint32_t gen_xi_make_table(uint32_t b, uint32_t e, uint16_t *ptab);
// %%EXPORT p
MAT24_API
void gen_xi_invert_table(uint16_t *ptab, uint32_t len, uint32_t ncols, uint16_t *pres, uint32_t len_res);
// %%EXPORT p
MAT24_API
void gen_xi_split_table(uint16_t *ptab, uint32_t len, uint32_t mod, uint32_t *psign);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM mm_group_n.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
void mm_group_n_mul_delta_pi(uint32_t *g, uint32_t delta, uint32_t pi);
// %%EXPORT px
MAT24_API
void mm_group_n_mul_inv_delta_pi(uint32_t *g, uint32_t delta, uint32_t pi);
// %%EXPORT px
MAT24_API
void mm_group_n_mul_x(uint32_t * g, uint32_t e);
// %%EXPORT px
MAT24_API
void mm_group_n_mul_y(uint32_t * g, uint32_t f);
// %%EXPORT px
MAT24_API
void mm_group_n_mul_t(uint32_t * g, uint32_t t);
// %%EXPORT px
MAT24_API
void mm_group_n_clear(uint32_t *g);
// %%EXPORT px
MAT24_API
void mm_group_n_copy_element(uint32_t *g_1, uint32_t *g_2);
// %%EXPORT px
MAT24_API
void mm_group_n_mul_element(uint32_t *g_1, uint32_t *g_2, uint32_t *g_3);
// %%EXPORT px
MAT24_API
void mm_group_n_mul_inv_element(uint32_t *g_1, uint32_t *g_2, uint32_t *g_3);
// %%EXPORT px
MAT24_API
void mm_group_n_inv_element(uint32_t *g_1, uint32_t *g_2);
// %%EXPORT px
MAT24_API
void mm_group_n_conjugate_element(uint32_t *g_1, uint32_t *g_2, uint32_t *g_3);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_mul_word_scan(uint32_t *g, uint32_t *w, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_mul_atom(uint32_t *g, uint32_t atom);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_scan_word(uint32_t *w, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t  mm_group_n_conj_word_scan(uint32_t *g, uint32_t *w, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_reduce_element(uint32_t *g);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_reduce_element_y(uint32_t *g);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_to_word(uint32_t *g, uint32_t *w);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_right_coset_N_x0(uint32_t *g);
// %%EXPORT px
MAT24_API
uint32_t mm_group_n_to_word_std(uint32_t *g, uint32_t *w);
// %%EXPORT px
MAT24_API
int32_t mm_group_n_conj_to_Q_x0(uint32_t *g);
// %%EXPORT px
MAT24_API
uint32_t mm_group_split_word_n(uint32_t *word, uint32_t length, uint32_t *g);
// %%EXPORT px
MAT24_API
uint32_t mm_group_mul_words(uint32_t *w1, uint32_t l1, uint32_t *w2, uint32_t l2, int32_t e);
// %%EXPORT px
MAT24_API
void mm_group_invert_word(uint32_t *w, uint32_t l);
// %%EXPORT px
MAT24_API
uint32_t mm_group_check_word_n(uint32_t *w1, uint32_t l1, uint32_t *g_out);
// %%EXPORT px
MAT24_API
uint32_t mm_group_words_equ(uint32_t *w1, uint32_t l1, uint32_t *w2, uint32_t l2, uint32_t *work);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM gen_leech.c
#ifdef __cplusplus
extern "C" {
#endif




/**
 @def gen_leech2_def_mul(x1, x2, result)
 @brief Macro version of function ``gen_leech2_mul``.

 Macro ``gen_leech2_def_mul(x1, x2, result)`` is equivalent to
 the statement ``result = gen_leech2_mul(x1, x2)``.
 The macro generates a sequence of statements!

 Caution:

 Here ``result`` must be an integer lvalue that is different
 from both integers, ``x1`` and ``x2``!

*/
#define gen_leech2_def_mul(x1, x2, result) \
    result = ((x2) >> 12) & (x1); \
    result = mat24_def_parity12(result); \
    result = ((result) << 24) ^ (x1) ^(x2); 


/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_mul(uint32_t x1, uint32_t x2);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_pow(uint32_t x1, uint32_t e);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_scalprod(uint32_t x1, uint32_t x2);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_op_word(uint32_t q0, uint32_t *g, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_op_atom(uint32_t q0, uint32_t g);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_prefix_Gx0(uint32_t *g, uint32_t len_g);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_op_word_many(uint32_t *q, uint32_t m, uint32_t *g, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_op_word_leech2(uint32_t l, uint32_t *g, uint32_t n, uint32_t back);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_op_word_leech2_many(uint32_t *a, uint32_t m, uint32_t *g, uint32_t n, uint32_t back);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_op_word_matrix24(uint32_t *g, uint32_t n, uint32_t back, uint32_t *a);
// %%EXPORT px
MAT24_API
void gen_leech2_op_mul_matrix24(uint32_t *a1, uint32_t n, uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_map_std_subframe(uint32_t *g, uint32_t len_g, uint32_t *a);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_leech_type.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
#ifdef MMGROUP_GENERATORS_INTERN

/**
  @brief inline version of function ``gen_leech2_coarse_subtype``
*/
static inline uint32_t gen_leech2_coarse_subtype_inline(uint32_t v2)
{
    uint32_t scalar = (v2 >> 12) &  v2;
    scalar = mat24_def_parity12(scalar);    // norm of v2 mod 2

    if (v2 & 0x800) {
        return scalar ? 8 : 5;
    } else {
        uint32_t w = MAT24_THETA_TABLE[(v2 >> 12) & 0x7ff] & 0x1000;
                     // parity of weight of Golay code part / 4
        if (w) {
            return scalar ? 7 : 4;
        } else {
            if (v2 & 0x7ff000UL) return scalar ? 6 : 3;
            else if (v2 & 0x7ff) return 2;
            else return (v2 & 0x800000) ? 1 : 0;
        }
    }
}

#endif


// %%EXPORT px
MAT24_API
uint32_t gen_leech2_subtype(uint64_t v2);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_coarse_subtype(uint32_t v2);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_type(uint64_t v2);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_type2(uint64_t v2);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_count_type2(uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_start_type24(uint32_t v);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_start_type4(uint32_t v);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_leech3.c
#ifdef __cplusplus
extern "C" {
#endif
#ifdef MMGROUP_GENERATORS_INTERN

/// @cond DO_NOT_DOCUMENT 

/**
  @brief Reduce coordinates of vector in Leech lattice mod 3

  The function reduces all coordinates of the vector \f$v_3\f$
  modulo 3, so that each coordinate has value 0, 1 or 2. Vector
  \f$v_3\f$ must be given Leech lattice mod 3 encoding.
*/
static inline uint64_t short_3_reduce(uint64_t v3)
{
    uint64_t a = (v3 & (v3 >> 24)) & 0xffffffUL;
    v3 ^=  a | (a << 24);
    return v3  & 0xffffffffffffULL;
}

/**
  @brief Perform operation \f$x_\pi\f$ on the Leech lattice mod 3

  The function returns the vector \f$v_3 \x_\pi\f$. Here the
  permutation \f$\pi\f$ given in the array ``perm`` as a permutation
  on the set  \f$\{0,\ldotss,23\}\f$. Vector \f$v_3\f$ and the
  result are given Leech lattice mod 3 encoding.
*/
static inline
uint64_t gen_leech3_op_pi(uint64_t v3, uint8_t perm[24])
{
    uint64_t w3 = 0;
    uint_fast32_t i;
    for (i = 0; i < 24; ++i) {
        w3 |= ((v3 >> i) & 0x1000001ULL) << perm[i];
    }
    return w3; 
}

/**
  @brief Perform operation \f$y_d\f$ on the Leech lattice mod 3

  The function returns vector \f$v_3 \x_\pi\f$. Here the element
  \f$d\f$ of the Parker loop is given as a integer ``d`` as in
  the API reference in section **The Parker loop**. Vector
  \f$v_3\f$ and the result are given Leech lattice mod 3 encoding.
*/
static inline
uint64_t gen_leech3_op_y(uint64_t v3, uint32_t d)
{
    uint64_t v = mat24_gcode_to_vect(d);
    return v3 ^  (v | (v << 24)); 
}


/**
  @brief Scalar product of two vectors in the Leech lattice mod 3

  The function returns the scalar product of the 
  vectors \f$v_{3,1}, $v_{3,1}\f$. The parameters are given Leech 
  lattice mod 3 encoding. The result is between 0 and 2.
*/
static inline uint32_t short_3_scalprod(uint64_t v3_1, uint64_t v3_2)
{
    uint64_t zero, res;
    
    // Set all bits i in ``zero`` to 0 where v3_1[i] * v3_2[i] is 0
    zero = ((v3_1 ^ (v3_1 >> 24)) & (v3_2 ^ (v3_2 >> 24))) & 0xffffffUL;
    // Store scalar products of entries of v3_1 and v3_2 in res
    // Each scalar product is >= 0 and <= 2.
    res = (v3_1 ^ v3_2) & 0xffffff000000ULL;
    res = (res & (zero << 24)) | (zero & ~(res >> 24));
    // Sum up the 48 bits of res, counting the high 24 bits twice
    res = (res & 0x555555555555ULL) + ((res >> 1) & 0x555555555555ULL);
    res = (res & 0x333333333333ULL) + ((res >> 2) & 0x333333333333ULL);
    res = (res & 0x0f0f0f0f0f0fULL) + ((res >> 4) & 0x0f0f0f0f0f0fULL);
    res = (res & 0xffffffULL) + ((res >> 23) & 0x1fffffeULL);
    res = ((res >> 16) + (res >> 8) + res) & 0xff;
    // Reduce res modulo 3; we have 0 <= res <= 48
    res = (res & 3) + (res >> 2); // res <= 19
    res = (0x924924924924924ULL >> (res << 1)) & 3;
    return (uint32_t)res;
}


/**
  @brief Add vectors in Leech lattice mod 3

  The function returns the sum of the vectors \f$v_{31}\f$
  and  \f$v_{32}\f$. These two vectors must be given in Leech
  lattice mod 3 encoding. The result is reduced and also
  given in Leech lattice mod 3 encoding.
*/
static inline uint64_t compute_3_sum(uint64_t v31, uint64_t v32)
{
    uint64_t a1 = v31 ^ v32;
    uint64_t a2 = v31 & v32 & 0xffffffffffffULL;
    a2 = ((a2 << 24) | (a2 >> 24)) & 0xffffffffffffULL;
    v31 = a1 ^ a2;
    v32 = a1 & a2 & 0xffffffffffffULL;
    v32 = ((v32 << 24) | (v32 >> 24)) & 0xffffffffffffULL;
    return v31 | v32;
}


/// @endcond  

#endif // #ifdef MMGROUP_GENERATORS_INTERN




/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint64_t gen_leech3_reduce(uint64_t v3);
// %%EXPORT px
MAT24_API
uint32_t gen_leech3_scalprod(uint64_t v3_1, uint64_t v3_2);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3_add(uint64_t v3_1, uint64_t v3_2);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3_neg(uint64_t v3);
// %%EXPORT px
MAT24_API
uint64_t gen_leech2to3_short(uint64_t v2);
// %%EXPORT px
MAT24_API
uint64_t gen_leech2to3_abs(uint64_t v2);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3to2_short(uint64_t v3);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3to2(uint64_t v3);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3to2_type4(uint64_t v3);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3_op_xi(uint64_t v3, uint32_t e);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3_op_vector_word(uint64_t v3, uint32_t *pg, uint32_t n);
// %%EXPORT px
MAT24_API
uint64_t gen_leech3_op_vector_atom(uint64_t v3, uint32_t g);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_leech_reduce.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT p
MAT24_API
int32_t apply_perm(uint32_t v, uint8_t *p_src, uint8_t *p_dest, uint32_t n, uint32_t *p_res);
// %%EXPORT p
MAT24_API
uint32_t find_octad_permutation(uint32_t v, uint32_t *p_res);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_reduce_type2(uint32_t v, uint32_t *pg_out);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_reduce_type2_ortho(uint32_t v, uint32_t *pg_out);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_reduce_type4(uint32_t v, uint32_t *pg_out);
// %%EXPORT px
MAT24_API
uint32_t gen_leech2_type_selftest(uint32_t start, uint32_t n, uint32_t *result);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_pair_type(uint64_t v1, uint64_t v2);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_leech_reduce_22.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
int32_t gen_leech2_n_type_22(uint32_t n);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_find_v4_2xx(uint32_t v2, uint32_t v3, uint64_t *seed);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_reduce_2xx(uint32_t v2, uint32_t v3, uint32_t v4, uint32_t *g);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_map_2xx(uint32_t *g, uint32_t n, uint32_t t, uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_u4_2xx(uint32_t v2, uint32_t v3, uint64_t *seed, uint32_t *a);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_leech_reduce_n.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
int32_t gen_leech2_reduce_n(uint32_t v, uint32_t *pg_out);
// %%EXPORT px
MAT24_API
int32_t gen_leech2_reduce_n_rep(uint32_t subtype);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_random.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
#define MM_GEN_RNG_SIZE 4
// %%EXPORT px
MAT24_API
void gen_rng_seed_init(void);
// %%EXPORT px
MAT24_API
void gen_rng_seed_no(uint64_t *seed, uint64_t seed_no);
// %%EXPORT px
MAT24_API
void gen_rng_seed(uint64_t *seed);
// %%EXPORT px
MAT24_API
int32_t gen_rng_bytes_modp(uint32_t p, uint8_t *out, uint32_t len, uint64_t *seed);
// %%EXPORT px
MAT24_API
uint32_t gen_rng_modp(uint32_t p, uint64_t *seed);
// %%EXPORT px
MAT24_API
uint64_t gen_rng_bitfields_modp(uint64_t p, uint32_t d, uint64_t *seed);
// %%EXPORT px
MAT24_API
double gen_rng_uniform(uint64_t *seed);
// %%EXPORT px
MAT24_API
uint32_t gen_rng_uniform_to_dist(double x, uint32_t n, double *dist);
// %%EXPORT px
MAT24_API
void gen_rng_int_dist(uint64_t *seed, uint32_t n, double *dist, uint32_t *a, uint32_t l_a);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM gen_union_find.c
#ifdef __cplusplus
extern "C" {
#endif

/**
  @enum gen_ufind_error_type
  @brief Error codes for functions in this module

  Unless otherwise stated, the functions in modules ``gen_union_find.c``, 
  and ``gen_ufind_lin2.c``  return nonnegative values
  in case of success and negative values in case of failure. 
  Negative return values mean error codes as follows:

  
*/
enum gen_ufind_error_type
{
ERR_GEN_UFIND_MEM        = -1, ///< Out of memory
ERR_GEN_UFIND_UF_LARGE   = -2, ///< Too many entries for union-find algorithm
ERR_GEN_UFIND_IN_LARGE   = -3, ///< Input parameter too large
ERR_GEN_UFIND_OUT_SHORT  = -4, ///< Output buffer too short
ERR_GEN_UFIND_ENTRY_UF   = -5, ///< Entry not in union-find table
ERR_GEN_UFIND_TABLE_UF   = -6, ///< Union-find table too large
ERR_GEN_UFIND_LIN2_DIM   = -7, ///< Dimension n of GF(2)^n is 0 or too large
ERR_GEN_UFIND_LIN2_GEN   = -8, ///< Too many generators for subgroup of SL_2(2)^n
ERR_GEN_UFIND_INVERSE    = -9, ///< Generator matrix is not invertible
ERR_GEN_UFIND_STATE     = -10, ///< Main buffer is not in correct state for this function
ERR_GEN_UFIND_DUPL      = -11, ///< Duplicate entry in union-find table

ERR_GEN_UFIND_INT_TABLE = -100, ///< -100 .. -199 are internal errors in module gen_union_find.c
ERR_GEN_UFIND_INT_LIN2  = -200, ///< -200 .. -299 are internal errors in module gen_ufind_lin2.c

};

/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
int32_t gen_ufind_init(uint32_t * table, uint32_t length);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_find(uint32_t *table, uint32_t length, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t gen_ufind_union(uint32_t * table, uint32_t length, uint32_t n1, uint32_t n2);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_find_all_min(uint32_t *table, uint32_t length);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_make_map(uint32_t *table, uint32_t length, uint32_t *map);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_partition(uint32_t *table, uint32_t l_t, uint32_t *map, uint32_t *ind, uint32_t l_ind);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_union_affine(uint32_t *table, uint32_t n, uint32_t *g, uint32_t b);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_ufind_lin2.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint32_t gen_ufind_lin2_mul_affine(uint32_t v, uint32_t *m, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_size(uint32_t n, uint32_t k);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_init(uint32_t *a, uint32_t l_a, uint32_t n, uint32_t n_g);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_dim(uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_n_gen(uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_n_max_gen(uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_pad(uint32_t *a, uint32_t len_a, uint32_t n_max_g);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_gen(uint32_t *a, uint32_t i, uint32_t *g, uint32_t l_g);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_add(uint32_t *a, uint32_t *g, uint32_t l_g);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_transform_v(uint32_t *a, uint32_t v, uint8_t *b, uint32_t l_b);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_compressed_size(uint32_t *a, uint32_t *o, uint32_t l_o);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_compress(uint32_t *a, uint32_t *o, uint32_t l_o, uint32_t *c, uint32_t l_c);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_n_orbits(uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_rep_v(uint32_t *a, uint32_t v);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_len_orbit_v(uint32_t *a, uint32_t v);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_orbit_v(uint32_t *a, uint32_t v, uint32_t *r, uint32_t l_r);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_representatives(uint32_t *a, uint32_t *r, uint32_t l_r);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_orbit_lengths(uint32_t *a, uint32_t *r, uint32_t l_r);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_map_v_gen(uint32_t *a, uint32_t v);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_map_v(uint32_t *a, uint32_t v, uint8_t *b, uint32_t l_b);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_finalize(uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_check(uint32_t *a, uint32_t len_a);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_check_finalized(uint32_t *a, uint32_t len_a);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_get_map(uint32_t *a, uint32_t *map, uint32_t l_map);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_get_table(uint32_t *a, uint32_t *t, uint32_t l_t);
// %%EXPORT px
MAT24_API
int32_t gen_ufind_lin2_orbits(uint32_t *a, uint32_t *t, uint32_t l_t, uint32_t *x, uint32_t l_x);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM gen_leech_reduce_mod3.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
int32_t gen_leech3_find_tetrad_leech_mod3(uint64_t a);
// %%EXPORT px
MAT24_API
int64_t gen_leech3_reduce_leech_mod3(uint64_t v3, uint32_t *g);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%INCLUDE_HEADERS


#endif // ifndef MMGROUP_GENERATORS_H

