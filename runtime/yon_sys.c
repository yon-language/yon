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
#include <pthread.h>
#if defined(__APPLE__)
/* The wait on a word on macOS is os_sync_wait_on_address, the system's public
 * primitive, from macOS 14.4 on; the runtime asks the system whether it has it
 * (__builtin_available) rather than trusting the build's minimum target. Where
 * it is missing, the doorbell of the wire waits on a condition shared between
 * the processes, and the wait on a word of SystemOs looks at the word again
 * after a short sleep. No private interface of the kernel is used. */
#if defined(__has_include)
#if __has_include(<os/os_sync_wait_on_address.h>)
#define YON_OS_SYNC 1
#include <os/os_sync_wait_on_address.h>
#include <os/clock.h>
#endif
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

/* Give the region open on fd at least `bytes` bytes. Two processes that open it
 * at once may both measure it empty; the first sizes it, and a kernel that sizes
 * a shared region only once (macOS) refuses the second with EINVAL. The second
 * then measures again: a region the other already sized is the one it asked for. */
static void yon_sys_shared_size(int fd, size_t bytes) {
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); yon_sys_refuse(YON_REFUSAL_SharedNotMeasured); }
    if ((size_t)st.st_size >= bytes || ftruncate(fd, (off_t)bytes) == 0) return;
    int e = errno;
    if (fstat(fd, &st) == 0 && (size_t)st.st_size >= bytes) return;
    close(fd);
    errno = e;
    yon_sys_refuse(YON_REFUSAL_KernelDidNotSizeShared);
}

int64_t yon_rt_sys_shared_map(double name_d, int64_t words) {
    char n[40];
    yon_sys_shared_kernel_name(name_d, n);
    size_t bytes = ((size_t)words + 1u) * sizeof(int64_t);
    int fd = shm_open(n, O_CREAT | O_RDWR, 0600);
    if (fd < 0) yon_sys_refuse(YON_REFUSAL_KernelDidNotOpenShared);
    yon_sys_shared_size(fd, bytes);
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
    yon_sys_shared_size(fd, bytes);
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
/* One interface for every wait of the runtime on a word shared between
 * processes: yon_word_wait sleeps while the low 32 bits of the word are the
 * expected value, until a wake, the end of the time, or a spurious return;
 * yon_word_wake wakes every sleeper. The kernel's primitive: the futex on
 * Linux, os_sync_wait_on_address on macOS (both on memory shared between
 * processes). The answer of a wait: 0 woken (or the word changed), 2 the time
 * ran out, -1 the system has no wait on a word (macOS before 14.4). */

static int yon_word_wait_available(void) {
#if defined(__APPLE__) && defined(YON_OS_SYNC)
    if (__builtin_available(macOS 14.4, *)) return 1;
    return 0;
#elif defined(__APPLE__)
    return 0;
#elif defined(__linux__)
    return 1;
#else
#error "the wait on a word needs a kernel primitive on this platform"
#endif
}

/* timeout_ns < 0: no end */
static int yon_word_wait(uint32_t *w, uint32_t expected, int64_t timeout_ns) {
#if defined(__APPLE__) && defined(YON_OS_SYNC)
    if (__builtin_available(macOS 14.4, *)) {
        int rc = timeout_ns >= 0
            ? os_sync_wait_on_address_with_timeout(w, (uint64_t)expected, 4,
                  OS_SYNC_WAIT_ON_ADDRESS_SHARED, OS_CLOCK_MACH_ABSOLUTE_TIME,
                  (uint64_t)(timeout_ns > 0 ? timeout_ns : 1))
            : os_sync_wait_on_address(w, (uint64_t)expected, 4,
                  OS_SYNC_WAIT_ON_ADDRESS_SHARED);
        return (rc < 0 && errno == ETIMEDOUT) ? 2 : 0;
    }
    return -1;
#elif defined(__APPLE__)
    (void)w; (void)expected; (void)timeout_ns;
    return -1;
#elif defined(__linux__)
    struct timespec ts, *tp = NULL;
    if (timeout_ns >= 0) {
        ts.tv_sec = timeout_ns / 1000000000; ts.tv_nsec = timeout_ns % 1000000000; tp = &ts;
    }
    long rc = syscall(SYS_futex, w, FUTEX_WAIT, expected, tp, NULL, 0);
    return (rc != 0 && errno == ETIMEDOUT) ? 2 : 0;
#endif
}

/* how many sleepers the kernel reports woken (macOS says only whether one was
 * there: 1 or 0); -1 the system has no wait on a word */
static int yon_word_wake(uint32_t *w) {
#if defined(__APPLE__) && defined(YON_OS_SYNC)
    if (__builtin_available(macOS 14.4, *))
        return os_sync_wake_by_address_all(w, 4, OS_SYNC_WAKE_BY_ADDRESS_SHARED) == 0 ? 1 : 0;
    return -1;
#elif defined(__APPLE__)
    (void)w;
    return -1;
#elif defined(__linux__)
    long rc = syscall(SYS_futex, w, FUTEX_WAKE, INT32_MAX, NULL, NULL, 0);
    return rc < 0 ? 0 : (int)rc;
#endif
}

static int64_t yon_word_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + (int64_t)ts.tv_nsec;
}

/* The wait on a word of SystemOs. The kernel compares the low 32 bits of the
 * word (the width every kernel waits on); the prelude keeps the expected value
 * inside them. The answer: 0 woken (the word changed, or a wake came), 1 the
 * word was not the expected value, 2 the time ran out. Where the system has no
 * wait on a word, the word is looked at again every YON_WORD_LOOK_NS: the same
 * answers, later. */
#define YON_WORD_LOOK_NS 50000

static double yon_sys_wait(int64_t r, int64_t at, int64_t expected,
                           int timed, int64_t timeout_ns) {
    int64_t *w = yon_sys_header(r) + 1 + at;
    if (__atomic_load_n(w, __ATOMIC_SEQ_CST) != expected) return 1.0;
    if (yon_word_wait_available()) {
        int rc = yon_word_wait((uint32_t *)w, (uint32_t)expected, timed ? timeout_ns : -1);
        return rc == 2 ? 2.0 : 0.0;
    }
    int64_t end = timed ? yon_word_now_ns() + timeout_ns : 0;
    for (;;) {
        struct timespec ts = { 0, YON_WORD_LOOK_NS };
        nanosleep(&ts, NULL);
        if (__atomic_load_n(w, __ATOMIC_SEQ_CST) != expected) return 0.0;
        if (timed && yon_word_now_ns() >= end) return 2.0;
    }
}

double yon_rt_sys_wait(int64_t r, int64_t at, int64_t expected) {
    return yon_sys_wait(r, at, expected, 0, 0);
}

double yon_rt_sys_wait_for(int64_t r, int64_t at, int64_t expected, int64_t timeout_ns) {
    return yon_sys_wait(r, at, expected, 1, timeout_ns);
}

/* wakes the waiters on the word; the answer is how many the kernel reports
 * (macOS says only whether one was there: 1 or 0); where the system has no wait
 * on a word the waiters look at the word themselves, and the answer is 0 */
double yon_rt_sys_wake(int64_t r, int64_t at) {
    int64_t *w = yon_sys_header(r) + 1 + at;
    int n = yon_word_wake((uint32_t *)w);
    return n < 0 ? 0.0 : (double)n;
}

/* ─── The doorbell of the wire ───────────────────────────────────────── */
/* A doorbell lives in memory shared between processes (the header of a
 * channel). Who waits reads the bell's count, tries what it waits for, and if
 * it must wait, waits for the count to change: first a short spin on the
 * count, then asleep on it. Who rings changes the count, and wakes the
 * sleepers only if there is one. The order of the two sides (the sleeper
 * counts itself, then reads the count; the ringer changes the count, then
 * reads the sleepers; all sequentially consistent) leaves no wake lost. Where
 * the system has no wait on a word, the sleep is on the bell's condition,
 * shared between the processes. */

/* How long a waiter spins on the count before it sleeps. The rule of the
 * waits in two phases: spin for as long as a sleep and its wake cost, so the
 * wait costs at most twice the best of the two (Karlin, Li, Manasse, Owicki,
 * SOSP 1991). Measured on the round trip of the wire
 * (tools/bench/wire_pingpong.py): asleep at once, a round trip costs about
 * 5 us more than when the answer is caught spinning; with a spin of 5 us the
 * p99 of the round trip is the p50's, and a longer spin buys nothing. */
#ifndef YON_BELL_SPIN_NS
#define YON_BELL_SPIN_NS 5000
#endif

/* the fallback of the condition is forced by the unit test of the bell, so
 * the path of the systems without a wait on a word runs on every machine */
int yon_bell_force_condition = 0;

static int yon_bell_on_word(void) {
    return !yon_bell_force_condition && yon_word_wait_available();
}

const char *yon_rt_wait_mechanism(void) {
    if (!yon_bell_on_word()) return "the condition shared between processes";
#if defined(__APPLE__)
    return "os_sync_wait_on_address";
#else
    return "futex";
#endif
}

size_t yon_bell_size(void) { return sizeof(yon_bell_t); }

int yon_bell_init(yon_bell_t *b) {
    __atomic_store_n(&b->count, 0u, __ATOMIC_SEQ_CST);
    __atomic_store_n(&b->sleepers, 0u, __ATOMIC_SEQ_CST);
    pthread_mutexattr_t ma;
    pthread_condattr_t ca;
    if (pthread_mutexattr_init(&ma) != 0) return -1;
    pthread_mutexattr_setpshared(&ma, PTHREAD_PROCESS_SHARED);
    int rc = pthread_mutex_init(&b->mu, &ma);
    pthread_mutexattr_destroy(&ma);
    if (rc != 0) return -1;
    if (pthread_condattr_init(&ca) != 0) return -1;
    pthread_condattr_setpshared(&ca, PTHREAD_PROCESS_SHARED);
    rc = pthread_cond_init(&b->cv, &ca);
    pthread_condattr_destroy(&ca);
    return rc == 0 ? 0 : -1;
}

uint32_t yon_bell_count(yon_bell_t *b) {
    return __atomic_load_n(&b->count, __ATOMIC_SEQ_CST);
}

static inline void yon_bell_relax(void) {
#if defined(__aarch64__)
    __asm__ __volatile__("yield");
#elif defined(__x86_64__) || defined(__i386__)
    __asm__ __volatile__("pause");
#endif
}

/* Waits for the count to differ from `seen`, until `deadline_ns` (on
 * yon_word_now_ns). 0 the count changed (or a spurious wake: the caller tries
 * again), 2 the time ran out. */
int yon_bell_wait(yon_bell_t *b, uint32_t seen, int64_t deadline_ns) {
    if (YON_BELL_SPIN_NS > 0) {
        int64_t end = yon_word_now_ns() + YON_BELL_SPIN_NS;
        for (uint32_t i = 1;; i++) {
            if (__atomic_load_n(&b->count, __ATOMIC_ACQUIRE) != seen) return 0;
            yon_bell_relax();
            if ((i & 63u) == 0 && yon_word_now_ns() >= end) break;
        }
    }
    int64_t left = deadline_ns - yon_word_now_ns();
    if (left <= 0) return 2;
    __atomic_fetch_add(&b->sleepers, 1u, __ATOMIC_SEQ_CST);
    int rc = 0;
    if (__atomic_load_n(&b->count, __ATOMIC_SEQ_CST) == seen) {
        if (yon_bell_on_word()) {
            rc = yon_word_wait(&b->count, seen, left);
        } else if (pthread_mutex_lock(&b->mu) == 0) {
            struct timespec now, abs;
            clock_gettime(CLOCK_REALTIME, &now);
            int64_t t = (int64_t)now.tv_nsec + left % 1000000000;
            abs.tv_sec = now.tv_sec + (time_t)(left / 1000000000) + (time_t)(t / 1000000000);
            abs.tv_nsec = (long)(t % 1000000000);
            while (__atomic_load_n(&b->count, __ATOMIC_SEQ_CST) == seen) {
                if (pthread_cond_timedwait(&b->cv, &b->mu, &abs) == ETIMEDOUT) { rc = 2; break; }
            }
            pthread_mutex_unlock(&b->mu);
        }
    }
    __atomic_fetch_sub(&b->sleepers, 1u, __ATOMIC_SEQ_CST);
    if (rc == 2 && __atomic_load_n(&b->count, __ATOMIC_SEQ_CST) != seen) rc = 0;
    return rc;
}

void yon_bell_ring(yon_bell_t *b) {
    __atomic_fetch_add(&b->count, 1u, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&b->sleepers, __ATOMIC_SEQ_CST) == 0u) return;
    if (yon_bell_on_word()) {
        yon_word_wake(&b->count);
    } else if (pthread_mutex_lock(&b->mu) == 0) {
        pthread_cond_broadcast(&b->cv);
        pthread_mutex_unlock(&b->mu);
    }
}

/* the deadline of a wait that starts now and lasts `ms` milliseconds */
int64_t yon_bell_deadline_ms(uint32_t ms) {
    return yon_word_now_ns() + (int64_t)ms * 1000000;
}

/* ─── Clocks ─────────────────────────────────────────────────────────── */

static int64_t yon_sys_clock(clockid_t c) {
    struct timespec ts;
    if (clock_gettime(c, &ts) != 0) yon_sys_refuse(YON_REFUSAL_KernelDidNotReadClock);
    return (int64_t)ts.tv_sec * 1000000000 + (int64_t)ts.tv_nsec;
}

/* on macOS CLOCK_MONOTONIC counts whole microseconds; CLOCK_MONOTONIC_RAW
 * counts the ticks of the machine */
#if defined(__APPLE__)
int64_t yon_rt_sys_monotonic_ns(void) { return yon_sys_clock(CLOCK_MONOTONIC_RAW); }
#else
int64_t yon_rt_sys_monotonic_ns(void) { return yon_sys_clock(CLOCK_MONOTONIC); }
#endif
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

/* An integer divided by zero, or its remainder by zero: no integer. */
void yon_rt_int_division_by_zero(void) {
    yon_rt_refuse_with(YON_REFUSAL_DivisionByZero, 0, 0, 0);
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
