#include <stdio.h>

// Tail-call fold: identical_block_2 (test2.cpp) is the same single block,
// ending in a return.
__attribute__((noinline)) int identical_block_1(int x) {
    int y = x * 13;
    y += 42;
    y ^= 0xdeadbeef;
    y -= 100;
    return y;
}

// Save-and-Jump: sj_block_2 (test2.cpp) has the same body, so every block
// below has an identical copy in another module:
//   * the mixing block ends in `if (h & 1)`, a conditional branch
//                                            -> two-exit Save-and-Jump
//   * the store block falls through to the return block
//                                            -> one-exit Save-and-Jump
//   * the return block                       -> tail-call fold
__attribute__((noinline)) unsigned long sj_block_1(unsigned long a,
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

// Tail-call fold of a block with a call: tc_call_2 (test2.cpp) ends in the
// same tail call to `finish`. It jumps from another address, so its `jmp`
// holds another displacement and the bytes differ; Step 1 compares the
// target instead, and lists it in the directive (`callees=`).
__attribute__((noinline)) unsigned long finish(unsigned long x) {
    return (x ^ (x >> 29)) * 0xbf58476d1ce4e5b9UL;
}

__attribute__((noinline)) unsigned long tc_call_1(unsigned long x) {
    return finish(x * 0x9e3779b97f4a7c15UL + 12345);
}
