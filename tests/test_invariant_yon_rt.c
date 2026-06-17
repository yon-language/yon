#include <check.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Forward declarations of functions from runtime/yon_rt.c */
extern int yon_rt_process(const uint8_t *payload, size_t payload_len, uint8_t *out, size_t out_capacity);

START_TEST(test_memcpy_bounds_invariant)
{
    /* Invariant: memcpy operations must not write beyond destination buffer capacity,
       regardless of size/offset parameters derived from untrusted input */
    
    struct {
        const char *name;
        const uint8_t *payload;
        size_t payload_len;
        size_t out_capacity;
    } test_cases[] = {
        /* Valid input: small payload within bounds */
        {
            "valid_small",
            (const uint8_t *)"\x00\x05hello",
            7,
            256
        },
        /* Boundary: payload size equals buffer capacity */
        {
            "boundary_exact_fit",
            (const uint8_t *)"\x00\x10" "0123456789abcdef",
            18,
            16
        },
        /* Attack: size field claims more data than exists */
        {
            "attack_oversized_claim",
            (const uint8_t *)"\x00\xff" "short",
            7,
            64
        },
        /* Attack: offset + size exceeds payload length */
        {
            "attack_offset_overflow",
            (const uint8_t *)"\x10\x20" "data",
            6,
            128
        },
        /* Attack: maximum size values */
        {
            "attack_max_size",
            (const uint8_t *)"\xff\xff" "x",
            4,
            32
        }
    };
    
    int num_cases = sizeof(test_cases) / sizeof(test_cases[0]);
    
    for (int i = 0; i < num_cases; i++) {
        uint8_t *out = malloc(test_cases[i].out_capacity);
        ck_assert_ptr_nonnull(out);
        
        /* Fill buffer with sentinel value to detect out-of-bounds writes */
        memset(out, 0xAA, test_cases[i].out_capacity);
        uint8_t sentinel_before = out[test_cases[i].out_capacity - 1];
        
        /* Call production function with adversarial input */
        int result = yon_rt_process(
            test_cases[i].payload,
            test_cases[i].payload_len,
            out,
            test_cases[i].out_capacity
        );
        
        /* Security property: buffer boundary must not be violated */
        uint8_t sentinel_after = out[test_cases[i].out_capacity - 1];
        ck_assert_msg(
            sentinel_after == sentinel_before,
            "Buffer overflow detected in case '%s': sentinel corrupted",
            test_cases[i].name
        );
        
        /* Verify no write beyond capacity occurred */
        for (size_t j = 0; j < test_cases[i].out_capacity; j++) {
            ck_assert_msg(
                out[j] != 0xBB,
                "Out-of-bounds write detected in case '%s' at offset %zu",
                test_cases[i].name,
                j
            );
        }
        
        free(out);
    }
}
END_TEST

Suite *security_suite(void)
{
    Suite *s;
    TCase *tc_core;

    s = suite_create("Security");
    tc_core = tcase_create("Core");

    tcase_add_test(tc_core, test_memcpy_bounds_invariant);
    suite_add_tcase(s, tc_core);

    return s;
}

int main(void)
{
    int number_failed;
    Suite *s;
    SRunner *sr;

    s = security_suite();
    sr = srunner_create(s);

    srunner_run_all(sr, CK_NORMAL);
    number_failed = srunner_ntests_failed(sr);
    srunner_free(sr);

    return (number_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}