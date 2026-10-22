"""The correctness guards of the benchmarks under regression/bench/.

Each bench prints a line of integers; some are guards, values the work must
produce whatever the machine (the size it built, a value it reads back), the
rest are timings. A bench reads YON_BENCH_DIV and divides the size of its
work by it; `guards(d)` gives each bench's guards at divisor d: (index of the
printed integer, expected value). d = 1 is the full measurement.
"""


def guards(d: int = 1) -> dict:
    return {
        "eq_constant": [(0, 1), (1, 1024), (2, 32768)],
        "hashset": [(0, 100000 // d), (2, 1)],
        "hashmap": [(0, 100000 // d), (2, 43)],
        "vec": [(0, 100000), (2, 42)],
        "list": [(0, 100000), (2, 99999)],
        "merkle": [(0, 1), (1, 0)],
        "xrel_points": [(0, 1), (1, 1), (5, 200000 // d)],
        "xset": [(0, 1000), (1, 3000)],
        # every (family, key kind) at N = 1000: size, hits, misses found,
        # |union|, |intersection|
        "maps_compare": [(5 * c + j, v) for c in range(6)
                         for j, v in enumerate([1000, 1000, 0, 1500, 500])],
        "golay": [(0, 1445)],
        "heap_expand": [(0, 1000000)],
    }
