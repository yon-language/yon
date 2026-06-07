// Warning: This file has been generated automatically. Do not change!

/// @cond DO_NOT_DOCUMENT 
#define MM_OP_DLL_EXPORTS 
/// @endcond

/** @file mm_index.c

 File ``mm_index.c`` provides the basic functions for converting 
 an index of a vector of the 196884-dimensional representation
 of the monster between internal, external, and sparse notation.


*/



/// @cond DO_NOT_DOCUMENT 
#include <stdlib.h>
#include "clifford12.h"
#include "mm_basics.h"
/// @endcond  





/// @cond DO_NOT_DOCUMENT 


/**************************************************************
Table for expanding entries for tags 'A', 'B', 'C'.

Entry k0 of the external representation of the monster is
mapped to location k1 in the internal representation with
k1 = (Table[k0] & 0x7ff) + k0 - 24. Entry k0 is also copied 
to location k1 - 31 * (Table[k0] >> 11) of the internal rep.
**************************************************************/

static const uint16_t MM_AUX_TBL_ABC[] = {
// %%TABLE MM_AUX_TBL_ABC, uint16
0x0018,0x0038,0x0058,0x0078,0x0098,0x00b8,0x00d8,0x00f8,
0x0118,0x0138,0x0158,0x0178,0x0198,0x01b8,0x01d8,0x01f8,
0x0218,0x0238,0x0258,0x0278,0x0298,0x02b8,0x02d8,0x02f8,
0x0820,0x103f,0x083f,0x185d,0x105d,0x085d,0x207a,0x187a,
0x107a,0x087a,0x2896,0x2096,0x1896,0x1096,0x0896,0x30b1,
0x28b1,0x20b1,0x18b1,0x10b1,0x08b1,0x38cb,0x30cb,0x28cb,
0x20cb,0x18cb,0x10cb,0x08cb,0x40e4,0x38e4,0x30e4,0x28e4,
0x20e4,0x18e4,0x10e4,0x08e4,0x48fc,0x40fc,0x38fc,0x30fc,
0x28fc,0x20fc,0x18fc,0x10fc,0x08fc,0x5113,0x4913,0x4113,
0x3913,0x3113,0x2913,0x2113,0x1913,0x1113,0x0913,0x5929,
0x5129,0x4929,0x4129,0x3929,0x3129,0x2929,0x2129,0x1929,
0x1129,0x0929,0x613e,0x593e,0x513e,0x493e,0x413e,0x393e,
0x313e,0x293e,0x213e,0x193e,0x113e,0x093e,0x6952,0x6152,
0x5952,0x5152,0x4952,0x4152,0x3952,0x3152,0x2952,0x2152,
0x1952,0x1152,0x0952,0x7165,0x6965,0x6165,0x5965,0x5165,
0x4965,0x4165,0x3965,0x3165,0x2965,0x2165,0x1965,0x1165,
0x0965,0x7977,0x7177,0x6977,0x6177,0x5977,0x5177,0x4977,
0x4177,0x3977,0x3177,0x2977,0x2177,0x1977,0x1177,0x0977,
0x8188,0x7988,0x7188,0x6988,0x6188,0x5988,0x5188,0x4988,
0x4188,0x3988,0x3188,0x2988,0x2188,0x1988,0x1188,0x0988,
0x8998,0x8198,0x7998,0x7198,0x6998,0x6198,0x5998,0x5198,
0x4998,0x4198,0x3998,0x3198,0x2998,0x2198,0x1998,0x1198,
0x0998,0x91a7,0x89a7,0x81a7,0x79a7,0x71a7,0x69a7,0x61a7,
0x59a7,0x51a7,0x49a7,0x41a7,0x39a7,0x31a7,0x29a7,0x21a7,
0x19a7,0x11a7,0x09a7,0x99b5,0x91b5,0x89b5,0x81b5,0x79b5,
0x71b5,0x69b5,0x61b5,0x59b5,0x51b5,0x49b5,0x41b5,0x39b5,
0x31b5,0x29b5,0x21b5,0x19b5,0x11b5,0x09b5,0xa1c2,0x99c2,
0x91c2,0x89c2,0x81c2,0x79c2,0x71c2,0x69c2,0x61c2,0x59c2,
0x51c2,0x49c2,0x41c2,0x39c2,0x31c2,0x29c2,0x21c2,0x19c2,
0x11c2,0x09c2,0xa9ce,0xa1ce,0x99ce,0x91ce,0x89ce,0x81ce,
0x79ce,0x71ce,0x69ce,0x61ce,0x59ce,0x51ce,0x49ce,0x41ce,
0x39ce,0x31ce,0x29ce,0x21ce,0x19ce,0x11ce,0x09ce,0xb1d9,
0xa9d9,0xa1d9,0x99d9,0x91d9,0x89d9,0x81d9,0x79d9,0x71d9,
0x69d9,0x61d9,0x59d9,0x51d9,0x49d9,0x41d9,0x39d9,0x31d9,
0x29d9,0x21d9,0x19d9,0x11d9,0x09d9,0xb9e3,0xb1e3,0xa9e3,
0xa1e3,0x99e3,0x91e3,0x89e3,0x81e3,0x79e3,0x71e3,0x69e3,
0x61e3,0x59e3,0x51e3,0x49e3,0x41e3,0x39e3,0x31e3,0x29e3,
0x21e3,0x19e3,0x11e3,0x09e3,0x0a0c,0x122b,0x0a2b,0x1a49,
0x1249,0x0a49,0x2266,0x1a66,0x1266,0x0a66,0x2a82,0x2282,
0x1a82,0x1282,0x0a82,0x329d,0x2a9d,0x229d,0x1a9d,0x129d,
0x0a9d,0x3ab7,0x32b7,0x2ab7,0x22b7,0x1ab7,0x12b7,0x0ab7,
0x42d0,0x3ad0,0x32d0,0x2ad0,0x22d0,0x1ad0,0x12d0,0x0ad0,
0x4ae8,0x42e8,0x3ae8,0x32e8,0x2ae8,0x22e8,0x1ae8,0x12e8,
0x0ae8,0x52ff,0x4aff,0x42ff,0x3aff,0x32ff,0x2aff,0x22ff,
0x1aff,0x12ff,0x0aff,0x5b15,0x5315,0x4b15,0x4315,0x3b15,
0x3315,0x2b15,0x2315,0x1b15,0x1315,0x0b15,0x632a,0x5b2a,
0x532a,0x4b2a,0x432a,0x3b2a,0x332a,0x2b2a,0x232a,0x1b2a,
0x132a,0x0b2a,0x6b3e,0x633e,0x5b3e,0x533e,0x4b3e,0x433e,
0x3b3e,0x333e,0x2b3e,0x233e,0x1b3e,0x133e,0x0b3e,0x7351,
0x6b51,0x6351,0x5b51,0x5351,0x4b51,0x4351,0x3b51,0x3351,
0x2b51,0x2351,0x1b51,0x1351,0x0b51,0x7b63,0x7363,0x6b63,
0x6363,0x5b63,0x5363,0x4b63,0x4363,0x3b63,0x3363,0x2b63,
0x2363,0x1b63,0x1363,0x0b63,0x8374,0x7b74,0x7374,0x6b74,
0x6374,0x5b74,0x5374,0x4b74,0x4374,0x3b74,0x3374,0x2b74,
0x2374,0x1b74,0x1374,0x0b74,0x8b84,0x8384,0x7b84,0x7384,
0x6b84,0x6384,0x5b84,0x5384,0x4b84,0x4384,0x3b84,0x3384,
0x2b84,0x2384,0x1b84,0x1384,0x0b84,0x9393,0x8b93,0x8393,
0x7b93,0x7393,0x6b93,0x6393,0x5b93,0x5393,0x4b93,0x4393,
0x3b93,0x3393,0x2b93,0x2393,0x1b93,0x1393,0x0b93,0x9ba1,
0x93a1,0x8ba1,0x83a1,0x7ba1,0x73a1,0x6ba1,0x63a1,0x5ba1,
0x53a1,0x4ba1,0x43a1,0x3ba1,0x33a1,0x2ba1,0x23a1,0x1ba1,
0x13a1,0x0ba1,0xa3ae,0x9bae,0x93ae,0x8bae,0x83ae,0x7bae,
0x73ae,0x6bae,0x63ae,0x5bae,0x53ae,0x4bae,0x43ae,0x3bae,
0x33ae,0x2bae,0x23ae,0x1bae,0x13ae,0x0bae,0xabba,0xa3ba,
0x9bba,0x93ba,0x8bba,0x83ba,0x7bba,0x73ba,0x6bba,0x63ba,
0x5bba,0x53ba,0x4bba,0x43ba,0x3bba,0x33ba,0x2bba,0x23ba,
0x1bba,0x13ba,0x0bba,0xb3c5,0xabc5,0xa3c5,0x9bc5,0x93c5,
0x8bc5,0x83c5,0x7bc5,0x73c5,0x6bc5,0x63c5,0x5bc5,0x53c5,
0x4bc5,0x43c5,0x3bc5,0x33c5,0x2bc5,0x23c5,0x1bc5,0x13c5,
0x0bc5,0xbbcf,0xb3cf,0xabcf,0xa3cf,0x9bcf,0x93cf,0x8bcf,
0x83cf,0x7bcf,0x73cf,0x6bcf,0x63cf,0x5bcf,0x53cf,0x4bcf,
0x43cf,0x3bcf,0x33cf,0x2bcf,0x23cf,0x1bcf,0x13cf,0x0bcf,
0x0bf8,0x1417,0x0c17,0x1c35,0x1435,0x0c35,0x2452,0x1c52,
0x1452,0x0c52,0x2c6e,0x246e,0x1c6e,0x146e,0x0c6e,0x3489,
0x2c89,0x2489,0x1c89,0x1489,0x0c89,0x3ca3,0x34a3,0x2ca3,
0x24a3,0x1ca3,0x14a3,0x0ca3,0x44bc,0x3cbc,0x34bc,0x2cbc,
0x24bc,0x1cbc,0x14bc,0x0cbc,0x4cd4,0x44d4,0x3cd4,0x34d4,
0x2cd4,0x24d4,0x1cd4,0x14d4,0x0cd4,0x54eb,0x4ceb,0x44eb,
0x3ceb,0x34eb,0x2ceb,0x24eb,0x1ceb,0x14eb,0x0ceb,0x5d01,
0x5501,0x4d01,0x4501,0x3d01,0x3501,0x2d01,0x2501,0x1d01,
0x1501,0x0d01,0x6516,0x5d16,0x5516,0x4d16,0x4516,0x3d16,
0x3516,0x2d16,0x2516,0x1d16,0x1516,0x0d16,0x6d2a,0x652a,
0x5d2a,0x552a,0x4d2a,0x452a,0x3d2a,0x352a,0x2d2a,0x252a,
0x1d2a,0x152a,0x0d2a,0x753d,0x6d3d,0x653d,0x5d3d,0x553d,
0x4d3d,0x453d,0x3d3d,0x353d,0x2d3d,0x253d,0x1d3d,0x153d,
0x0d3d,0x7d4f,0x754f,0x6d4f,0x654f,0x5d4f,0x554f,0x4d4f,
0x454f,0x3d4f,0x354f,0x2d4f,0x254f,0x1d4f,0x154f,0x0d4f,
0x8560,0x7d60,0x7560,0x6d60,0x6560,0x5d60,0x5560,0x4d60,
0x4560,0x3d60,0x3560,0x2d60,0x2560,0x1d60,0x1560,0x0d60,
0x8d70,0x8570,0x7d70,0x7570,0x6d70,0x6570,0x5d70,0x5570,
0x4d70,0x4570,0x3d70,0x3570,0x2d70,0x2570,0x1d70,0x1570,
0x0d70,0x957f,0x8d7f,0x857f,0x7d7f,0x757f,0x6d7f,0x657f,
0x5d7f,0x557f,0x4d7f,0x457f,0x3d7f,0x357f,0x2d7f,0x257f,
0x1d7f,0x157f,0x0d7f,0x9d8d,0x958d,0x8d8d,0x858d,0x7d8d,
0x758d,0x6d8d,0x658d,0x5d8d,0x558d,0x4d8d,0x458d,0x3d8d,
0x358d,0x2d8d,0x258d,0x1d8d,0x158d,0x0d8d,0xa59a,0x9d9a,
0x959a,0x8d9a,0x859a,0x7d9a,0x759a,0x6d9a,0x659a,0x5d9a,
0x559a,0x4d9a,0x459a,0x3d9a,0x359a,0x2d9a,0x259a,0x1d9a,
0x159a,0x0d9a,0xada6,0xa5a6,0x9da6,0x95a6,0x8da6,0x85a6,
0x7da6,0x75a6,0x6da6,0x65a6,0x5da6,0x55a6,0x4da6,0x45a6,
0x3da6,0x35a6,0x2da6,0x25a6,0x1da6,0x15a6,0x0da6,0xb5b1,
0xadb1,0xa5b1,0x9db1,0x95b1,0x8db1,0x85b1,0x7db1,0x75b1,
0x6db1,0x65b1,0x5db1,0x55b1,0x4db1,0x45b1,0x3db1,0x35b1,
0x2db1,0x25b1,0x1db1,0x15b1,0x0db1,0xbdbb,0xb5bb,0xadbb,
0xa5bb,0x9dbb,0x95bb,0x8dbb,0x85bb,0x7dbb,0x75bb,0x6dbb,
0x65bb,0x5dbb,0x55bb,0x4dbb,0x45bb,0x3dbb,0x35bb,0x2dbb,
0x25bb,0x1dbb,0x15bb,0x0dbb
};



/// @endcond  





// %%GEN ch
#ifdef __cplusplus
extern "C" {
#endif
// %%GEN c

//  %%GEN h
//  %%GEN c








/**********************************************************************
*** Index conversion between external and sparse rep of vectors in R_p
**********************************************************************/


/**
  @brief Convert an index from external to sparse representation

  The function converts an index ``i`` for the external representation 
  of a vector to an index for the sparse representation of a vector
  and returns the converted index. The function returns 0 in case
  ``i >= 196884``. 

  Indices for the sparse representation are defined as 
  in ``enum MM_SPACE_TAG`` in file ``mm_basics.h``.
*/
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_extern_to_sparse(uint32_t i)
// Convert external index i to sparse index.
// Return 0 if index i is bad
{
    if (i <  MM_AUX_XOFS_X) {
        if (i <  MM_AUX_XOFS_T) {
            // Tags A, B, C
            i = (MM_AUX_TBL_ABC[i] & 0x7ff) + i - 24;
            // put i += (i / 0x300) * 0x100; assuming 0 <= i < 0x900 
            i += (0x2A54000 >> ((i >> 8) << 1)) & 0x300;
            // now 0 <= i < 0xc00. output bits of old i as 
            // (tag - 1) = bits 11..10, i = bits 9..5, j = bits 4..0
            return 0x2000000 + ((i & 0xc00) << 15) +
                   ((i & 0x3e0) << 9) + ((i & 0x1f) << 8);
        } else {
            // Tag T
            i += 0x80000 - MM_AUX_XOFS_T;
            return i << 8;
        } 
    } else if (i <  MM_AUX_XLEN_V) {
        // Tags X, Z, Y
        i -=  MM_AUX_XOFS_X;
        // Put i += 8 * floor(i/24), for i <  3 * 2048 * 24
        i += (((i >> 3) * 0xaaab) >> 17) << 3; 
        // shift bits 17..5 of i to bit positions 18...6
        i += i & 0x3ffe0;
        i += 0xA0000;
        return i << 8;
    } else return 0;
}


/**
  @brief Convert index array from external to sparse representation

  The function converts an array ``a`` of indices for the external 
  representation to an array of indices for the sparse representation 
  of a vector. All indices in the array ``a`` of length ``len`` are
  converted in place, using function ``mm_aux_index_extern_to_sparse``.
*/
// %%EXPORT px
MM_OP_API
void mm_aux_array_extern_to_sparse(uint32_t *a, uint32_t len)
{
    for(; len--; ++a) *a = mm_aux_index_extern_to_sparse(*a); 
}


/**
  @brief Convert an index from sparse to external representation

  The function converts an index ``i`` for the sparse representation 
  of a vector to an index for the external representation of a vector
  and returns the converted index. The function returns -1 if the
  input ``i`` denotes an illegal index. The coordinate value encoded
  in the input ``i`` is ignored.
 
  Indices for the sparse representation are defined as 
  in ``enum MM_SPACE_TAG`` in file ``mm_basics.h``.
*/
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_sparse_to_extern(uint32_t i)
{
    uint_fast32_t tag = i >> 25, j = (i >> 8) & 0x3f;
    i = (i >> 14) & 0x7ff;
    switch (tag) {
        case 2:  // tag B
        case 3:  // tag C
            if (i == j) return -1;
            // Fall trough to case tag A
        case 1:  // tag A
            if (i >= 24 || j >= 24) return -1;
            if (i == j) return i;
            return  MM_AUX_XOFS_A - 276 + tag * 276 
                  + ((i * i - i) >> 1) + j;
        case 4:  // tag T
            if (i >= 759) return -1;
            return MM_AUX_XOFS_T + (i << 6) + j;
        case 5:  // tag X
        case 6:  // tag Z
        case 7:  // tag Y
            if (j >= 24) return -1;
            return  MM_AUX_XOFS_X - 0x3c000
                + 24 * ((tag << 11) + i) + j; 
        default:
            return -1;
    }
}

/**
  @brief Convert sparse index to a short vector in the Leech lattice

  The function converts an index ``i`` for the sparse representation
  of a vector to a vector ``v`` in the Leech lattice. This conversion 
  is successful if ``i`` denotes a legal index for one of the tags
  tags ``B, C, T, X``. Then the function computes a short Leech 
  lattice vector  (scaled to norm 32)  in the array ``v``. 
  Output ``v`` is determined up to sign only; that sign is 
  implementation dependent.

  The function returns 0 in case of a successful conversion and -1
  in case of failure.
*/
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_sparse_to_leech(uint32_t i, int32_t *v)
// Convert sparse index i to a short vector v in the Leech lattice.
// Vector v has norm 32. The sign of v is implementation dependent.
// Return -1 if index i is bad or does not map to a short vector
{
    uint_fast32_t tag = i >> 25, j = (i >> 8) & 0x3f, k, w, u_sub, coc;
    i = (i >> 14) & 0x7ff;
    switch (tag) {
        case 2:  // tag B
        case 3:  // tag C
            if (i == j || i >= 24 || j >= 24) return -1;
            for (k = 0; k < 24; ++k) v[k] = 0;
            v[i] = v[j] = 4;
            if (i < j) i = j;
            if ((tag & 1) == 0) v[i] = -4;
            return 0;
        case 4:  // tag T
            coc = mat24_inline_suboctad_to_cocode(j, i);
            w = mat24_octad_to_vect(i);
            if (coc >= 0x800) return -1;
            u_sub = mat24_cocode_syndrome(coc, MAT24_OCTAD_ELEMENT_TABLE[8*i]);
            for (k = 0; k < 24; ++k) v[k] = 
                 2 * ((w >> k) & 1) - 4 * ((u_sub >> k) & 1);
            return 0;
        case 5:  // tag X
            if (j >= 24) return -1;
            w = mat24_gcode_to_vect(i);
            for (k = 0; k < 24; ++k) v[k] = 1 - 2 * ((w >> k) & 1);
            v[j] = v[j] < 0 ? 3 : -3;
            return  0; 
        default:
            return -1;
    }
}


/**
  @brief Convert sparse index to a short vector in the Leech lattice mod 2

  The function converts an index ``i`` for the sparse representation
  of a vector to a vector ``v`` in the Leech lattice mod 2. This 
  conversion  is successful if ``i`` denotes a legal index for one of 
  the tags tags ``B, C, T, X``. The function returns a short Leech 
  lattice vector modulo 2, encoded in **Leech lattice encoding**, as
  described in 
  section **Description of the mmgroup.generators extension**. 

  The function returns 0 in case of failure.
*/
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_sparse_to_leech2(uint32_t i)
{
    uint_fast32_t tag = i >> 25, j = (i >> 8) & 0x3f,  res = 0;
    i = (i >> 14) & 0x7ff;
    switch (tag) {
        case 3:  // tag C
            res = 0x800000;
        case 2:  // tag B
            if (i == j || i >= 24 || j >= 24) return 0;
            return res + mat24_vect_to_cocode((1 << i) ^ (1 << j));
        case 4:  // tag T
            if (i >= 759) return 0;
            {
                uint_fast32_t gcode, cocode;
                cocode = mat24_inline_suboctad_to_cocode(j, i);
                gcode = MAT24_OCT_DEC_TABLE[i] & 0xfff;
                gcode ^= mat24_def_suboctad_weight(j) << 11;
                cocode ^= MAT24_THETA_TABLE[gcode & 0x7ff] & 0xfff;
                res = (gcode << 12) + cocode;
            }
            return res;
        case 5:  // tag X
            if (j >= 24) return 0;
            {
                uint_fast32_t w, gcode, cocode, theta;
                cocode = mat24_vect_to_cocode(1 << j);
                theta = MAT24_THETA_TABLE[i & 0x7ff];
                w = ((theta >> 12) & 1) ^ (i & cocode);
                w = mat24_def_parity12(w);
                gcode = i ^ (w << 11); 
                cocode ^= theta & 0xfff;
                res = (gcode << 12) + cocode;
            }
            return res;
        default:
            return 0;
    }
}





/**
  @brief Convert short vector in the Leech lattice mod 2 to sparse rep

  The function converts a value ``v2`` representing a vector in
  the Leech lattice mod 2 to a sparse index and returns that sparse
  index. It returns 0 if ``v2`` is not a short Leech lattice vector.
*/
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_leech2_to_sparse(uint32_t v2)
{
    uint_fast32_t theta, syn, scalar, gc, res;

    // in the sequel we cut and paste the code for the detection of 
    // a short vector v2 in the Leech lattice mod 2 from 
    // function ``gen_leech2_type2`` in file ``gen_leech.c``.
    // After detecting such a short vector we convert that
    // vector to a sparse index.

    // Deal with odd cocode words
    if (v2 & 0x800) {   // Deal with odd cocode words
         // Let syn be the syndrome table entry for the cocode part
         theta = MAT24_THETA_TABLE[(v2 >> 12) & 0x7ff];
         syn = MAT24_SYNDROME_TABLE[(theta ^ v2) & 0x7ff];
         // Return 0 if syn does not encode a cocode word of length 1
         if ((syn & 0x3ff) < (24 << 5)) return 0;
         // Return  0 if scalar product <code, cocode> == 1  (mod 2)
         scalar = (v2 >> 12) &  v2;
         scalar = mat24_def_parity12(scalar);
         if (scalar) return 0;
         // Here v2 is a short vector of shape (3^1,^1^23)
         // Return sparse vector with tag X
         return 0xA000000 + ((v2 & 0x7ff000) << 2) + ((syn & 0x1f) << 8);
    }
    // Deal with Golay code word 0
    if ((v2 & 0x7ff000L) == 0) {
         // Let syn be the syndrome table entry for the cocode part 
         syn = MAT24_SYNDROME_TABLE[v2 & 0x7ff];
         // Return 1 iff tab does not encode a cocode word of length 2
         if ((syn & 0x8000) == 0) return 0;

         // Compute cocode entries of v2
         syn = MAT24_SYNDROME_TABLE[(v2 ^ MAT24_RECIP_BASIS[23]) & 0x7ff];
         syn &= 0x3ff;
         // Bits 9..5 and bits 4..0 contain high and low cocode bit index.
         // Change a high cocode bit index 24 to 23.
         syn -= ((syn + 0x100) & 0x400) >> 5;

         // Return sparse vector with tag B is bit 23 of v2 is 0
         // and with tag C otherwise.
         return  ((syn >> 5) << 14) + ((syn & 0x1f) << 8) + 0x4000000 
                 + ((0x800000 & v2) << 2);
    }

    // Deal with octads (and suboctads)
    gc = (v2 >> 12) & 0xfff;
    theta = MAT24_THETA_TABLE[gc & 0x7ff] & 0x7ff;
    res = mat24_inline_cocode_to_suboctad((v2 ^ theta) & 0xfff, gc, 1);
    if (res == 0xffffffff) return 0;
    return 0x8000000 + (res << 8);
}



/**
  @brief Convert short vector in the Leech lattice mod 2 to internal rep

  The function converts a value ``v2`` representing a vector in the
  Leech lattice mod 2 to an index in internal representation and
  returns that index. It returns garbage if ``v2`` is not a short
  Leech lattice vector.

  If ``v`` is a vector of type ``uint_mmv_t``, and ``v2`` is
  not a short Leech lattice vector, then the
  value ``mm_aux_get_mmv(v, mm_aux_index_leech2_to_intern_fast(v2))``
  is invalid, but reading that value does not cause buffer overflow.
*/
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_leech2_to_intern_fast(uint32_t v2)
{
    uint_fast32_t gc, theta, syn, res, oct, j, c, sub;
    gc = (v2 >> 12) & 0x7ff;

    // We proceed as in function ``mm_aux_index_leech2_to_sparse``,
    // dropping some of the checks.

    // Deal with odd cocode words
    if (v2 & 0x800) {   // Deal with odd cocode words
         theta = MAT24_THETA_TABLE[gc];
         // Let syn be the syndrome table entry for the cocode part
         syn = MAT24_SYNDROME_TABLE[(theta ^ v2) & 0x7ff];
         return MM_AUX_OFS_X + (gc << 5) + (syn & 0x1f);
    }
    // Deal with Golay code word 0
    if (gc == 0) {
         // Compute cocode entries of v2
         syn = MAT24_SYNDROME_TABLE[(v2 ^ MAT24_RECIP_BASIS[23]) & 0x7ff];
         syn &= 0x3ff;
         // Bits 9..5 and bits 4..0 contain high and low cocode bit index.
         // Change a high cocode bit index 24 to 23.
         syn -= ((syn + 0x100) & 0x400) >> 5;
         // Return sparse vector with tag B if bit 23 of v2 is 0
         // and with tag C otherwise.
         res = v2 & 0x800000 ? MM_AUX_OFS_C : MM_AUX_OFS_B;
         return res + (syn & 0x3ff);
    }

    // Deal with octads (and suboctads)
    oct = MAT24_OCT_ENC_TABLE[gc] >> 1;
    if (oct >= 759) return 0;             // Error detected!
    const uint8_t *p_oct = MAT24_OCTAD_ELEMENT_TABLE + (oct << 3);
    theta = MAT24_THETA_TABLE[gc];
    j =  p_oct[7];
    c = MAT24_SYNDROME_TABLE[(theta ^ v2 ^ MAT24_RECIP_BASIS[j]) & 0x7ff];
    syn = mat24_def_syndrome_from_table(c);
    sub = (syn >> j) & 1 ? 0 : 0x3f;
    sub ^= ((syn >> p_oct[1]) & 1UL) << 0;
    sub ^= ((syn >> p_oct[2]) & 1UL) << 1;
    sub ^= ((syn >> p_oct[3]) & 1UL) << 2;
    sub ^= ((syn >> p_oct[4]) & 1UL) << 3;
    sub ^= ((syn >> p_oct[5]) & 1UL) << 4;
    sub ^= ((syn >> p_oct[6]) & 1UL) << 5;
    return MM_AUX_OFS_T + (oct << 6) + sub;
}






/**********************************************************************
*** Index conversion between internal and sparse rep of vectors in R_p
**********************************************************************/

/**
  @brief Convert an index from internal to sparse representation

  The function converts an index ``i`` for the internal representation 
  of a vector to an index for the sparse representation of a vector
  and returns the converted index. The function returns 0 in case
  of a bad index. 

  Indices for the sparse representation are defined as 
  in ``enum MM_SPACE_TAG`` in file ``mm_basics.h``.
*/
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_intern_to_sparse(uint32_t i)
// Convert internal index i to sparse index.
// Return 0 if index i is bad
{
    uint32_t t, i0, i1, tmp;
    if (i <  MM_AUX_OFS_X) {
        if (i <  MM_AUX_OFS_T) {
            // put t =  (i / 0x300); assuming 0 <= i < 0x900 
            t = (0x2A540 >> ((i >> 8) << 1)) & 3;
            i0 = i - t * 0x300;
            i1 = i0 & 31;
            i0 >>= 5;
            if (i0 < i1) {
                tmp = i0; i0 = i1; i1 = tmp;
            }
            if (i0 >= 24) return 0;
            if (t && i0 == i1) return 0;
            return ((t + 1) << 25) + (i0 << 14) + (i1 << 8);
        } else {
            // Tag T
            i += 0x80000 - MM_AUX_OFS_T;
            return i << 8;
        } 
    } else if (i < MM_AUX_LEN_V) {
        // Tags X, Z, Y
        i -=  MM_AUX_OFS_X;
        i0 = i >> 5;
        i1 = i & 31;
        if (i1 >= 24) return 0;
        return  MM_SPACE_TAG_X + (i0 << 14) + (i1 << 8);
    } else return 0;
}



/**
  @brief Convert an index from sparse to internal representation

  The function converts an index ``i`` for the sparse representation
  of a vector to an index for the internal representation of a vector
  and returns the converted index. The function returns -1 if the
  input ``i`` denotes an illegal index. The coordinate value encoded
  in the input ``i`` is ignored.

  Indices for the sparse representation are defined as
  in ``enum MM_SPACE_TAG`` in file ``mm_basics.h``.
*/
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_sparse_to_intern(uint32_t i)
{
    uint_fast32_t tag = i >> 25, j = (i >> 8) & 0x3f;
    i = (i >> 14) & 0x7ff;
    switch (tag) {
        case 2:  // tag B
        case 3:  // tag C
            if (i == j) return -1;
            // Fall trough to case tag A
        case 1:  // tag A
            if (i >= 24 || j >= 24) return -1;
            return ((tag - 1) * 24 + i) * 32 + j;
        case 4:  // tag T
            if (i >= 759) return -1;
            return MM_AUX_OFS_T + (i << 6) + j;
        case 5:  // tag X
        case 6:  // tag Z
        case 7:  // tag Y
            if (j >= 24) return -1;
            return MM_AUX_OFS_X + 32 * (((tag - 5) << 11) + i) + j;
        default:
            return -1;
    }
}


/************************************************************************
*** Index conversion between internal and external rep of vectors in R_p
************************************************************************/


/**
  @brief Convert an index from external to internal representation

  The function converts an index ``i`` for the external representation
  of a vector to an index for the internal representation of a vector
  and returns the converted index. The function returns -1 in case
  ``i >= 196884``.
*/
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_extern_to_intern(uint32_t i)
{
    if (i <  MM_AUX_XOFS_X) {
        if (i <  MM_AUX_XOFS_T) {
            // Tags A, B, C
            return (MM_AUX_TBL_ABC[i] & 0x7ff) + i - 24;
        } else {
            // Tag T
            return i + MM_AUX_OFS_T - MM_AUX_XOFS_T;
        }
    } else if (i <  MM_AUX_XLEN_V) {
        // Tags X, Z, Y
        i -=  MM_AUX_XOFS_X;
        // Put i += 8 * floor(i/24), for i <  3 * 2048 * 24
        i += (((i >> 3) * 0xaaab) >> 17) << 3;
        // return result
        return i + MM_AUX_OFS_X;
    } else return -1;
}



/**********************************************************************
*** Convert index from internal rep to vector in leech lattice mod 2
**********************************************************************/

/**
  @brief Convert an index from internal to Leech 2 representation

  The function converts an index ``i`` for the internal representation 
  of a vector to a vector ``v`` in the Leech lattice mod 2. This 
  conversion  is successful if ``i`` denotes a legal index for one of 
  the tags``B, C, T, X``. The function returns a short Leech 
  lattice vector modulo 2, encoded in **Leech lattice encoding**, as
  described in 
  section **Description of the mmgroup.generators extension**. 

  The function returns 0 in case of failure.
*/
// %%EXPORT px
MM_OP_API
uint32_t mm_aux_index_intern_to_leech2(uint32_t i)
// Convert internal index i to sparse index.
// Return 0 if index i is bad
{
    uint32_t t, i0, i1, v;

    if (i <  MM_AUX_OFS_T) {
        // Tags B, C
        // put t =  (i / 0x300); assuming 0 <= i < 0x900 
        t = (0x2A540 >> ((i >> 8) << 1)) & 3;
        i0 = i - t * 0x300;
        i1 = i0 & 31;
        i0 >>= 5;
        if (t == 0 || i0 == i1 || i1 > 24) return 0;
        v = MAT24_RECIP_BASIS[i0] ^ MAT24_RECIP_BASIS[i1];
        return (v & 0xfff)  + ((t - 1) << 23);
   } else if (i < MM_AUX_OFS_X) {
        // Tag T
        uint_fast32_t gcode, cocode;
        i -=  MM_AUX_OFS_T;
        i0 = i >> 6;
        i1 = i & 0x3f;
        cocode = mat24_inline_suboctad_to_cocode(i1, i0);
        gcode = MAT24_OCT_DEC_TABLE[i0] & 0xfff;
        gcode ^= mat24_def_suboctad_weight(i1) << 11;
        cocode ^= MAT24_THETA_TABLE[gcode & 0x7ff] & 0xfff;
        return (gcode << 12) + cocode;
   } else if (i < MM_AUX_OFS_Z) {
        uint_fast32_t w, gcode, cocode, theta;
        i -=  MM_AUX_OFS_X;
        i0 = i >> 5;
        i1 = i & 0x1f;
        if (i1 > 24) return 0;
        cocode = mat24_vect_to_cocode(1 << i1);
        theta = MAT24_THETA_TABLE[i0 & 0x7ff];
        w = ((theta >> 12) & 1) ^ (i0 & cocode);
        w = mat24_def_parity12(w);
        gcode = i0 ^ (w << 11); 
        cocode ^= theta & 0xfff;
        return (gcode << 12) + cocode;
   } else return 0;
}






/************************************************************************
*** Check index in internal rep of vectors in R_p
************************************************************************/


/**
  @brief Check an index in internal representation

  The function checks an index ``i`` in the internal representation
  of a vector. Some entries of the vectors are stored at two different
  locations, e.g  entries ``A[i,j], B[i,j], C[i,j]`` for ``i != j``.

  The function returns the other location of the same entry (as an
  index in internal representation) if there is any. It returns 0 if
  that entry is stored at exactly one location, and -1 if index ``i``
  is illegal.
*/
// %%EXPORT px
MM_OP_API
int32_t mm_aux_index_check_intern(uint32_t i)
{
    uint32_t t, i1, i2 = i & 31;
    if (i < MM_AUX_OFS_T) {
        if (i2 >= 24) return -1;
        // put t = (i / (24 * 32)) * 24 * 32 for i < 72 * 32
        t = (((i & 0xf00) * 0x55556) >> 28) * 0x300;
        i1 = (i - t) >> 5;  // row index of U[i1,i2] for U = A, B, C
        if (i1 == i2) return 0 - (int32_t)(t > 0);
        return t + (i2 << 5) + i1;
    }
    if (i < MM_AUX_OFS_X || (i < MM_AUX_LEN_V && i2 < 24)) return 0;
    return -1;
}






//  %%GEN h
//  %%GEN c


// %%GEN ch
#ifdef __cplusplus
}
#endif
//  %%GEN c




