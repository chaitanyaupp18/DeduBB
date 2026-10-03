<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:6EE7B7,100:3B82F6&height=200&section=header&text=DeduBB&fontSize=48&fontColor=ffffff&fontAlignY=38&desc=Cross-module%20basic%20block%20deduplication%20(DeduBB)%20integrated%20into%20LLVM%20CodeGen%20and%20Propeller.&descAlignY=58&descSize=16" width="100%" />
</div>


# DeduBB

DeduBB removes duplicate machine code across a whole program. It finds basic
blocks, and runs of instructions inside blocks, that are identical anywhere in
a linked binary, keeps one copy of each (the master), and turns every other
copy into a jump or a call to it.

Paper: [DeduBB: Binary Code Size Reduction via Post-Link Basic Block
Deduplication](https://dl.acm.org/doi/10.1145/3814943.3816169) (LCTES '26).

## How it works

1. **Find.** Propeller's `generate_propeller_profiles` reads a binary built with
   `-fbasic-block-address-map` and writes a directive file that names the
   duplicates by function and basic block.
2. **Fold.** The program is built again with the directives, and passes in
   LLVM's code generator replace each duplicate.

| Fold | Duplicate | Becomes |
| --- | --- | --- |
| Tail call | a block, or its last instructions, ending in a return or a tail call | a `jmp` to the master |
| Save-and-Jump | a block, or a run of instructions in it, that use the stack | a `jmp` to the master, which jumps back through `%r11` |
| Call-Return | a block's body, or a run of instructions in it, that may make calls but leaves the stack alone | a `call` to the master, which returns |

A `call` moves `%rsp`, so a Call-Return master cannot run code that addresses
the stack. Save-and-Jump pushes nothing: its master runs in the duplicate's own
frame, so it takes that code (spills, reloads, stack arguments, red-zone data).

## Build

```bash
git clone https://github.com/llvm/llvm-project.git && cd llvm-project
git checkout 333edde4e && git apply /path/to/DeduBB/patches/llvm-project-dedubb.patch
cmake -G Ninja -S llvm -B build -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD=X86
ninja -C build clang lld && cd ..

git clone https://github.com/google/llvm-propeller.git && cd llvm-propeller
git checkout e2c7049 && git apply /path/to/DeduBB/patches/llvm-propeller-dedubb.patch
cmake -G Ninja -B build && ninja -C build generate_propeller_profiles
```

## Use

```bash
FLAGS="-O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld -Wl,--lto-basic-block-address-map"
clang++ $FLAGS a.cpp b.cpp -o app
generate_propeller_profiles --binary=app --dedubb_profile=dedubb.txt --dedubb_subsequence
clang++ $FLAGS -Wl,-mllvm,-dedubb-directives=dedubb.txt a.cpp b.cpp -o app.dedubb
```

Both builds need the same sources, compiler and flags. Without
`--dedubb_subsequence`, only whole blocks are folded. `examples/` holds small
programs with each kind of duplicate.

## Reproducing on clang

`reproduce_dedubb_clang.sh` builds clang at `-Oz` with `--gc-sections` and
`--icf=all`, once as the baseline and once with DeduBB (and, for comparison,
with LLVM's MachineOutliner), and writes the sizes to
`clang_dedubb_binaries/Results/sizes_clang_dedup.txt`.

## Citation

```bibtex
@inproceedings{dedubb2026,
  title     = {DeduBB: Binary Code Size Reduction via Post-Link Basic Block Deduplication},
  author    = {Mamatha Ananda, Chaitanya and Afarin, Mahbod and Gupta, Rajiv and
               Tallam, Sriraman and Shen, Han and Li, Xinliang David},
  booktitle = {Proceedings of the 27th ACM SIGPLAN/SIGBED International Conference on
               Languages, Compilers, and Tools for Embedded Systems},
  series    = {LCTES '26},
  pages     = {43--56},
  year      = {2026},
  publisher = {ACM},
  doi       = {10.1145/3814943.3816169}
}
```

}
```
