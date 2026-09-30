#include <stdio.h>

extern unsigned long seq_mix_1(unsigned long *p, unsigned long x);

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

int main(int argc, char **argv) {
    unsigned long p[4] = {1, 2, 3, 4};
    for (unsigned long i = 0; i < 4; ++i) {
        unsigned long a = seq_mix_1(p, i + argc);
        unsigned long b = seq_mix_2(p, i + argc);
        printf("%lu %lu %lu %lu %lu %lu\n", a, b, p[0], p[1], p[2], p[3]);
    }
    return 0;
}
