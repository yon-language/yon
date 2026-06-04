# Yon runtime — portable build (Linux / macOS).
# Override: make CC=clang MMGROUP_DIR=$(python3 -c 'import mmgroup,os;print(os.path.dirname(mmgroup.__file__))')
CC ?= gcc
MMGROUP_DIR ?= $(shell python3 -c 'import mmgroup,os;print(os.path.dirname(mmgroup.__file__))' 2>/dev/null || echo /usr/local/lib/python3.12/dist-packages/mmgroup)
CFLAGS ?= -std=c11 -D_DARWIN_C_SOURCE -O2 -Wall -Wextra -Werror -I$(MMGROUP_DIR)/dev/headers
LDFLAGS ?= -L$(MMGROUP_DIR) -Wl,-rpath,$(MMGROUP_DIR) -lmmgroup_mat24 -lmmgroup_mm_op -lpthread
OBJS = xleech2_coord.o xleech2_heap.o xleech2_mphf.o xleech2_handler_stack.o yon_rt.o
all: $(OBJS)
yon_rt.o: yon_rt.c yon_rt_hsh.c
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
clean:
	rm -f *.o
.PHONY: all clean
