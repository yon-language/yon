/* yon_mmap.c — the one allocation primitive of the Yon runtime. See yon_mmap.h.
 * mmap always; private anonymous by default, named shared as the sole
 * exception for cross-Space structures. */
#define _GNU_SOURCE  /* ftruncate on glibc; harmless under _DARWIN_C_SOURCE */
#include "yon_mmap.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

/* macOS: MAP_ANONYMOUS may be spelled MAP_ANON (BSD). */
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

void *yon_map(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("[YON-RT] yon_map");
        abort();
    }
    return p;  /* kernel-zeroed: callers rely on a clean region */
}

void yon_unmap(void *p, size_t size) {
    if (p) munmap(p, size);
}

void *yon_map_shared(const char *shm_name, size_t size, int create) {
    int flags = create ? (O_RDWR | O_CREAT) : O_RDWR;
    int fd = shm_open(shm_name, flags, 0600);
    if (fd < 0) {
        perror("[YON-RT] yon_map_shared shm_open");
        return NULL;
    }
    if (create && ftruncate(fd, (off_t)size) != 0) {
        perror("[YON-RT] yon_map_shared ftruncate");
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);  /* the mapping outlives the descriptor */
    if (p == MAP_FAILED) {
        perror("[YON-RT] yon_map_shared mmap");
        return NULL;
    }
    return p;
}
