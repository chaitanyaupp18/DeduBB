#include <stdio.h>

extern unsigned long cr_block_1(unsigned long a, unsigned long *out);

__attribute__((noinline)) unsigned long step(unsigned long a) {
    return a % 5 ? a * 3 + 1 : 0;
}

__attribute__((noinline)) unsigned long mix(unsigned long h, unsigned long a) {
    h ^= h >> 29;
    return h * (a | 1);
}

// Same body as cr_block_1 in cr_test1.cpp.
__attribute__((noinline)) unsigned long cr_block_2(unsigned long a,
                                                   unsigned long *out) {
    unsigned long h = step(a);
    if (h == 0)
        return 0;
    h *= 0x9e3779b97f4a7c15UL;
    out[0] = h;
    h = mix(h, a);
    out[1] = h ^ (h >> 31);
    out[2] = h + a;
    if (h & 1)
        out[3] = h;
    return h ^ a;
}

int main(int argc, char **argv) {
    // Every path of both functions is taken for these inputs; the two halves
    // of each line must match, before and after deduplication.
    for (unsigned long i = 0; i < 8; ++i) {
        unsigned long out1[4] = {0}, out2[4] = {0};
        unsigned long r1 = cr_block_1(i + argc, out1);
        unsigned long r2 = cr_block_2(i + argc, out2);
        printf("%lu %lu %lu %lu | %lu %lu %lu %lu\n", r1, out1[0], out1[1] ^ out1[2],
               out1[3], r2, out2[0], out2[1] ^ out2[2], out2[3]);
    }
    return 0;
}
