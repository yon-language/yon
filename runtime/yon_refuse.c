/* yon_refuse.c — the refusal of the runtime: it stops a program it cannot
 * carry on. The reasons and their sentences are the prelude's place Refusal,
 * generated into yon_refusals.h; this file writes "error: " and the sentence
 * of a reason, the three words of the occasion in the places the sentence
 * gives them, and ends the program with exit code 3. It depends on nothing
 * else, so every part of the runtime can refuse.
 *
 * The words of the occasion: {a} an integer, {a:f} the bits of a real, {a:x}
 * a type root, {a:s} the text a word names (read by the runtime's heap, when
 * it is linked), {a:e} an errno. */

#define YON_REFUSAL_SENTENCES
#include "yon_refusals.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int64_t yon_refusal_real(double x) { int64_t w; memcpy(&w, &x, 8); return w; }

/* without the heap a word names no text */
__attribute__((weak)) const char *yon_refusal_text(int64_t w) { (void)w; return ""; }

_Noreturn void yon_rt_refuse_with(enum yon_refusal r, int64_t a, int64_t b, int64_t c) {
    fflush(stdout);
    const char *s = ((int)r >= 0 && r < YON_REFUSAL_COUNT)
        ? yon_refusal_sentence[r]
        : "the runtime stopped for a reason it does not know";
    int64_t w[3] = { a, b, c };
    fputs("error: ", stderr);
    for (const char *p = s; *p; p++) {
        if (p[0] == '{' && p[1] >= 'a' && p[1] <= 'c') {
            int64_t v = w[p[1] - 'a'];
            char kind = (p[2] == ':') ? p[3] : 'i';
            const char *end = strchr(p, '}');
            if (!end) { fputc(*p, stderr); continue; }
            double x;
            switch (kind) {
            case 'f': memcpy(&x, &v, 8); fprintf(stderr, "%.17g", x); break;
            case 'x': fprintf(stderr, "%016llx", (unsigned long long)v); break;
            case 's': fputs(yon_refusal_text(v), stderr); break;
            case 'e': fputs(strerror((int)v), stderr); break;
            default:  fprintf(stderr, "%lld", (long long)v); break;
            }
            p = end;
        } else fputc(*p, stderr);
    }
    fputc('\n', stderr);
    exit(3);
}
