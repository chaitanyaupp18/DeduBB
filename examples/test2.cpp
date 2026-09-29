#include <stdio.h>

extern int identical_block_1(int x);
extern unsigned long sj_block_1(unsigned long a, unsigned long b,
                                unsigned long n, unsigned long *out);

__attribute__((noinline)) int identical_block_2(int x) {
    int y = x * 13;
    y += 42;
    y ^= 0xdeadbeef;
    y -= 100;
    return y;
}

// Same body as sj_block_1 in test1.cpp.
__attribute__((noinline)) unsigned long sj_block_2(unsigned long a,
                                                   unsigned long b,
                                                   unsigned long n,
                                                   unsigned long *out) {
    if (n == 0)
        return 0;
    unsigned long h = (a ^ (a >> 33)) * 0xff51afd7ed558ccdUL;
    h = (h ^ (h >> 33)) * 0xc4ceb9fe1a85ec53UL;
    h ^= h >> 33;
    if (h & 1) {
        out[0] = h * 3;
        out[1] = h ^ a;
        out[2] = h + b;
        out[3] = h - n;
    }
    return h ^ (h >> 17) ^ n ^ b;
}

int main(int argc, char** argv) {
    printf("%d %d\n", identical_block_1(argc), identical_block_2(argc));
    // Both paths of `if (h & 1)` are taken for these inputs; the two columns
    // of each line must match before and after deduplication.
    unsigned long out1[4] = {0}, out2[4] = {0};
    for (unsigned long i = 0; i < 6; ++i) {
        unsigned long r1 = sj_block_1(i * 7 + argc, i + 3, i, out1);
        unsigned long r2 = sj_block_2(i * 7 + argc, i + 3, i, out2);
        printf("%lu %lu | %lu %lu\n", r1, r2, out1[1] ^ out1[3],
               out2[1] ^ out2[3]);
    }
    return 0;
}
