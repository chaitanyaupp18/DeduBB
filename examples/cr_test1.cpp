// Call-Return: cr_block_2 (cr_test2.cpp) has the same second block, which
// makes a call in its middle. A tail-call fold needs a block that ends the
// function, and Save-and-Jump a block without calls (a call clobbers %r11 and
// %r10), so neither can share it. Call-Return moves the block's body into one
// shared routine that both copies call.
unsigned long step(unsigned long a);
unsigned long mix(unsigned long h, unsigned long a);

__attribute__((noinline)) unsigned long cr_block_1(unsigned long a,
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
