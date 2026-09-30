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
