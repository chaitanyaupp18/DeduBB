// Range folds: a run of instructions that repeats inside blocks that differ
// before and after it. seq_mix_2 (seq_test2.cpp) mixes its input the same way,
// between work of its own, so the blocks differ but the mixing run in the
// middle is shared.
__attribute__((noinline)) unsigned long seq_mix_1(unsigned long *p,
                                                  unsigned long x) {
    p[0] = x + 1;
    unsigned long h = (x ^ (x >> 31)) * 0x9e3779b97f4a7c15UL;
    h = (h ^ (h >> 27)) * 0x94d049bb133111ebUL;
    h ^= h >> 31;
    p[1] = h;
    return h + p[2];
}

extern unsigned long seq_report(unsigned long *p, unsigned long x);

// A tail-call ending: seq_end_2 (seq_test2.cpp) ends the same way, with the
// same tail call, after a start of its own.
__attribute__((noinline)) unsigned long seq_end_1(unsigned long *p,
                                                  unsigned long x) {
    p[3] = x * 7;
    p[0] += x;
    p[1] ^= x;
    return seq_report(p, x + p[2]);
}
