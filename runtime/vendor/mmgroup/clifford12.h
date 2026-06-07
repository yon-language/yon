// Warning: This file has been generated automatically. Do not change!


/** @file clifford12.h
 File ``clifford.h`` is the header file for shared library 
 ``mmgroup_clifford12``. 

*/

#ifndef CLIFFORD12_H
#define CLIFFORD12_H

/// @cond DO_NOT_DOCUMENT 
#include <stdint.h>
/// @endcond 





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
// %%FROM qstate12.c

/// @cond DO_NOT_DOCUMENT 


#define QSTATE12_MAXCOLS     (64)
#define QSTATE12_MAXROWS     (QSTATE12_MAXCOLS+1)

/// @endcond  

/**
  @def QSTATE12_UNDEF_ROW
  @brief Marker for an undefined row index in function qstate12_row_table()
*/
#define QSTATE12_UNDEF_ROW 0xff



/**
  @brief Description of a quadratic state matrix
  
  More precisely, a variable of this type decribes the
  representation  \f$(e', A, Q)\f$ of a quadratic mapping 
  \f$f(e', A, Q)\f$. Here \f$A\f$  is an \f$(1+m) \times n\f$
  bit matrix. \f$Q\f$ is a symmetric \f$(1+m) \times (1+m)\f$ bit 
  matrix representing an symmetric bilinear form.  We always have
  \f$Q_{0,0}=0\f$. Then the quadratic mapping
  \f$f(e', A, Q): \mathbb{F}_2^n \rightarrow \mathbb{C} \f$ 
  is given by


  \f[
     f(e',A,Q)(x) = e' \cdot
     \sum_{{\{{y = (y_0,\ldots,y_m) \in \mathbb{F}_2^{m+1}
     \mid y_0 = 1,  y \cdot A  = x\}}}} 
	 \exp \left( \frac {\pi \sqrt{{-1}}}{2} 
	 \sum_{j,k=0}^m     Q_{j,k} y_j y_k \right) \, .
  \f]  

  
  Matrices \f$A\f$ and  \f$Q\f$ are concatenated to an 
  \f$ (m+1) \times (n+m+1)\f$ matrix  \f$M\f$ such that
  \f$M_{i,j} = A_{i,j}\f$ for \f$j < n\f$ and
  \f$M_{i,j} = Q_{i-n,j}\f$ for \f$j \geq n\f$. Matrix
  \f$M\f$ is encoded in a one-dimensional array of unsigned
  64-bit integers. Here bit \f$j\f$ of entry \f$i\f$ of the
  array corresponds to \f$M_{i,j}\f$, with bit \f$0\f$ the 
  least significant bit.
  
  We do not update column  \f$0\f$ of matrix  \f$Q\f$. 
  \f$Q_{j,0}\f$ is inferred from \f$Q_{0,j}\f$ for
  \f$j>0\f$ and we always have \f$Q_{0,0} = 0.\f$ 
  
  We also interpret a quadratic mapping \f$ f \f$ from 
  \f$\mathbb{F}_2^n\f$ to \f$\mathbb{C}\f$ as a complex
  \f$2^{n-k} \times 2^k\f$ matrix \f$U\f$ with entries
  \f$U[i,j] = f(b_0,\ldots,b_{n-1})\f$, where
  \f$(b_{n-1},...,b_0)_2\f$, is the binary representation
  of the integer \f$i \cdot 2^k + j\f$, and \f$k\f$ is given by
  component ``shape1`` of the structure.

  The current implementation requires \f$n + m <= 63\f$, so that
  all columns of the bit matrix \f$M\f$ fit into a 64-bit
  integer. With this restriction we may still multiply 
  \f$2^{12} \times 2^{12}\f$ matrices \f$U\f$ given as
  quadratic mappings.

  A quadratic mapping may be reduced with function qstate12_reduce()
  without notice, whenever appropriate. 

  Warning:

  If an external function changes any component of a structure ``qs`` 
  of type ``qstate12_type`` (or the content of ``qs.data``) then 
  it **must** set ``qs.reduced`` to zero. The **only** legal way to  
  set ``qs.reduced`` to a nonzero value is to call function 
  ``qstate12_reduce``.  The functions in this module assume that
  ``qs`` is actually reduced if ``qs.reduced`` is not zero.
  
*/

typedef struct {
  uint32_t maxrows; ///< No of entries of type ``uint64_t`` allocated to component ``data``
  uint32_t nrows;   ///< No \f$m + 1\f$ of rows of bit matrix \f$A\f$
                    ///< The value ``nrows = 0`` encodes the zero mapping.
  uint32_t ncols;   ///< No \f$n\f$ of columns of bit matrices \f$A\f$ and \f$Q\f$
  int32_t  factor;  ///< A integer \f$e\f$ encoding the complex scalar factor \f$e'=\f$
                    ///< \f$\exp(e \pi \sqrt{-1}/4) \cdot 2^{\lfloor e/16 \rfloor / 2}\f$
  uint32_t shape1;  ///< Describes the shape of the quadratic state matrix
                    ///< as explained above.
  uint32_t reduced; ///< This is set to 1 if the state is reduced and to 0 otherwise.
  uint64_t *data;   ///< Pointer to the data bits of the matrix \f$M = (A,Q)\f$
} qstate12_type;


/**
  @enum qstate12_error_type
  @brief Error codes for functions in this module

  Unless otherwise stated, the functions in modules ``qstate.c``, 
  ``qmatrix.c``, and ``xsp2co1.c``  return nonnegative values 
  in case of success and negative values in case of failure. 
  Negative return values mean error codes as follows:
*/
enum qstate12_error_type
{
    ERR_QSTATE12_NOTFOUND = -1,     ///< No object with the requested property found. 
    ERR_QSTATE12_INCONSISTENT = -2, ///< State is inconsistent
    ERR_QSTATE12_QUBIT_INDEX = -3,  ///< Qubit index error
    ERR_QSTATE12_TOOLARGE = -4,     ///< State is too large for this module
    ERR_QSTATE12_BUFFER_OVFL = -5,  
       ///< Buffer overflow; usually there are now enough rows available
    ERR_QSTATE12_Q_NOT_SYMM = -6,   ///< Bit matrix part Q is not symmetric
    ERR_QSTATE12_BAD_ROW = -7,      ///< Bad row index for bit matrix 
    ERR_QSTATE12_INTERN_PAR = -8,    
       ///< Internal parameter error. Usually a bad row has been requested
    ERR_QSTATE12_SCALAR_OVFL = -9,  ///< Overflow or underflow in scalar factor
    ERR_QSTATE12_CTRL_NOT = -10,    
       ///< Bad control_not gate. A qubit in a ctrl-not gate cannot control itself.
    ERR_QSTATE12_SHAPE_COMP = -11,  ///< Shape mismatch in comparing matrices
    ERR_QSTATE12_SCALAR_INT = -12,  ///< Scalar factor is not an integer
    ERR_QSTATE12_PARAM = -13,       ///< Parameter error
    ERR_QSTATE12_DOMAIN = -14,      ///< Matrix is not is the expected domain
	
    ERR_QSTATE12_SHAPE_OP = -101,   ///< Shape mismatch in matrix operation
    ERR_QSTATE12_MATRIX_INV = -102, ///< Matrix is not invertible
    ERR_QSTATE12_PAULI_GROUP = -103, ///< Matrix is not in the Pauli group
    ERR_QSTATE12_NOT_MONOMIAL = -104, ///< Matrix is not monomial

    ERR_QSTATE12_LEECH_OP = -201,  ///< Internal error in operation of group Co_0
    ERR_QSTATE12_REP_GX0 = -202,   ///< Error in operation of group 2^{1+24}.Co_1
    ERR_QSTATE12_NOTIN_XSP = -203, ///< Element of G_x0 not in 2^{1+24}
    ERR_QSTATE12_GX0_TAG = -204,   ///< Bad tag for atom in group G_x0 
    ERR_QSTATE12_GX0_BAD_ELEM = -205, ///< Bad element of group G_x0 
    ERR_QSTATE12_LEECH_SHORT = -206  ///< Vector in Leech lattice must be short

};

/*************************************************************************
*** Macros
*************************************************************************/
 
 
#ifdef CLIFFORD12_INTERN

/// @cond DO_NOT_DOCUMENT 
      
// Max No of columns supporte in an object of type 
// qstate12_type. Here each column stores a bit.
#define MAXCOLS QSTATE12_MAXCOLS
  
// Max No of rows required in an object of type qstate12_type
// when  MAXCOLS bolumns are present.
#define MAXROWS QSTATE12_MAXROWS



// Use this for the number 1 as an uint64_t
// We'd better make sure that  ONE << n  works as expected 
// for  n >= 32 on all compilers, regardless of sizeof(int).
#define ONE ((uint64_t)0x1ULL)


// Use this for the an uint64_t where all bits are set
#define ALL_SET ((uint64_t)0xffffffffffffffffULL)


// Mask for valid bits of factor
#define FACTOR_MASK (ALL_SET & ~8ULL)

// Adding factors
#define ADD_FACTORS(e1, e2) ((((e1) & FACTOR_MASK) + (e2)) & FACTOR_MASK)

// Sign bit of factor
#define FACTOR_SIGN 0x80000000

// Check factor overflow
#define ADD_FACTOR_OVERFLOW(e1, e2) \
   (((e1) + (e2) < -0x8000000) || ((e1) + (e2) >= 0x8000000))



// Check the object of type qstate12_type referred by pqs.
// Return True if that object is errorneous.
#define bad_state(pqs) \
    ((pqs)->nrows + (pqs)->ncols > MAXCOLS  \
      || (pqs)->nrows  > (pqs)->maxrows \
      || (pqs)->shape1 > (pqs)->ncols)

   

// The 'bad' maximum and minimum functions in C, use them with care!!
#define MIN(a,b) (((a)<(b))?(a):(b))
#define MAX(a,b) (((a)>(b))?(a):(b)) 

extern const uint8_t qstate12_lsbtab[64];

/// @endcond


/*************************************************************************
*** inline functions
*************************************************************************/

static inline 
uint64_t qstate12_get_col(uint64_t *m, uint32_t j, uint32_t len)
// Return column ``j`` of the bit matrix ``m``
// upto and exlcuding line ``len``.
{
    uint_fast32_t i;
    uint64_t a = 0;
    for (i = 0; i <= len; ++i) a |= ((m[i] >> j) & ONE) << i;
    return a;
}


static inline 
int32_t qstate12_find_pivot(uint64_t *m, uint32_t nrows, uint32_t j)
// Auxiliary low-level function for ``qstate12_reduce()``.
// Let ``m`` be a bit matrix with ``nrows`` rows.  On input ``j``, 
// the function returns the highest row index ``i`` such that
// ``A[i,j] = 1.``. 
//  The function returns ``-1`` if all bits ``A[i1,j]`` are zero.
{
    uint64_t mask = ONE << j; 
    int_fast32_t i = nrows - 1; 

    // find the  highest row index i such that m[i,j] = 1. 
    while (i >= 0  && ((m[i] & mask) == 0)) -- i;
    return i;
}


static inline
void qstate12_xch_rows(qstate12_type *pqs, uint32_t i1, uint32_t i2)
// Exchange row i1 of the state matrix M referred by *pqs with row i2. 
// Also, adjust the quadratic form Q inside M. 1 <= i1, i2 < pqs->nrows 
// must hold. This does not change the state.
{ 
    uint64_t *m = pqs->data, v; 
    uint_fast32_t k;
    v = m[i1]; m[i1] = m[i2];  m[i2] = v;
    i1 +=  pqs->ncols; i2 +=  pqs->ncols; 
    v = (ONE << i1) ^ (ONE << i2);
    if (v) for (k = 0; k < pqs->nrows; ++k) 
        m[k] ^= v & (0 - (((m[k] >> i1) ^ (m[k] >> i2)) & ONE));
} 


#endif // #ifdef CLIFFORD12_INTERN




#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT p
MAT24_API
int32_t qstate12_check(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_set_mem(qstate12_type *pqs, uint64_t *data, uint32_t size);
// %%EXPORT p
MAT24_API
int32_t qstate12_zero(qstate12_type *pqs, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_vector_state(qstate12_type *pqs, uint32_t nqb, uint64_t v);
// %%EXPORT p
MAT24_API
int32_t qstate12_set(qstate12_type *pqs, uint32_t nqb, uint32_t nrows, uint64_t *data, uint32_t mode);
// %%EXPORT p
MAT24_API
int32_t qstate12_copy(qstate12_type *pqs1, qstate12_type *pqs2);
// %%EXPORT p
MAT24_API
int32_t qstate12_copy_alloc(qstate12_type *pqs1, qstate12_type *pqs2, uint64_t *data, uint32_t size);
// %%EXPORT p
MAT24_API
int32_t qstate12_factor_to_complex(int32_t factor, double *pcomplex);
// %%EXPORT p
MAT24_API
int32_t qstate12_factor_to_int32(int32_t factor, int32_t *pi);
// %%EXPORT p
MAT24_API
int32_t qstate12_conjugate(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_mul_scalar(qstate12_type *pqs, int32_t e, uint32_t phi);
// %%EXPORT p
MAT24_API
int32_t qstate12_abs(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
uint64_t qstate12_get_column(qstate12_type *pqs, uint32_t j);
// %%EXPORT 
MAT24_API
int32_t qstate12_del_rows(qstate12_type *pqs, uint64_t v);
// %%EXPORT 
MAT24_API
int32_t qstate12_insert_rows(qstate12_type *pqs, uint32_t i, uint32_t nrows);
// %%EXPORT p
MAT24_API
int32_t qstate12_mul_Av(qstate12_type *pqs, uint64_t v, uint64_t *pw);
// %%EXPORT p
MAT24_API
int32_t qstate12_rot_bits(qstate12_type *pqs, int32_t rot, uint32_t nrot, uint32_t n0);
// %%EXPORT p
MAT24_API
int32_t qstate12_xch_bits(qstate12_type *pqs, uint32_t sh, uint64_t mask);
// %%EXPORT 
MAT24_API
void qstate12_pivot(qstate12_type *pqs, uint32_t i, uint64_t v);
// %%EXPORT p
MAT24_API
void qstate12_pivot_rot_rows(qstate12_type *pqs, uint32_t fst, uint32_t last);
// %%EXPORT 
MAT24_API
int32_t qstate12_sum_up_kernel(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_echelonize(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_check_reduced(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_reduce(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_row_table(qstate12_type *pqs, uint8_t *row_table);
// %%EXPORT p
MAT24_API
int32_t qstate12_join_imaginary(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_equal(qstate12_type *pqs1, qstate12_type *pqs2);
// %%EXPORT p
MAT24_API
int32_t qstate12_extend_zero(qstate12_type *pqs, uint32_t j, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_extend(qstate12_type *pqs, uint32_t j, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_sum_cols(qstate12_type *pqs, uint32_t j, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_restrict_zero(qstate12_type *pqs, uint32_t j, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_restrict(qstate12_type *pqs, uint32_t j, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_gate_not(qstate12_type *pqs, uint64_t v);
// %%EXPORT p
MAT24_API
int32_t qstate12_gate_ctrl_not(qstate12_type *pqs, uint64_t vc, uint64_t v);
// %%EXPORT p
MAT24_API
int32_t qstate12_gate_phi(qstate12_type *pqs, uint64_t v, uint32_t phi);
// %%EXPORT p
MAT24_API
int32_t qstate12_gate_ctrl_phi(qstate12_type *pqs, uint64_t v1, uint64_t v2);
// %%EXPORT p
MAT24_API
int32_t qstate12_gate_h(qstate12_type *pqs, uint64_t v);
/// @endcond  
#ifdef __cplusplus
}
#endif


// %%FROM qstate12io.c
#ifdef __cplusplus
extern "C" {
#endif

/**
  @def QSTATE_SUPPORT_MAXCOLS
  @brief Max No of columns allowed for matrix in struct qstate12_support_type   
*/
#define QSTATE_SUPPORT_MAXCOLS 30


/**
  @brief Structure ``qstate12_support_type`` for reading data a state

  This structure is created by function ``qstate12_support_init`` in
  file ``qstateio.c`` for traversing the support (i.e. the set of
  nonzero entries) of a quadratic state. For details we refer to the
  documentation of file ``qstateio.c``.
*/
typedef struct {
   uint32_t size;        ///< Total size of the quadratic state; a power of 2
   uint32_t weight;      ///< No of nonzero entries of of matrix; 0 or a power of 2
   int32_t factor;       ///< Scalar factor, encoded as in the structure ``qstate12_type``
   uint32_t factor_new;  ///< 1 if factor has changed, 0 otherwise
   uint32_t batchlength; ///< Size of a batch; 0 or a power of 2
   uint32_t n_batches;   ///< Total number of batches
   uint32_t indices[64]; ///< Indices contained in the current batch
   uint8_t signs[64];    ///< Signs of entries of the current batch
   // Internal data
   /** @private */
   uint32_t lb_batchlength; ///< binary logarithm of member batchlength
   /** @private */
   qstate12_type qs;     ///< Copy of state to be processed
   /** @private */
   uint64_t buf[QSTATE_SUPPORT_MAXCOLS + 1];  ///< Buffer for member pqs
   /** @private */
   uint64_t qf;          ///< Current value of high part of quadratic form
   /** @private */
   uint64_t assoc;       ///< Current value of linear part for quadratic form
   /** @private */
   uint32_t i;           ///< Current (high) index of iterator
   /** @private */
   uint32_t c_weight;    ///< Value of i where to switch imaginary part
} qstate12_support_type;

/// @cond DO_NOT_DOCUMENT 


// %%EXPORT p
MAT24_API
int32_t qstate12_support_init(qstate12_type *pqs,  qstate12_support_type *psup);
// %%EXPORT p
MAT24_API
int32_t qstate12_support_next(qstate12_support_type *psup);
// %%EXPORT p
MAT24_API
int32_t qstate12_support_adjust(qstate12_support_type *psup, uint32_t flags);
// %%EXPORT p
MAT24_API
int32_t qstate12_complex(qstate12_type *pqs,  double *pc);
// %%EXPORT p
MAT24_API
int32_t qstate12_entries(qstate12_type *pqs, uint32_t n, uint32_t *v, double *pc);
// %%EXPORT p
MAT24_API
int32_t qstate12_int32(qstate12_type *pqs,  int32_t *pi);
// %%EXPORT p
MAT24_API
int32_t qstate12_to_signs(qstate12_type *pqs,  uint64_t *bmap);
// %%EXPORT p
MAT24_API
int32_t qstate12_compare_signs(qstate12_type *pqs, uint64_t *bmap);
// %%EXPORT p
MAT24_API
int32_t qstate12_from_signs(uint64_t *bmap, int32_t n, qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_mul_matrix_mod3(qstate12_type *pqs, uint64_t *v, uint64_t w);
/// @endcond  
#ifdef __cplusplus
}
#endif


// %%FROM qmatrix12.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT p
MAT24_API
int32_t qstate12_std_matrix(qstate12_type *pqs, uint32_t rows, uint32_t cols, uint32_t rk);
// %%EXPORT p
MAT24_API
int32_t qstate12_unit_matrix(qstate12_type *pqs, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_monomial_column_matrix(qstate12_type *pqs, uint32_t nqb, uint64_t *pa);
// %%EXPORT p
MAT24_API
int32_t qstate12_monomial_row_matrix(qstate12_type *pqs, uint32_t nqb, uint64_t *pa);
// %%EXPORT p
MAT24_API
int32_t qstate12_monomial_matrix_row_op(qstate12_type *pqs, uint32_t *pa);
// %%EXPORT p
MAT24_API
int32_t qstate12_mat_reshape(qstate12_type *pqs, int32_t rows, int32_t cols);
// %%EXPORT p
MAT24_API
int32_t qstate12_mat_t(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_mat_trace_factor(qstate12_type *pqs, int32_t *pfactor);
// %%EXPORT p
MAT24_API
int32_t qstate12_mat_trace(qstate12_type *pqs, double *p_trace);
// %%EXPORT p
MAT24_API
int32_t qstate12_mat_itrace(qstate12_type *pqs, int32_t *p_itrace);
// %%EXPORT p
MAT24_API
int32_t qstate12_prep_mul(qstate12_type *pqs1, qstate12_type *pqs2, uint32_t nqb);
// %%EXPORT p
MAT24_API
int32_t qstate12_product(qstate12_type *pqs1, qstate12_type *pqs2, uint32_t nqb, uint32_t nc);
// %%EXPORT p
MAT24_API
int32_t qstate12_matmul(qstate12_type *pqs1, qstate12_type *pqs2, qstate12_type *pqs3);
// %%EXPORT p
MAT24_API
int32_t qstate12_pauli_vector(qstate12_type *pqs, uint64_t *pv);
// %%EXPORT p
MAT24_API
int32_t qstate12_pauli_matrix(qstate12_type *pqs, uint32_t nqb, uint64_t v);
// %%EXPORT px
MAT24_API
uint64_t qstate12_pauli_vector_mul(uint32_t nqb, uint64_t v1, uint64_t v2);
// %%EXPORT px
MAT24_API
uint64_t qstate12_pauli_vector_exp(uint32_t nqb, uint64_t v, uint32_t e);
// %%EXPORT p
MAT24_API
int32_t qstate12_reduce_matrix(qstate12_type *pqs, uint8_t *row_table);
// %%EXPORT p
MAT24_API
int32_t qstate12_mat_lb_rank(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_mat_inv(qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t qstate12_to_symplectic(qstate12_type *pqs, uint64_t *pA);
// %%EXPORT p
MAT24_API
int32_t qstate12_to_symplectic_row(qstate12_type *pqs, uint32_t n);
// %%EXPORT p
MAT24_API
int32_t qstate12_pauli_conjugate(qstate12_type *pqs, uint32_t n, uint64_t *pv, uint32_t arg);
/// @endcond 
#ifdef __cplusplus
}
#endif





// %%FROM bitmatrix64.c

/// @cond DO_NOT_DOCUMENT 


#ifdef __cplusplus
extern "C" {
#endif
// %%EXPORT px
MAT24_API
uint32_t bitmatrix64_error_pool(uint64_t *dest, uint32_t length);
// Multiplier for finding high bit with table UINT64T_HIGHBIT_TABLE
#define UINT64T_HIGHBIT_MULTIPLIER 0xb7c2ad8bd12cd265ULL
// Multiplier for finding low bit with table UINT64T_LOWBIT_TABLE
#define UINT64T_LOWBIT_MULTIPLIER 0x12e91e16a99fdf2bULL
// %%EXPORT_TABLE  p
MAT24_API
extern const uint8_t UINT64T_HIGHBIT_TABLE[128];
// %%EXPORT_TABLE  p
MAT24_API
extern const uint8_t UINT64T_LOWBIT_TABLE[128];
// %%EXPORT px
MAT24_API
uint32_t uint64_parity(uint64_t v);
// %%EXPORT px
MAT24_API
uint32_t uint64_low_bit(uint64_t v);
// %%EXPORT px
MAT24_API
uint32_t uint64_bit_len(uint64_t v);
// %%EXPORT px
MAT24_API
uint32_t uint64_bit_weight(uint64_t v);
// %%EXPORT px
MAT24_API
uint32_t uint64_to_bitarray(uint64_t v, uint8_t *bl);
// %%EXPORT px
MAT24_API
void bitmatrix64_add_diag(uint64_t *m, uint32_t i, uint32_t j);
// %%EXPORT px
MAT24_API
void bitmatrix64_mask_rows(uint64_t *m, uint32_t i, uint64_t mask);
// %%EXPORT px
MAT24_API
int32_t bitmatrix64_find_masked_row(uint64_t *m, uint32_t i, uint64_t mask, uint64_t v);
// %%EXPORT px
MAT24_API
int32_t bitmatrix64_to_numpy(uint64_t *m, uint32_t rows, uint32_t cols, uint8_t *a);
// %%EXPORT px
MAT24_API
void bitmatrix64_from_32bit(uint32_t *a32, uint32_t n, uint64_t *a64);
// %%EXPORT px
MAT24_API
void bitmatrix64_to_32bit(uint32_t *a32, uint32_t n, uint64_t *a64);
// %%EXPORT px
MAT24_API
uint32_t bitmatrix64_find_low_bit(uint64_t *m, uint32_t imin, uint32_t imax);
// %%EXPORT px
MAT24_API
void bitmatrix64_mul(uint64_t *m1,  uint64_t *m2, uint32_t i1, uint32_t i2, uint64_t *m3);
// %%EXPORT px
MAT24_API
uint64_t bitmatrix64_vmul(uint64_t v,  uint64_t *m, uint32_t i);
// %%EXPORT px
MAT24_API
int32_t bitmatrix64_rot_bits(uint64_t *m, uint32_t i, int32_t rot, uint32_t nrot, uint32_t n0);
// %%EXPORT p
MAT24_API
int32_t bitmatrix64_xch_bits(uint64_t *m, uint32_t i, uint32_t sh, uint64_t mask);
// %%EXPORT px
MAT24_API
int32_t bitmatrix64_reverse_bits(uint64_t *m, uint32_t i, uint32_t n, uint32_t n0);
// %%EXPORT px
MAT24_API
int32_t bitmatrix64_t(uint64_t *m1, uint32_t i, uint32_t j, uint64_t *m2);
// %%EXPORT px
MAT24_API
uint32_t bitmatrix64_echelon_h(uint64_t *m, uint32_t i, uint32_t j0, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t bitmatrix64_echelon_l(uint64_t *m, uint32_t i, uint32_t j0, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t bitmatrix64_cap_h(uint64_t *m1, uint64_t *m2, uint32_t i1, uint32_t i2, uint32_t j0, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t bitmatrix64_inv(uint64_t *m, uint32_t i);
// %%EXPORT px
MAT24_API
int64_t bitmatrix64_solve_equation(uint64_t *m, uint32_t i, uint32_t j);
/// @endcond  
#ifdef __cplusplus
}
#endif





// %%FROM uint_sort.c

/// @cond DO_NOT_DOCUMENT 


/** @brief macro for sorting an array according to a condition

  The macro permutes the entries ``a[k], i <= k < j`` of the
  array ``a`` such that ``a[k] < a[l]`` holds for ``i <= k, l < j``
  if ``cond(a[k])`` is false and ``cond(a[l])`` is true. That sorting
  process is not stable. After executing the macro, variable ``i``
  is one plus the index of the highest entry ``a[k], i <= k < j``
  such that  ``cond(a[k])`` is false. If no such ``a[k]`` exists
  and ``j >= i`` then ``i`` is changed to the input value of ``j``.

  Here ``a`` must be an array and ``i, j`` must integer **variables**.
  Parameter ``cond`` must be a Boolean condition that will be applied
  to the entries of the array ``a``. Here ``cond`` should be a
  function taking a single argument of the same type as an entry of
  array ``a`` and returning an ``int``. Then the return value is
  interpreted as a Boolean value. Parameter ``cond`` may also be
  a ``#define`` expression with a corresponding behaviour. This is
  much faster for a simple condition ``cond``.

  Variable ``temp`` must be able to store an entry of the
  array ``a``. E.g if ``a`` is of type ``int[]`` then ``temp``
  must be of type ``int``.

  The macro expands to a code block in C.
*/
#define bitvector_cond_sort(a, i, j, cond, temp)    \
    {                                               \
        while (i < j && !(cond(a[i]))) ++i;         \
        while (i < j && cond(a[--j]));              \
        while (i < j)  {                            \
            temp = a[i]; a[i] = a[j]; a[j] = temp;  \
            do {++i;} while (!(cond(a[i])));        \
            do {--j;} while (cond(a[j]));           \
        }                                           \
    }


/** @brief Shellsort step for an array ``a`` of length ``n`` with ``gap``

    Type of array ``a`` is given by ``num_type``.
    Here ``gap = 1`` is equivalent to insert sort.
    The shellsort step is done in place.
*/
#define bitvector_shellsort_step(a, n, gap, num_type) do { \
    uint_fast32_t _i, _j;  \
    for (_i = gap; _i < n; _i += 1) { \
        num_type _tmp = (a)[_i]; \
        for (_j = _i; _j >= gap && (a)[_j - gap] > _tmp; _j -= gap) { \
            (a)[_j] = (a)[_j - gap]; \
        } \
        (a)[_j] = _tmp; \
    } \
} while(0)

#define bitvector_insertsort(a, n, num_type) \
    bitvector_shellsort_step(a, n, 1, num_type)



#ifdef __cplusplus
extern "C" {
#endif
// %%EXPORT px
MAT24_API
void bitvector_sort_stat(uint64_t* out, uint32_t len_out);
// %%EXPORT px
MAT24_API
void bitvector32_copy(uint32_t *a_src, uint32_t n, uint32_t *a_dest);
// %%EXPORT px
MAT24_API
void bitvector32_heapsort(uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
void bitvector32_sort(uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t bitvector32_bsearch(uint32_t *a, uint32_t n, uint32_t v);
// %%EXPORT px
MAT24_API
void bitvector64_copy(uint64_t *a_src, uint32_t n, uint64_t *a_dest);
// %%EXPORT px
MAT24_API
void bitvector64_heapsort(uint64_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
void bitvector64_sort(uint64_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t bitvector64_bsearch(uint64_t *a, uint32_t n, uint64_t v);
/// @endcond  
#ifdef __cplusplus
}
#endif




// %%FROM xsp2co1.c
#ifdef __cplusplus
extern "C" {
#endif


/// @cond DO_NOT_DOCUMENT 

#ifdef CLIFFORD12_INTERN


// The standard short Leech lattice vector modulo 3
#define STD_V3  0x8000004ULL
// The negative of STD_V3
#define STD_V3_NEG  0x4000008ULL


// If ERROR_POOL is defined then function xsp2co1_error_pool() can
// read data from an "error pool" that contains debug information
// for certain functions after calling them.
// #define ERROR_POOL

// Number of entries of type uit64_t of the ERROR_POOL
#define LEN_ERROR_POOL 20

// Exchange the bits masked by ``mask`` of the integer ``a``
// with the corresponding bits masked by ``mask << sh``.
// ``mask & (mask << sh)` = 0`` must hold. ``aux`` must be an 
// integer variable of the same type as variable ``a``.
#define SHIFT_MASKED(a, aux, mask, sh) \
    aux = (a ^ (a >> sh)) & mask; \
    a ^=  aux ^  (aux << sh);


// Standard size of a buffer for a quaratic state matrix
// representing an element of the group G_{x0}. 
#define MAXROWS_ELEM 30


#endif // #ifdef CLIFFORD12_INTERN


/// @endcond 

/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint32_t xsp2co1_error_pool(uint64_t *dest, uint32_t length);
// %%EXPORT px
MAT24_API
uint64_t xsp2co1_find_chain_short_3(uint64_t v3_1, uint64_t v3_2);
// %%EXPORT p
MAT24_API
int32_t xsp2co1_chain_short_3(qstate12_type *pqs, uint32_t n, uint64_t *psrc, uint64_t *pdest);
// %%EXPORT p
MAT24_API
int32_t xsp2co1_elem_to_qs_i(uint64_t *elem, qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t xsp2co1_elem_to_qs(uint64_t *elem, qstate12_type *pqs);
// %%EXPORT p
MAT24_API
int32_t xsp2co1_qs_to_elem_i(qstate12_type *pqs, uint64_t v_g, uint64_t *elem);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_reduce_elem(uint64_t *elem);
// %%EXPORT px
MAT24_API
void xsp2co1_neg_elem(uint64_t *elem);
// %%EXPORT px
MAT24_API
void xsp2co1_copy_elem(uint64_t *elem1, uint64_t *elem2);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_to_bitmatrix(uint64_t *elem, uint64_t *pA);
// %%EXPORT p
MAT24_API
int64_t xsp2co1_map_short3(qstate12_type *pqs, uint64_t src1,  uint64_t dest1, uint64_t src2);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_mul_elem(uint64_t *elem1, uint64_t *elem2, uint64_t *elem3);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_inv_elem(uint64_t *elem1, uint64_t *elem2);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_conj_elem(uint64_t *elem1, uint64_t *elem2, uint64_t *elem3);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_xspecial_conjugate(uint64_t *elem, uint32_t n, uint64_t *ax, uint32_t sign);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_xspecial_img_omega(uint64_t *elem);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_check_fix_short(uint64_t *elem1, uint32_t v);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_xspecial_vector(uint64_t *elem);
// %%EXPORT px
MAT24_API
void xsp2co1_unit_elem(uint64_t *elem);
// %%EXPORT px
MAT24_API
uint32_t xsp2co1_is_unit_elem(uint64_t *elem);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_xspecial(uint64_t *elem, uint32_t x);
// %%EXPORT p
MAT24_API
int32_t xsp2co1_mul_qs_v3_word(qstate12_type *pqs, uint64_t *pv3, uint32_t *a, uint32_t n, uint32_t s);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_mul_elem_word(uint64_t *elem, uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_set_elem_word(uint64_t *elem, uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_mul_elem_atom(uint64_t *elem, uint32_t v);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_set_elem_atom(uint64_t *elem, uint32_t v);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_set_elem_word_scan(uint64_t *elem, uint32_t *a, uint32_t n, uint32_t mul);
/// @endcond  
#ifdef __cplusplus
}
#endif





// %%FROM xsp2co1_word.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint64_t xsp2co1_to_vect_mod3(uint64_t x);
// %%EXPORT px
MAT24_API
uint64_t xsp2co1_from_vect_mod3(uint64_t x);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_to_leech_op(uint64_t *elem, int8_t *pdest);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_short_3_to_leech(uint64_t x, int8_t *pdest);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_short_2_to_leech(uint64_t x, int8_t *pdest);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_monomial_to_xsp(uint64_t *elem, uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_to_word(uint64_t *elem, uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_reduce_word(uint32_t *a, uint32_t n, uint32_t *a1);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_subtype(uint64_t *elem);
// %%EXPORT px
MAT24_API
uint32_t xsp2co1_check_word_g_x0(uint32_t *w, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_isotropic_type4(uint32_t v, uint64_t *pB, int32_t n);
// %%EXPORT px
MAT24_API
int64_t xsp2co1_isotropic_type4_span(uint32_t v, uint32_t *pB, int32_t n);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_row_mod3(uint64_t *elem, uint32_t column, uint64_t *v);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_read_mod3(uint64_t *v, uint64_t *elem, uint32_t row, uint32_t column);
/// @endcond  
#ifdef __cplusplus
}
#endif





// %%FROM leech2matrix.c

/// @cond DO_NOT_DOCUMENT 


#ifdef __cplusplus
extern "C" {
#endif
// %%EXPORT px
MAT24_API
int32_t leech2matrix_add_eqn(uint64_t *m, uint32_t nrows, uint32_t ncols, uint64_t a);
// %%EXPORT px
MAT24_API
int32_t leech2matrix_prep_eqn(uint64_t *m, uint32_t nrows, uint32_t ncols, uint32_t *b);
// %%EXPORT px
MAT24_API
uint32_t leech2matrix_solve_eqn(uint32_t *b, uint32_t nrows, uint64_t v);
// %%EXPORT px
MAT24_API
void leech2matrix_echelon_eqn(uint64_t *m, uint32_t nrows, uint32_t ncols, uint64_t *m1);
// %%EXPORT px
MAT24_API
int64_t leech2matrix_subspace_eqn(uint64_t *m, uint32_t nrows, uint32_t ncols, uint64_t v);
// %%EXPORT px
MAT24_API
uint32_t leech2_matrix_basis(uint32_t *v2, uint32_t n, uint64_t *basis, uint32_t d);
// %%EXPORT px
MAT24_API
int32_t leech2_matrix_orthogonal(uint64_t *a, uint64_t *b, uint32_t k);
// %%EXPORT px
MAT24_API
uint32_t leech2_matrix_radical(uint32_t *v2, uint32_t n, uint64_t *basis, uint32_t d);
// %%EXPORT px
MAT24_API
uint32_t leech2_matrix_expand(uint64_t *basis, uint32_t dim, uint32_t *v2);
/// @endcond  
#ifdef __cplusplus
}
#endif





// %%FROM leech3matrix.c

/// @cond DO_NOT_DOCUMENT 


#ifdef __cplusplus
extern "C" {
#endif
// %%EXPORT px
MAT24_API
uint32_t leech3matrix_echelon(uint64_t *a);
// %%EXPORT px
MAT24_API
uint64_t leech3matrix_reduced_echelon(uint64_t *a, uint32_t d);
// %%EXPORT px
MAT24_API
int32_t leech3matrix_kernel_image(uint64_t *a);
// %%EXPORT px
MAT24_API
void leech3matrix_compress(uint64_t *a, uint64_t *v);
// %%EXPORT px
MAT24_API
void leech3matrix_sub_diag(uint64_t *a, uint64_t diag, uint32_t offset);
// %%EXPORT px
MAT24_API
uint64_t leech3matrix_rank(uint64_t *a, uint32_t d);
// %%EXPORT px
MAT24_API
uint64_t leech3matrix_vmul(uint64_t v, uint64_t *a);
// %%EXPORT px
MAT24_API
int32_t leech3matrix_prep_type4(uint64_t *a, uint32_t n, uint64_t *w, uint64_t *seed);
// %%EXPORT px
MAT24_API
int32_t leech3matrix_rand_type4(uint64_t *w, uint32_t n, uint32_t trials, uint64_t *seed);
// %%EXPORT px
MAT24_API
void leech3_vect_mod3_to_signs(uint64_t *v, uint64_t mult, uint32_t n, uint64_t *signs);
/// @endcond  
#ifdef __cplusplus
}
#endif





// %%FROM xsp2co1_elem.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_to_N0(uint64_t *elem, uint32_t *g);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_from_N0(uint64_t *elem, uint32_t *g);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_conjugate_elem(uint64_t *elem, uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_power_elem(uint64_t *elem1, int64_t e, uint64_t *elem2);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_power_word(uint32_t *a1, uint32_t n, int64_t e, uint32_t *a2);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_odd_order_bitmatrix(uint64_t *bm);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_half_order_elem(uint64_t *elem1, uint64_t *elem2);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_order_elem(uint64_t *elem);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_half_order_word(uint32_t *a1, uint32_t n, uint32_t *a2);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_order_word(uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
uint32_t  xsp2co1_leech2_count_type2(uint64_t *a, uint32_t n);
// %%EXPORT p
MAT24_API
int32_t xsp2co1_trace_98280(uint64_t *elem, int32_t (*f_fast)(uint64_t*));
// %%EXPORT px
MAT24_API
int32_t xsp2co1_traces_small(uint64_t *elem, int32_t *ptrace);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_traces_all(uint64_t *elem, int32_t *ptrace);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_rand_word_N_0(uint32_t *w, uint32_t in_N_x0, uint32_t even, uint64_t *seed);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_rand_word_G_x0(uint32_t *w, uint64_t *seed);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM involutions.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint32_t xsp2co1_involution_error_pool(uint64_t *dest, uint32_t length);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_involution_invariants(uint64_t *elem, uint64_t *invar);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_involution_orthogonal(uint64_t *invar, uint32_t col);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_involution_find_type4(uint64_t *invar, uint32_t guide);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_find_type4(uint64_t *elem, uint32_t guide);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_conj_G_x0_to_Q_x0(uint64_t *elem, uint32_t *a, uint32_t baby);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_conjugate_involution(uint64_t *elem, uint32_t *a);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM xsp2co1_traces.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_involution_class(uint64_t *elem);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_traces_fast(uint64_t *elem, int32_t *ptrace);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_conjugate_involution_Gx0(uint64_t *elem, uint32_t guide, uint32_t *a);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_map_involution_class_Gx0(uint32_t iclass, uint32_t *a);
/// @endcond 
#ifdef __cplusplus
}
#endif

// %%FROM xsp2co1_map.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT px
MAT24_API
uint32_t xsp2co1_Co1_debug_pool_mapping(uint64_t *dest, uint32_t len);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_Co1_get_mapping(uint32_t *m1, uint32_t *m2, uint32_t *m_out);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_Co1_matrix_to_word(uint32_t *m, uint32_t *g);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_elem_from_mapping(uint32_t *m1, uint32_t *m2, uint32_t *g);
/// @endcond  
#ifdef __cplusplus
}
#endif


// %%FROM xsp2co1_rep_mod3.c
#ifdef __cplusplus
extern "C" {
#endif
/// @cond DO_NOT_DOCUMENT 
// %%EXPORT p
MAT24_API
int32_t xsp2co1_rep_mod3_from_qs(qstate12_type *pqs, uint64_t v3, uint64_t *p_rep);
// %%EXPORT px
MAT24_API
void xsp2co1_rep_mod3_unit_vector(uint32_t i, uint64_t v3, uint64_t *p_rep);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_rep_mod3_mul_elem(uint64_t *p_rep, uint64_t *elem);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_rep_mod3_mul_word(uint64_t *p_rep, uint32_t *a, uint32_t n);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_rep_mod3_conv_mm_op(uint64_t *p_rep, uint64_t *p_wz);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_rep_mod3_scalprod_mm_op(uint64_t *p_rep, uint64_t *p_wz);
// %%EXPORT px
MAT24_API
int32_t xsp2co1_rep_mod3_find_nonzero(uint64_t *p_rep);
/// @endcond  
#ifdef __cplusplus
}
#endif





// %%INCLUDE_HEADERS



#ifdef __cplusplus
}
#endif
#endif  // #ifndef CLIFFORD12_H

