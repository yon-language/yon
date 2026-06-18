# Yon runtime — portable build (Linux / macOS). Self-contained:
# the mmgroup mathematical core (Golay code, Leech lattice) is VENDORED
# under vendor/mmgroup (BSD-2-Clause, see PROVENANCE.md there).
# No Python, no pip, no external shared libraries.
CC ?= gcc
# Platform feature macros: Darwin needs _DARWIN_C_SOURCE, Linux needs
# _GNU_SOURCE (madvise/MADV_DONTNEED, ftruncate). Without this the build is
# Mac-only despite the "portable" claim.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  PLATFORM_DEFS := -D_DARWIN_C_SOURCE
else
  PLATFORM_DEFS := -D_GNU_SOURCE
endif
CFLAGS ?= -std=c11 $(PLATFORM_DEFS) -O2 -Wall -Wextra -Werror -Ivendor/mmgroup
VENDOR_SRCS = vendor/mmgroup/mat24_tables.c vendor/mmgroup/mat24_functions.c \
              vendor/mmgroup/gen_leech.c vendor/mmgroup/gen_leech3.c \
              vendor/mmgroup/gen_leech_type.c vendor/mmgroup/gen_leech_reduce.c \
              vendor/mmgroup/gen_xi_functions.c vendor/mmgroup/mm_group_n.c \
              vendor/mmgroup/mm_index.c
VENDOR_OBJS = $(VENDOR_SRCS:.c=.o)
OBJS = xleech2_coord.o xleech2_heap.o xleech2_mphf.o xleech2_handler_stack.o yon_mmap.o leech_orbits.o yon_arena.o yon_curtis_canon.o yon_rt.o $(VENDOR_OBJS)
all: $(OBJS)
yon_rt.o: yon_rt.c yon_rt_hsh.c
# vendored generated code: compiled relaxed (no -Werror promises on
# generated output we must not edit)
vendor/mmgroup/%.o: vendor/mmgroup/%.c
	$(CC) -std=c11 -O2 -Ivendor/mmgroup -c $< -o $@
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
clean:
	rm -f *.o vendor/mmgroup/*.o
.PHONY: all clean
