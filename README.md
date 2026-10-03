<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:6EE7B7,100:3B82F6&height=200&section=header&text=DeduBB&fontSize=48&fontColor=ffffff&fontAlignY=38&desc=Cross-module%20basic%20block%20deduplication%20(DeduBB)%20integrated%20into%20LLVM%20CodeGen%20and%20Propeller.&descAlignY=58&descSize=16" width="100%" />
</div>


# DeduBB

DeduBB removes duplicate machine code across a whole program. It finds basic
blocks, and runs of instructions inside blocks, that are identical anywhere in
a linked binary, keeps one copy (the master), and turns every other copy into
a jump or a call to it.

Paper: [DeduBB: Binary Code Size Reduction via Post-Link Basic Block
Deduplication](https://dl.acm.org/doi/10.1145/3814943.3816169) (LCTES '26).

## How it works

1. **Find.** Propeller's `generate_propeller_profiles` reads a binary built with
   `-fbasic-block-address-map` and writes a directive file.
2. **Fold.** The program is built again with the directives, and LLVM's code
   generator replaces each duplicate.

| Fold | Duplicate | Becomes |
| --- | --- | --- |
| Tail call | a block, or its last instructions, ending in a return or a tail call | a `jmp` to the master |
| Save-and-Jump | a block, or a run of instructions in it, that may use the stack but makes no calls | a `jmp` to the master, which jumps back through `%r11` |
| Call-Return | a block's body, or a run of instructions in it, that may make calls but leaves the stack alone | a `call` to the master, which returns |

Folding part of a block, its last instructions or a run inside it, is
*subsequence folding*.

## Directive file

From [`examples/seq_test1.cpp`, `examples/seq_test2.cpp`](examples) (`body=`
shortened):

```
m seq_test1.cpp
f _Z9seq_end_1Pmm
bbm 0 (DeduBB.master.0) callees=_Z10seq_reportPmm at=2 block_insts=7
f _Z9seq_mix_1Pmm
bbmcr 0 (DeduBB.master.cr.1) callees= insts=14 at=2 block_insts=18 body=4889f048c1e81f...
m seq_test2.cpp
f _Z9seq_end_2Pmm
bbf 0 (DeduBB.master.0) callees=_Z10seq_reportPmm at=1 block_insts=6
f _Z9seq_mix_2Pmm
bbfcr 0 (DeduBB.master.cr.1) callees= insts=14 at=2 block_insts=18
f main
bbmsj 0 (DeduBB.master.sj.4) insts=4 at=29 block_insts=130 body=4c8b442410...
bbfsj 0 (DeduBB.master.sj.4) insts=4 at=57 block_insts=130
```

* `m`, `f`: the source file (informational) and the function of the lines below.
* `bbm` keeps the master, `bbf` folds into it: tail call (no suffix),
  Call-Return (`cr`) or Save-and-Jump (`sj`).
* `0`: the block's ID in the basic-block address map. `(DeduBB.master.K)`: the
  group; its master and folds share `K`.
* `at=`, `block_insts=`: subsequence folding, from instruction `at` (counting
  from 0) of a block of `block_insts` instructions, to the end for a tail call.
  `insts=`: the number of instructions folded. Without `at=`, the whole block is
  folded.
* `callees=`: the functions called or jumped to. `body=`: on the master's line,
  the master's code in hex.

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
FLAGS="-O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld \
       -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix"
clang++ $FLAGS a.cpp b.cpp -o app
generate_propeller_profiles --binary=app --dedubb_profile=dedubb.txt --dedubb_subsequence
clang++ $FLAGS -Wl,-mllvm,-dedubb-directives=dedubb.txt a.cpp b.cpp -o app.dedubb
```

Both builds need the same sources, compiler and flags. Without
`--dedubb_subsequence`, only whole blocks are folded. With
`-z keep-text-section-prefix`, the masters get a section of their own,
`.text.dedubb`.

## Optimizing clang

`optimize_clang.sh` builds clang at `-Oz` with `--gc-sections` and `--icf=all`:
as the baseline, with DeduBB, and, for comparison, with LLVM's MachineOutliner
(one and two rounds). It writes the sizes to
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

Rerunning the MachineOutliner (`-machine-outliner-reruns=5`) didn't help: it
made clang larger in both modes.
