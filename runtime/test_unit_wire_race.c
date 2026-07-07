/* test_unit_wire_race.c — concurrent reproducer for the cross-process SHM wire.
 *
 * Producer (child) and consumer (parent) run AT THE SAME TIME on one channel,
 * each hammering the ring under back-pressure. Every value is 1.0, so a correct
 * transport delivers exactly N values summing to N. If the cross-process lock
 * around head/tail/count does not actually serialize (e.g. flock() on an shm fd
 * that is a no-op across processes on this platform), the counters race: values
 * are lost or double-read and got/sum diverge from N. This is Bug B, exercised
 * concurrently instead of sequentially.
 *
 * Handles are passed as void* — yon_shm_stream_t is anonymous inside yon_rt.c;
 * a pointer is a pointer at the ABI, so the opaque form links cleanly. */
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/wait.h>

extern void *yon_rt_stream_shm_open(const char *name, uint32_t slot_size,
                                    uint32_t capacity, int create);
extern int   yon_rt_stream_shm_produce_blocking(void *s, const void *value_ptr);
extern int   yon_rt_stream_shm_await_blocking(void *s, void *out_ptr);
extern int   yon_rt_stream_shm_close_write(void *s);
extern void  yon_rt_stream_shm_close(void *s);
extern int   yon_rt_stream_shm_unlink(const char *name);

/* yon_rt.o references __yon_dispatch (the Yon method dispatcher); tests that
 * link it but don't emit Yon code provide a no-op. */
double __yon_dispatch(double a, double b, double c) { (void)a;(void)b;(void)c; return 0.0; }

#define CHAN "wire_race"
#define N     100000L
#define CAP   256u          /* small ring => constant wrap + back-pressure contention */

int main(void) {
    yon_rt_stream_shm_unlink(CHAN);                       /* fresh */
    void *s = yon_rt_stream_shm_open(CHAN, sizeof(double), CAP, 1);
    if (!s) { printf("WIRE_RACE: FAIL (create)\n"); return 1; }

    pid_t pid = fork();
    if (pid == 0) {                                       /* child: producer */
        void *sp = yon_rt_stream_shm_open(CHAN, sizeof(double), CAP, 0);
        if (sp) {
            double one = 1.0;
            for (long k = 0; k < N; k++)
                yon_rt_stream_shm_produce_blocking(sp, &one);
            yon_rt_stream_shm_close_write(sp);
            yon_rt_stream_shm_close(sp);
        }
        _exit(0);
    }

    double sum = 0.0; long got = 0; double v;             /* parent: consumer */
    for (;;) {
        int rc = yon_rt_stream_shm_await_blocking(s, &v);
        if (rc != 0) break;                               /* -2 EOF, -1 timeout */
        sum += v; got++;
    }
    int st; waitpid(pid, &st, 0);
    yon_rt_stream_shm_close(s);
    yon_rt_stream_shm_unlink(CHAN);

    if (got == N && sum == (double)N)
        printf("WIRE_RACE: PASS (%ld values, sum %.0f)\n", got, sum);
    else
        printf("WIRE_RACE: FAIL got=%ld sum=%.0f expected=%ld\n", got, sum, N);
    return 0;
}
