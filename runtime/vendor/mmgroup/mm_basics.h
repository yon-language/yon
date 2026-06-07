// Warning: This file has been generated automatically. Do not change!



#ifndef MM_BASICS_H
#define MM_BASICS_H




/** @file mm_basics.h

 The header file ``mm_basics.h`` contains basic definitions for dealing with 
 vectors of the 198884-dimensional representation of the monster group,
 as described in  *The C interface of the mmgroup project*, 
 section *Description of the mmgroup.mm extension*.


 It also contains prototypes for the C files in the ``mm`` extension. This 
 extension comprises the  files ``mm_aux.c``,  ``mm_crt.c``,  
``mm_group_word.c``, ``mm_random.c``, ``mm_tables.c``, 
``mm_tables_xi.c``. 
*/

#include <stdint.h>
#include "mat24_functions.h"
#include "mmgroup_generators.h"


/** @var typedef uint64_t uint_mmv_t
    @brief Used for the representation of the monster group

    Internally, a vector in the 196884-dimensional representation of 
    the monster is stored as an array of integers of 
    type ``uint_mmv_t``. Here several entries are stored in such
    an integer. See ``enum MM_AUX_OFS_type`` for more details.
*/
typedef uint64_t uint_mmv_t;


/**********************************************************************
*** Some macros
**********************************************************************/


/** 
  This enumeration contains the  offsets for the tags ``A,B,C,T,X,Z,Y``
  in a vector in the 196884-dimensional representation of the monster,
  stored in the internal representation.

  Such an offset counts the number of entries starting at the 
  beginning of th vector. Note that several entries of a vector are 
  stored in a 64-bit integer. Also there may be duplicate or
  unused entries in a vector, in order to speed up the operation
  of the monster group on a vector.
*/
enum MM_AUX_OFS {
  MM_AUX_OFS_A =      0UL, /**< Offset for tag A */ 
  MM_AUX_OFS_B =    768UL, /**< Offset for tag B */
  MM_AUX_OFS_C =   1536UL, /**< Offset for tag C */
  MM_AUX_OFS_T =   2304UL, /**< Offset for tag T */
  MM_AUX_OFS_X =  50880UL, /**< Offset for tag X */
  MM_AUX_OFS_Z = 116416UL, /**< Offset for tag Z */
  MM_AUX_OFS_Y = 181952UL, /**< Offset for tag Y */
  MM_AUX_LEN_V = 247488UL  /**< Total length of the internal representation */
};


/** 
  This enumeration contains the offsets for the tags ``A,B,C,T,X,Z,Y``
  in a vector in the 196884-dimensional representation of the monster,
  stored in the external representation.

  In external representation, a vector is stored as a contiguous 
  array of bytes.
*/
enum MM_AUX_XOFS {
  MM_AUX_XOFS_D =      0UL, /**< Offset for diagonal entries of tag A */ 
  MM_AUX_XOFS_A =     24UL, /**< Offset for tag A */ 
  MM_AUX_XOFS_B =    300UL, /**< Offset for tag B */ 
  MM_AUX_XOFS_C =    576UL, /**< Offset for tag C */ 
  MM_AUX_XOFS_T =    852UL, /**< Offset for tag T */ 
  MM_AUX_XOFS_X =  49428UL, /**< Offset for tag X */ 
  MM_AUX_XOFS_Z =  98580UL, /**< Offset for tag Z */ 
  MM_AUX_XOFS_Y = 147732UL, /**< Offset for tag Y */ 
  MM_AUX_XLEN_V = 196884UL  /**< Total length of the external representation */
};


/**
  This enumeration defines the values of the tags ``A,B,C,T,X,Z,Y``
  in a vector in the 196884-dimensional representation of the monster,
  stored in the sparse representation.

  In the sparse representation an entry of a vector is stored as a tuple
  of bit  fields ``(tag, par1, par2, value)`` inside an integer of
  type ``uint32_t`` as follows:

      Bits 27,...,25:  tag (as indicated below)
 
      Bits 24,...,14:  par1 (an integer of up to 11 bits)

      Bits 13,..., 8:  par2 (an integer of up to 6 bits)
  
      Bits  7,..., 0:  value (Reserved for the value of an entry)
*/
enum MM_SPACE_TAG {
  MM_SPACE_TAG_A =    0x2000000UL, /**< Encodes tag A */ 
  MM_SPACE_TAG_B =    0x4000000UL, /**< Encodes tag B */
  MM_SPACE_TAG_C =    0x6000000UL, /**< Encodes tag C */
  MM_SPACE_TAG_T =    0x8000000UL, /**< Encodes tag T */
  MM_SPACE_TAG_X =    0xA000000UL, /**< Encodes tag X */
  MM_SPACE_TAG_Z =    0xC000000UL, /**< Encodes tag Z */
  MM_SPACE_TAG_Y =    0xE000000UL  /**< Encodes tag Y */
};



/** @def mm_aux_bad_p(p)
    @brief Return 0 if ``p`` is a good modulus and a nonzero value otherwise 
*/
#define mm_aux_bad_p(p) (((p) & ((p)+1)) | (((p)-3) & ((0UL-256UL))))


/// @cond DO_NOT_DOCUMENT 

// Mask for all tags:
// Use y = (x & MM_SPACE_MASK_PAR1) << MM_SPACE_SHIFT_PAR1
// to set parameter par1 in y to the value x.
#define MM_SPACE_MASK_TAG     0xE000000 
// Mask and shift factor for parameter par1  
// Use y = (x << MM_SPACE_SHIFT_PAR1) & MM_SPACE_MASK_PAR1
// to set parameter par1 in y to the value x.
#define MM_SPACE_MASK_PAR1    0x1FFC000   
#define MM_SPACE_SHIFT_PAR1          14   
// Mask and shift factor for parameter par12  
// Use y = (x << MM_SPACE_SHIFT_PAR2) & MM_SPACE_MASK_PAR2
// to set parameter par2 in y to the value x.
#define MM_SPACE_MASK_PAR2       0x3F00   
#define MM_SPACE_SHIFT_PAR2           8 
// Mask for coordinate:  
// Use y = x  & MM_SPACE_MASK_COORD
// to set the coordiante in y to the value x.
// Caution: some special routines for modulus p = 2**k - 1
// use only the lowest k bits of the coordinate.
#define MM_SPACE_COORD_PAR1    0x1FFC000   

/// @endcond






/// @cond DO_NOT_DOCUMENT 
//  Definitions for using this header in a a DLL (or a shared library)

// Generic helper definitions for DLL (or shared library) support
#if defined(_WIN32) || defined(__CYGWIN__)
  #define MM_OP_DLL_IMPORT __declspec(dllimport)
  #define MM_OP_DLL_EXPORT __declspec(dllexport)
#elif (defined(__GNUC__) || defined(__clang__)) && defined(_WIN32)
  #define MM_OP_DLL_IMPORT __attribute__((noinline,optimize("no-tree-vectorize"),visiblity("default")))
  #define MM_OP_DLL_EXPORT __attribute__((noinline,optimize("no-tree-vectorize"),visiblity("default")))
#else
  #define MM_OP_DLL_IMPORT
  #define MM_OP_DLL_EXPORT
#endif

// Now we use the generic helper definitions above to define MM_OP_API 
// MM_OP_API is used for the public API symbols. It either DLL imports 
// or DLL exports 

#ifdef MM_OP_DLL_EXPORTS // defined if we are building the MM_OP DLL 
  #define MM_OP_API MM_OP_DLL_EXPORT
#else                  // not defined if we are using the MM_OP DLL 
  #define MM_OP_API  MM_OP_DLL_IMPORT
#endif // MM_OP_DLL_EXPORTS

/// @endcond
// %%FROM mm_index.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_extern_to_sparse(uint32_t i);
// %%EXPORT px
MM_OP_API
void mm_aux_array_extern_to_sparse(uint32_t *a, uint32_t len);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_sparse_to_extern(uint32_t i);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_sparse_to_leech(uint32_t i, int32_t *v);
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_sparse_to_leech2(uint32_t i);
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_leech2_to_sparse(uint32_t v2);
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_leech2_to_intern_fast(uint32_t v2);
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_intern_to_sparse(uint32_t i);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_sparse_to_intern(uint32_t i);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_extern_to_intern(uint32_t i);
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_intern_to_leech2(uint32_t i);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_check_intern(uint32_t i);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM mm_aux.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MM_OP_API
uint8_t mm_aux_get_mmv(uint32_t p, uint_mmv_t *mv, uint32_t i);
// %%EXPORT px
MM_OP_API
void mm_aux_put_mmv(uint32_t p, uint8_t value, uint_mmv_t *mv, uint32_t i);
// %%EXPORT px
MM_OP_API
void mm_aux_add_mmv(uint32_t p, uint8_t value, uint_mmv_t *mv, uint32_t i);
// %%EXPORT px
MM_OP_API
void mm_aux_read_mmv32(uint32_t p, uint_mmv_t *mv, uint32_t i, uint8_t *b, uint32_t len);
// %%EXPORT px
MM_OP_API
void mm_aux_write_mmv32(uint32_t p, uint8_t *b, uint_mmv_t *mv, uint32_t i, uint32_t len);
// %%EXPORT px
MM_OP_API
void mm_aux_read_mmv24(uint32_t p, uint_mmv_t *mv, uint32_t i, uint8_t *b, uint32_t len);
// %%EXPORT px
MM_OP_API
void mm_aux_write_mmv24(uint32_t p, uint8_t *b, uint_mmv_t *mv, uint32_t i, uint32_t len);
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_mmv_size(uint32_t p);
// %%EXPORT p
MM_OP_API
uint32_t mm_aux_v24_ints(uint32_t p);
// %%EXPORT px
MM_OP_API
void mm_aux_zero_mmv(uint32_t p, uint_mmv_t *mv);
// %%EXPORT px
MM_OP_API
void mm_aux_random_mmv(uint32_t p, uint_mmv_t *mv, uint64_t *seed);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_reduce_mmv(uint32_t p, uint_mmv_t *mv);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_reduce_mmv_fields(uint32_t p, uint_mmv_t *mv, uint32_t nfields);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_check_mmv(uint32_t p, uint_mmv_t *mv);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_mmv(uint32_t p, uint_mmv_t *mv, uint16_t *a, uint32_t l);
// %%EXPORT px
MM_OP_API
void mm_aux_small24_expand(uint8_t *b_src, uint8_t *b_dest);
// %%EXPORT px
MM_OP_API
void mm_aux_small24_compress(uint8_t *b_src, uint8_t *b_dest);
// %%EXPORT px
MM_OP_API
void mm_aux_mmv_to_bytes(uint32_t p, uint_mmv_t *mv, uint8_t *b);
// %%EXPORT px
MM_OP_API
void mm_aux_bytes_to_mmv(uint32_t p, uint8_t *b, uint_mmv_t *mv);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_mmv_to_sparse(uint32_t p, uint_mmv_t *mv, uint32_t *sp);
// %%EXPORT px
MM_OP_API
void mm_aux_mmv_extract_sparse(uint32_t p, uint_mmv_t *mv, uint32_t *sp, uint32_t length);
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_mmv_get_sparse(uint32_t p, uint_mmv_t *mv, uint32_t sp);
// %%EXPORT px
MM_OP_API
void mm_aux_mmv_add_sparse(uint32_t p, uint32_t *sp, uint32_t length, uint_mmv_t *mv);
// %%EXPORT px
MM_OP_API
void mm_aux_mmv_set_sparse(uint32_t p, uint_mmv_t *mv, uint32_t *sp, uint32_t length);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_mmv_extract_sparse_signs(uint32_t p, uint_mmv_t *mv, uint32_t *sp, uint32_t n);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_leech2_op_word_sparse(uint32_t *q, uint32_t m, uint32_t *g, uint32_t n, uint32_t *qg);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_mmv_extract_x_signs(uint32_t p, uint_mmv_t *mv, uint64_t *elem, uint32_t *a, uint32_t n);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_mul_sparse(uint32_t p, uint32_t *sp, uint32_t length, int64_t f, uint32_t p1, uint32_t *sp1);
// %%EXPORT px
MM_OP_API
int32_t mm_aux_get_mmv_leech2(uint32_t p, uint_mmv_t *mv, uint32_t v2);
// %%EXPORT px
MM_OP_API
uint64_t mm_aux_hash(uint32_t p, uint_mmv_t *mv, uint32_t skip);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM mm_tables.c


/** @struct mm_sub_op_pi64_type "mm_basics.h"

 @brief Auxiliary structure for the structure ``mm_sub_op_pi_type``


 An array of type ``mm_sub_op_pi64_type[759]`` encodes the operation
 of  \f$x_\epsilon x_\pi\f$ on the representation of the monster group
 for entries with tag ``T``. Assume that entry ``(T, i, j)`` is mapped
 to entry ``+-(T, i1, j1)``. Then ``i1`` depends on ``i`` only, and ``j1``
 depends on ``i`` and ``j``. For fixed ``i`` the mapping ``j -> j1`` is
 linear if we consider the binary numbers ``j`` and ``j1`` as bit vectors.

 Entry ``i1`` of the array of type ``mm_sub_op_pi64_type[759]``
 describes the preimage of ``(T, i1, j1)`` for all ``0 <= j1 < 64``
 as documented in the description of the members ``preimage``
 and  ``perm``.
 
 Note that the values 1, 3, 7, 15, 31, 63 occur as
 differences `` j1 ^ (j1 - 1)`` when counting ``j1`` from 0 up to 63. So the
 preimage of ``(T, i1, j1)`` can be computed from the preimage
 of ``(T, i1, j1 - 1)`` using linearity and the approprate entry in
 member perm.

 We remark that in case of an odd value epsilon the mapping for tag ``T``
 requires a postprocessing step that cannot be derived from the
 infomration in this structure. Then entry ``(T, i, j)`` has to be negated
 if the bit weight of the subset of octade ``i`` corresponding to
 index ``j`` has bit weight 2 modulo 4.
 
 In the sequel we describe the meaning of entry ``i1`` an an array of 
 elements of type ``mm_sub_op_pi64_type``.
*/
typedef struct {
   /**
   Bits 9...0 : preimage ``i`` such that ``(T, i, .)`` maps to ``+-(T, i1, .)``

   Bit 12: sign bit: ``(T, i, .)`` maps to ``-(T, i1, .)`` if bit 12 is set
   */
   uint16_t preimage;
   /**
   Member ``perm[k]`` is a value ``v ``such that ``(T, i, v)`` maps 
   to ``+-(T, i1, 2 * 2**k - 1)``
   */
   uint8_t perm[6];
} mm_sub_op_pi64_type;


/** @struct mm_sub_op_pi_type "mm_basics.h"

 @brief Structure used for preparing an operation \f$x_\epsilon  x_\pi\f$

 Function ``mm_sub_prep_pi`` computes some tables required for the operation
 of \f$x_\epsilon  x_\pi\f$ on the representation of the monster group, and
 stores these tables in a structure of type ``mm_sub_op_pi_type``.

 The structure of type ``mm_sub_op_pi_type`` has the following members:
*/
typedef struct {
    /**
       A 12-bit integer describing an element  \f$\epsilon\f$ of
       the Golay cocode.
    */
    uint32_t eps; 
    /**
      An integer describing the element \f$\pi\f$ of the Mathieu
      group \f$M_{24}\f$ as in module ``mat24_functions.c``.
    */    
    uint32_t pi;
    /**
      The permutation ``0...23 -> 0...23`` given by the
      element \f$\pi\f$ of \f$M_{24}\f$.
    */
    uint8_t perm[24];
    /**
      The inverse of the permutation ``perm``.
    */
    uint8_t inv_perm[24];
    /**
      A representation of Benes network for computing permutationperm, as
      described in function ``mat24_perm_to_net`` in
      file ``mat24_functions.c``.    
    */
    uint32_t benes_net[9];
    
    /**
      For tags ``A, B, C, X, Y, Z``, an entry ``(tag, i, j)`` of the
      representation of the monster is mapped to entry ``(tag1, i1, j1)``,
      with ``i1`` depending on ``i`` (and the tag), and ``j1``
      depending on ``j`` only.

      If ``tbl_perm24_big[i1] & 0x7ff = i`` for ``0 <= i1 < 2048``
      then ``(tag, i, j)`` ia mapped to ``(Tag, i1, perm[j])``, up to sign,
      for tags ``X``, ``Y`` and ``Z``. In case of an odd \f$\epsilon\f$,
      tags ``Y`` and ``Z`` have to be exchanged. The
      value ``tbl_perm24_big[2048 + 24*k + i1] & 0x7ff`` describes the
      preimage of ``(tag, i1, j1)`` in a similar way,
      where ``tag = A, B, C``, for ``k = 0, 1, 2``.

      Bits 12,...,15 of ``tbl_perm24_big[i1]`` encode the signs of the
      preimages of the corresponding entry of the rep. Bits 12, 13, and 14
      refer to the signs for the preimages for the tags ``X``, ``Z``
      and ``Y``, respectively. Bit 15 refers to the signs for the preimages
      for tags ``A``, ``B`` and ``C``. If the corresponding bit is set,
      the preimage has to be negated.

      Note that function ``mat24_op_all_autpl`` in
      module ``mat24_functions.c computes``the first 2048 entries of
      the table.
    */
    uint16_t tbl_perm24_big[2048+72];
    
    /**
       A description of the operation of \f$x_\epsilon  x_\pi\f$ on the
       entries with tag ``T``,  see structure ``mm_sub_op_pi64_type``.
       Entry ``d`` of the Arrary refers to the octad ``o(d)`` with 
       number ``d``. It contains the followint information_
       
       Bits 5,...,0: Associator ``\delta' = A(o(d), f))`` encoded as a suboctad
       
       Bits 11,...,6: Associator ``a = A(o(d), ef))`` encoded as a suboctad.

       Caution:

       Pointer ``tbl_perm64`` must be initialized with an array 
       of type ``mm_sub_op_pi64_type a_tbl_perm64[759]``.
    */
    mm_sub_op_pi64_type *tbl_perm64;
} mm_sub_op_pi_type;


/** @struct mm_sub_op_xy_type "mm_basics.h"

  @brief Structure used for preparing an operation \f$y_f x_e x_\epsilon\f$
  
  The operation of \f$g = y_f x_e x_\epsilon\f$, (or, more precisely, of its 
  inverse \f$g^{-1}\f$) on the representation of the monster group is 
  described in section **Implementing generators of the Monster group** in 
  the **The mmgroup guide for developers**. 
  
  Function ``mm_sub_prep_xy`` in file ``mm_tables.c`` collects the data
  required for this operation in a structure of type ``mm_sub_op_xy_type``.

*/
typedef struct {
    /**
       A 13-bit integer describing an element  \f$f\f$ of the Parker loop.
    */
    uint32_t f;            
    /**
       A 13-bit integer describing an element  \f$e\f$ of the Parker loop.
    */
    uint32_t e;
    /**
       A 12-bit integer describing an element  \f$\epsilon\f$ of
       the Golay cocode.
    */
    uint32_t eps;
    /**
       Bit \f$i\f$ of member ``f_i`` is the scalar product of \f$f\f$ and
       the singleton cocode word  \f$(i)\f$.
       
       These bits are used for the operation of  \f$g^{-1}\f$ on
       entries with tag ``A``.
    */
    uint32_t f_i;
    /**
       Bit \f$i\f$ of member ``ef_i`` is the scalar product of \f$ef\f$ and
       the singleton cocode word  \f$(i)\f$.
       
       These bits are used for the operation of  \f$g^{-1}\f$ on
       entries with tags ``B``, and ``C``.
    */
    uint32_t ef_i;
    /**
       Put  \f$g_0 = e\f$,  \f$g_1 = g_2 = f\f$.
       For ``k = 0, 1,2``, the bit \f$i\f$ of member ``lin_i[k]`` is the scalar
       product of \f$g_k\f$ and  the singleton cocode word  \f$(i)\f$.
       
       These bits are used for the operation of  \f$g^{-1}\f$ on
       entries with tags ``X``, ``Z``, and ``Y``.
    */
    uint32_t lin_i[3];
    /**
       Let ``U_k = X, Z, Y`` for ``k = 0, 1, 2``. If the cocode
       element \f$\epsilon\f$ is even then we put ``U'_k = U_k``, otherwise 
       we put  ``U'_k = X, Y, Z``   for ``k = 0, 1, 2``. The
       operation \f$g^{-1}\f$ maps the vector with tag ``(U_k, d, i)`` 
       to ``(-1)**s`` times the vector with tag ``(U'_k, d ^ lin[d], i)``. 
       Here ``**`` denotes exponentiation and we have
       
       ``s`` =  ``s(k, d, i)`` = ``(lin_i[k] >> i) + (sign_XYZ[d] >> k)``.

       If ``k = 0`` and \f$\epsilon\f$  is odd then we have to 
       correct ``s(k, d, i)``  by a  term ``<d, i>``.
    */
    uint32_t lin_d[3];
    /**
       Pointer ``sign_XYZ`` refers to an array of length 2048. This is
       used for calculations of signs as described above. Here we use the
       formula in section **Implementing generators of the Monster group**
       of the  **mmgroup guide for developers**, dropping all terms
       depending on ``i``.
    */
    uint8_t *sign_XYZ;
    /**
       Pointer ``s_T`` refers to an array of length 759.  Entry ``d`` 
       of this array refers to the octad ``o(d)``  with number ``d``. 
       The bits of entry ``d`` are interpreted as follows: 
    
       Bits 5,...,0: The asscociator ``delta' = A(o(d), f)`` encoded
       as a suboctad of octad ``o(d))``.
       
       Bits 13,...,8: The asscociator ``alpha = A(o(d), ef)`` encoded
       as a suboctad of octad ``o(d))``. From his information we can
       compute the scalar product ``<ef, \delta>`` for each suboctad 
       ``delta`` of ``o(d)`` as an  intersection of tow suboctads.
       Here we assume that ``delta`` is represented as such a suboctad.
       
       Bit 14: The sign bit ``s(d) = P(d) + P(de) + <d, eps>``, where
       ``P(.)`` is the squaring map in the Parker loop.
       
       Bit 15: Parity bit ``|eps|`` of the cocode word ``eps``.
       
       Then \f$g^{-1}\f$ maps the vector with tag ``(T, d, delta)`` 
       to ``(-1)**s'`` times  the vector with 
       tag ``(T, d, \delta ^ delta')``. 
       Here ``**`` denotes exponentiation and we have
       
       ``s'`` = ``s'(T, d, delta)`` 
       = ``s(d)`` + ``<\alpha, \delta>`` + ``|delta| * |eps| / 2``. 
       
       Here the product ``<\alpha, \delta>`` must be computed as the
       bit length of an intersection of two suboctads.        
    */
    uint16_t *s_T;
} mm_sub_op_xy_type;

#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT 
MM_OP_API
void  mm_sub_prep_pi(uint32_t eps, uint32_t pi, mm_sub_op_pi_type *p_op);
// %%EXPORT px
MM_OP_API
int32_t mm_sub_test_prep_pi_64(uint32_t eps, uint32_t pi, uint32_t *p_tbl);
// %%EXPORT 
MM_OP_API
void  mm_sub_prep_xy(uint32_t f, uint32_t e, uint32_t eps, mm_sub_op_xy_type *p_op);
// %%EXPORT px
MM_OP_API
void  mm_sub_test_prep_xy(uint32_t f, uint32_t e, uint32_t eps, uint32_t n, uint32_t *p_tbl);
// %%EXPORT_TABLE 
MM_OP_API
extern uint64_t TABLE_OCTAD_TO_STD_AX_OP[];
// %%EXPORT px
MM_OP_API
int32_t mm_sub_table_octad_to_std_ax_op(uint32_t o);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM mm_group_word.c

/// @cond DO_NOT_DOCUMENT 

typedef struct {
    // public members:
    uint32_t data[6];
    uint32_t lookahead;
    // private members: storing input parameters
    uint32_t *g;
    int32_t e;
      // int32_t len_g; // not needed
    // private members: counters:
    int32_t index;
    // private members: compensations for negative exponents
    int32_t i_start;
    int32_t i_stop;
    int32_t i_step; 
    int32_t sign; 
} mm_group_iter_t;

/// @endcond

#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT 
MM_OP_API
void mm_group_iter_start(mm_group_iter_t *pit, uint32_t *g, int32_t len_g, int32_t e);
// %%EXPORT 
MM_OP_API
uint32_t  mm_group_iter_next(mm_group_iter_t *pit);
// %%EXPORT px
MM_OP_API
int32_t mm_group_prepare_op_ABC(uint32_t *g, uint32_t len_g, uint32_t *a);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM mm_tables_xi.c
/// @cond DO_NOT_DOCUMENT 

// Structure used for referring to tables for operator xi
// See corresponding comment in file mm_tables_xi.c
typedef struct {
   uint16_t *p_perm;
   uint32_t *p_sign;
} mm_sub_table_xi_type;
/// @endcond
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT_TABLE  
MM_OP_API
extern mm_sub_table_xi_type MM_SUB_TABLE_XI[5][2];
// %%EXPORT_TABLE  
MM_OP_API
extern uint32_t MM_SUB_OFFSET_TABLE_XI[5][2][2];
// %%EXPORT px
MM_OP_API
uint32_t mm_sub_get_table_xi(uint32_t i, uint32_t e, uint32_t j, uint32_t k);
// %%EXPORT px
MM_OP_API
uint32_t mm_sub_get_offset_table_xi(uint32_t i, uint32_t e, uint32_t j);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM mm_crt.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MM_OP_API
uint32_t mm_crt_combine(uint_mmv_t *p7, uint_mmv_t *p31, uint_mmv_t *p127, uint_mmv_t *p255, int32_t *p_out);
// %%EXPORT px
MM_OP_API
uint32_t mm_crt_combine_bytes(uint8_t *p7, uint8_t *p31, uint8_t *p127, uint8_t *p255, uint32_t n, int32_t *p_out);
// %%EXPORT px
MM_OP_API
uint32_t mm_crt_check_v2(uint_mmv_t *p7, uint_mmv_t *p31, uint_mmv_t *p127, uint_mmv_t *p255);
// %%EXPORT px
MM_OP_API
uint32_t mm_crt_check_g(uint32_t g, uint_mmv_t *p7, uint_mmv_t *p31, uint_mmv_t *p127, uint_mmv_t *p255);
// %%EXPORT px
MM_OP_API
int64_t mm_crt_norm_int32_32(int32_t *pv, uint32_t i0, uint32_t i1);
// %%EXPORT px
MM_OP_API
int64_t mm_crt_norm_int32(int32_t *pv);
// %%EXPORT px
MM_OP_API
uint32_t mm_crt_v2_int32_32(int32_t *pv, uint32_t i0, uint32_t i1);
// %%EXPORT px
MM_OP_API
uint32_t mm_crt_v2_int32(int32_t *pv);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%INCLUDE_HEADERS




#endif  // #ifndef MM_BASICS_H



