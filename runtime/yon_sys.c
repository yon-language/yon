/* yon_sys.c — the face of the operating system.
 *
 * The prelude reaches the kernel through one place, SystemOs, and its
 * `is given` faces land here: memory, shared memory, the wait on a word,
 * the clocks, the arguments, the standard streams, processes. Nothing here allocates a
 * value of the language except what the language asked for (a Text read
 * from the arguments); everything else is a scalar or a region.
 *
 * A region is a run of 64-bit words the kernel gave. Its handle is the
 * address of a one-word header holding the number of words, the words
 * follow it. No table holds regions: a region is its memory, and unmap
 * gives it back. Reading and writing its words is not offered to the
 * language at large: the heaps that live in a region do it, through faces
 * of their own house (read_word, write_word), which land on the two
 * functions at the end of this file.
 *
 * What the kernel refuses (memory it will not map, a write that fails) stops
 * the program with a sentence on stderr and exit code 3, the way every other
 * refusal of the runtime does. What the language can see is wrong before
 * asking (a size, an index, a name) is a DomainError, decided in the prelude.
 *
 * Included by yon_rt.c, as yon_rt_hsh.c is: one object, one link line. */

#include <sys/mman.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#if defined(__APPLE__)
/* The wait on a word on macOS is os_sync_wait_on_address, the system's
 * public primitive, from macOS 14.4 on: it is used when the build's minimum
 * target is at least 14.4. Below that the fallback is __ulock_wait /
 * __ulock_wake, the kernel's compare-and-wait under it, which libc++ uses for
 * atomic wait: not a public interface, declared here by hand. Both wait on
 * the word shared between processes and compare its low 32 bits. */
#if defined(__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__) \
    && __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ >= 140400 \
    && defined(__has_include)
#if __has_include(<os/os_sync_wait_on_address.h>)
#define YON_OS_SYNC 1
#include <os/os_sync_wait_on_address.h>
#include <os/clock.h>
#endif
#endif
#ifndef YON_OS_SYNC
extern int __ulock_wait(uint32_t operation, void *addr, uint64_t value,
                        uint32_t timeout_us);
extern int __ulock_wake(uint32_t operation, void *addr, uint64_t wake_value);
#define YON_UL_COMPARE_AND_WAIT_SHARED 3u
#define YON_ULF_WAKE_ALL               0x00000100u
#define YON_ULF_NO_ERRNO               0x01000000u
#endif
#elif defined(__linux__)
#include <linux/futex.h>
#include <sys/syscall.h>
#endif

/* ─── Refusals ───────────────────────────────────────────────────────── */
/* The refusal itself is runtime/yon_refuse.c; what needs the heap stays here:
 * a name given as the handle of its text, and the text a word names. */

#include "yon_refusals.h"

/* a name the runtime gives, as the handle of its text */
int64_t yon_refusal_name(const char *s) {
    return yon_refusal_real(s ? yon_ds_string(s) : 0.0);
}

/* the text a word names, if it names one: a heap value whose bytes end with
   the one zero of a text; any other word names no text */
const char *yon_refusal_text(int64_t w) {
    double h;
    memcpy(&h, &w, 8);
    if (!(h >= 1.0 && h < 4294967296.0 && h == (double)(uint32_t)h)) return "";
    const yon_xheap_slot_t *s = yon_xheap_get_chain((uint32_t)h);
    if (!s || s->payload_size == 0) return "";
    const char *p = (const char *)yon_xheap_slot_payload_any(s);
    if (!p || p[s->payload_size - 1] != '\0' || strlen(p) != s->payload_size - 1) return "";
    return p;
}

/* the face of the prelude: the refusal is the constant of its arm,
   -(tag + 1); the three words come with it */
double yon_rt_refuse(double r, int64_t a, int64_t b, int64_t c) {
    yon_rt_refuse_with((enum yon_refusal)(-(int64_t)r - 1), a, b, c);
}

static _Noreturn void yon_sys_refuse(enum yon_refusal r) {
    yon_rt_refuse_with(r, errno, 0, 0);
}

static int64_t *yon_sys_header(int64_t r) { return (int64_t *)(intptr_t)r; }

/* ─── Memory ─────────────────────────────────────────────────────────── */

int64_t yon_rt_sys_map(int64_t words) {
    size_t bytes = ((size_t)words + 1u) * sizeof(int64_t);
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) yon_sys_refuse(YON_REFUSAL_KernelDidNotMap);
    ((int64_t *)p)[0] = words;            /* the kernel zeroes the rest */
    return (int64_t)(intptr_t)p;
}

int64_t yon_rt_sys_words(int64_t r) { return yon_sys_header(r)[0]; }

double yon_rt_sys_unmap(int64_t r) {
    int64_t *h = yon_sys_header(r);
    size_t bytes = ((size_t)h[0] + 1u) * sizeof(int64_t);
    if (munmap(h, bytes) != 0) yon_sys_refuse(YON_REFUSAL_KernelDidNotUnmap);
    return 0.0;
}

/* A shared-memory name is 1 to 30 letters, digits, '_' or '-'. The kernel
 * of this system wants it with a leading '/'; the runtime gives it that form,
 * so the name the language sees says nothing of any kernel. */
double yon_rt_sys_is_shared_name(double name_d) {
    const char *n = yon_ds_cstr(name_d);
    if (!n) return 0.0;
    size_t len = strlen(n);
    if (len < 1 || len > 30) return 0.0;
    for (size_t i = 0; i < len; i++) {
        char c = n[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-')) return 0.0;
    }
    return 1.0;
}

static void yon_sys_shared_kernel_name(double name_d, char out[40]) {
    snprintf(out, 40, "/%s", yon_ds_cstr(name_d));
}

int64_t yon_rt_sys_shared_map(double name_d, int64_t words) {
    char n[40];
    yon_sys_shared_kernel_name(name_d, n);
    size_t bytes = ((size_t)words + 1u) * sizeof(int64_t);
    int fd = shm_open(n, O_CREAT | O_RDWR, 0600);
    if (fd < 0) yon_sys_refuse(YON_REFUSAL_KernelDidNotOpenShared);
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); yon_sys_refuse(YON_REFUSAL_SharedNotMeasured); }
    if ((size_t)st.st_size < bytes && ftruncate(fd, (off_t)bytes) != 0) {
        close(fd); yon_sys_refuse(YON_REFUSAL_KernelDidNotSizeShared);
    }
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) yon_sys_refuse(YON_REFUSAL_KernelDidNotMapShared);
    int64_t *h = (int64_t *)p;
    if (h[0] == 0) h[0] = words;          /* the first to map it sizes it */
    else if (h[0] != words)
        yon_rt_refuse_with(YON_REFUSAL_SharedSizeMismatch, yon_refusal_name(n + 1), h[0], words);
    return (int64_t)(intptr_t)p;
}

/* A region shared under a kernel name already in its kernel's form, made by
   the first to ask; every later ask maps the same region. */
static int64_t yon_sys_shared_named(const char *n, int64_t words) {
    size_t bytes = ((size_t)words + 1u) * sizeof(int64_t);
    int fd = shm_open(n, O_CREAT | O_RDWR, 0600);
    if (fd < 0) yon_sys_refuse(YON_REFUSAL_KernelDidNotOpenShared);
    yon_rt_world_register(n);
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); yon_sys_refuse(YON_REFUSAL_SharedNotMeasured); }
    if ((size_t)st.st_size < bytes && ftruncate(fd, (off_t)bytes) != 0) {
        close(fd); yon_sys_refuse(YON_REFUSAL_KernelDidNotSizeShared);
    }
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) yon_sys_refuse(YON_REFUSAL_KernelDidNotMapShared);
    int64_t *h = (int64_t *)p;
    int64_t zero = 0;
    /* the first to map it sizes it; the size is the region's first word */
    if (!__atomic_compare_exchange_n(&h[0], &zero, words, 0,
                                     __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)
        && zero != words)
        yon_rt_refuse_with(YON_REFUSAL_SharedSizeMismatch, yon_refusal_name(n + 1), zero, words);
    return (int64_t)(intptr_t)p;
}

double yon_rt_sys_shared_remove(double name_d) {
    char n[40];
    yon_sys_shared_kernel_name(name_d, n);
    return shm_unlink(n) == 0 ? 1.0 : 0.0;
}

/* ─── The wait on a word ─────────────────────────────────────────────── */
/* The kernel compares the low 32 bits of the word (the width every kernel
 * waits on); the prelude keeps the expected value inside them. The answer:
 * 0 woken (the word changed, or a wake came), 1 the word was not the
 * expected value, 2 the time ran out. */

static double yon_sys_wait(int64_t r, int64_t at, int64_t expected,
                           int timed, int64_t timeout_ns) {
    int64_t *w = yon_sys_header(r) + 1 + at;
    if (__atomic_load_n(w, __ATOMIC_SEQ_CST) != expected) return 1.0;
#if defined(__APPLE__) && defined(YON_OS_SYNC)
    int rc = timed
        ? os_sync_wait_on_address_with_timeout(w, (uint64_t)(uint32_t)expected, 4,
              OS_SYNC_WAIT_ON_ADDRESS_SHARED, OS_CLOCK_MACH_ABSOLUTE_TIME,
              (uint64_t)timeout_ns)
        : os_sync_wait_on_address(w, (uint64_t)(uint32_t)expected, 4,
              OS_SYNC_WAIT_ON_ADDRESS_SHARED);
    if (rc < 0 && errno == ETIMEDOUT) return 2.0;
    return 0.0;
#elif defined(__APPLE__)
    uint32_t us = 0;
    if (timed) {
        int64_t q = timeout_ns / 1000;
        us = (uint32_t)(q < 1 ? 1 : q);
    }
    int rc = __ulock_wait(YON_UL_COMPARE_AND_WAIT_SHARED | YON_ULF_NO_ERRNO,
                          w, (uint64_t)(uint32_t)expected, us);
    if (rc == -ETIMEDOUT) return 2.0;
    return 0.0;
#elif defined(__linux__)
    struct timespec ts, *tp = NULL;
    if (timed) { ts.tv_sec = timeout_ns / 1000000000; ts.tv_nsec = timeout_ns % 1000000000; tp = &ts; }
    long rc = syscall(SYS_futex, (uint32_t *)w, FUTEX_WAIT, (uint32_t)expected, tp, NULL, 0);
    if (rc != 0 && errno == ETIMEDOUT) return 2.0;
    return 0.0;
#else
#error "the wait on a word needs a kernel primitive on this platform"
#endif
}

double yon_rt_sys_wait(int64_t r, int64_t at, int64_t expected) {
    return yon_sys_wait(r, at, expected, 0, 0);
}

double yon_rt_sys_wait_for(int64_t r, int64_t at, int64_t expected, int64_t timeout_ns) {
    return yon_sys_wait(r, at, expected, 1, timeout_ns);
}

/* wakes the waiters on the word; the answer is how many the kernel reports
 * (macOS says only whether one was there: 1 or 0) */
double yon_rt_sys_wake(int64_t r, int64_t at) {
    int64_t *w = yon_sys_header(r) + 1 + at;
#if defined(__APPLE__) && defined(YON_OS_SYNC)
    return os_sync_wake_by_address_all(w, 4, OS_SYNC_WAKE_BY_ADDRESS_SHARED) == 0 ? 1.0 : 0.0;
#elif defined(__APPLE__)
    int rc = __ulock_wake(YON_UL_COMPARE_AND_WAIT_SHARED | YON_ULF_WAKE_ALL | YON_ULF_NO_ERRNO, w, 0);
    return rc == 0 ? 1.0 : 0.0;
#elif defined(__linux__)
    long rc = syscall(SYS_futex, (uint32_t *)w, FUTEX_WAKE, INT32_MAX, NULL, NULL, 0);
    return rc < 0 ? 0.0 : (double)rc;
#endif
}

/* ─── Clocks ─────────────────────────────────────────────────────────── */

static int64_t yon_sys_clock(clockid_t c) {
    struct timespec ts;
    if (clock_gettime(c, &ts) != 0) yon_sys_refuse(YON_REFUSAL_KernelDidNotReadClock);
    return (int64_t)ts.tv_sec * 1000000000 + (int64_t)ts.tv_nsec;
}

int64_t yon_rt_sys_monotonic_ns(void) { return yon_sys_clock(CLOCK_MONOTONIC); }
int64_t yon_rt_sys_wall_ns(void) { return yon_sys_clock(CLOCK_REALTIME); }

/* ─── The standard streams ───────────────────────────────────────────── */

static double yon_sys_write_all(int fd, double text_d) {
    const char *s = yon_ds_cstr(text_d);
    size_t len = s ? strlen(s) : 0, done = 0;
    while (done < len) {
        ssize_t w = write(fd, s + done, len - done);
        if (w < 0) {
            if (errno == EINTR) continue;
            yon_sys_refuse(YON_REFUSAL_KernelDidNotWrite);
        }
        done += (size_t)w;
    }
    return (double)done;
}

double yon_rt_sys_write_output(double text_d) { return yon_sys_write_all(1, text_d); }
double yon_rt_sys_write_error(double text_d) { return yon_sys_write_all(2, text_d); }

/* ─── Arguments ──────────────────────────────────────────────────────── */
/* the prelude has checked the index */

double yon_rt_sys_arg_count(void) { return (double)g_argc; }
double yon_rt_sys_arg(double i_d) { return yon_ds_string(g_argv[(int)i_d]); }

/* ─── Processes ──────────────────────────────────────────────────────── */

double yon_rt_sys_process_id(void) { return (double)getpid(); }

/* a process is there when the kernel knows it, even one we may not touch */
double yon_rt_sys_process_exists(double pid_d) {
    return (kill((pid_t)pid_d, 0) == 0 || errno == EPERM) ? 1.0 : 0.0;
}

double yon_rt_sys_terminate(double pid_d) {
    return kill((pid_t)pid_d, SIGKILL) == 0 ? 1.0 : 0.0;
}

/* ─── Arithmetic out of its range ────────────────────────────────────── */

/* an Int64 sum, difference or product outside [-2^63, 2^63) */
void yon_rt_int64_overflow(void) {
    yon_rt_refuse_with(YON_REFUSAL_Int64Overflow, 0, 0, 0);
}

/* ─── The words of a region, for the heaps that live in it ───────────── */

static int64_t *yon_sys_word(int64_t r, int64_t at) {
    int64_t *h = yon_sys_header(r);
    if (at < 0 || at >= h[0])
        yon_rt_refuse_with(YON_REFUSAL_WordOutsideRegion, at, h[0], 0);
    return h + 1 + at;
}

int64_t yon_rt_region_read(int64_t r, int64_t at) {
    return __atomic_load_n(yon_sys_word(r, at), __ATOMIC_ACQUIRE);
}

double yon_rt_region_write(int64_t r, int64_t at, int64_t w) {
    __atomic_store_n(yon_sys_word(r, at), w, __ATOMIC_RELEASE);
    return 0.0;
}

/* The word becomes `desired` if it is `expected`, in one step that no other
   process sharing the region can split; the answer is the word it found. */
int64_t yon_rt_region_cas(int64_t r, int64_t at, int64_t expected, int64_t desired) {
    int64_t found = expected;
    __atomic_compare_exchange_n(yon_sys_word(r, at), &found, desired, 0,
                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return found;
}
