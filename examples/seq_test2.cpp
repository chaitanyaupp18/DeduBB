#include <stdio.h>

extern unsigned long seq_mix_1(unsigned long *p, unsigned long x);
extern unsigned long seq_end_1(unsigned long *p, unsigned long x);

// Same mixing as seq_mix_1 in seq_test1.cpp, between other work.
__attribute__((noinline)) unsigned long seq_mix_2(unsigned long *p,
                                                  unsigned long x) {
    p[3] = x * 5;
    unsigned long h = (x ^ (x >> 31)) * 0x9e3779b97f4a7c15UL;
    h = (h ^ (h >> 27)) * 0x94d049bb133111ebUL;
    h ^= h >> 31;
    p[1] = h;
    return h - p[0];
}

__attribute__((noinline)) unsigned long seq_report(unsigned long *p,
                                                   unsigned long x) {
    return x ^ p[0] ^ p[1];
}

// Same ending as seq_end_1 in seq_test1.cpp.
__attribute__((noinline)) unsigned long seq_end_2(unsigned long *p,
                                                  unsigned long x) {
    p[3] = x - 9;
    p[0] += x;
    p[1] ^= x;
    return seq_report(p, x + p[2]);
}

int main(int argc, char **argv) {
    unsigned long p[4] = {1, 2, 3, 4};
    for (unsigned long i = 0; i < 4; ++i) {
        unsigned long a = seq_mix_1(p, i + argc);
        unsigned long b = seq_mix_2(p, i + argc);
        unsigned long c = seq_end_1(p, a) + seq_end_2(p, b);
        printf("%lu %lu %lu %lu %lu %lu %lu\n", a, b, c, p[0], p[1], p[2], p[3]);
    }
    return 0;
}
