<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:6EE7B7,100:3B82F6&height=200&section=header&text=DeduBB&fontSize=48&fontColor=ffffff&fontAlignY=38&desc=Cross-module%20basic%20block%20deduplication%20(DeduBB)%20integrated%20into%20LLVM%20CodeGen%20and%20Propeller.&descAlignY=58&descSize=16" width="100%" />
</div>

# DeduBB

DeduBB reduces binary code size by deduplicating machine code across functions
and modules. It finds identical basic blocks and instruction sequences in a
linked binary, keeps one copy (the master), and replaces the duplicates with
jumps or calls to that copy.

This implementation uses Propeller to identify duplicates and LLVM CodeGen to
fold them when the program is rebuilt. It supports whole-block and subsequence
folding.

For details, see [DeduBB: Binary Code Size Reduction via Post-Link Basic Block
Deduplication](https://dl.acm.org/doi/10.1145/3814943.3816169) (LCTES '26).

## How it works

1. Build the program with `-fbasic-block-address-map`.
2. Run Propeller's `generate_propeller_profiles` on the binary to produce a
   directive file describing the masters and duplicates.
3. Rebuild the program with the directives. LLVM's code generator replaces
   each duplicate with a jump or call to its master.

DeduBB uses three folding strategies:

| Strategy | Eligible code | Replacement |
| --- | --- | --- |
| Tail Call | A block, or its final instructions, ending in a return or tail call | A `jmp` to the master |
| Save-and-Jump | A block or instruction sequence that use the stack | A `jmp` to the master, which jumps back through `%r11` |
| Call-Return | A block's body or instruction sequence that may make calls but leaves the stack alone | A `call` to the master, which returns |

Subsequence folding applies these strategies to part of a block: its final
instructions or an instruction sequence within it.

## Building

The following commands build the X86 target using the revisions required by
the patches. You will need Git, CMake, Ninja, and a C/C++ build toolchain.

Set `DEDUBB_ROOT` to the absolute path of your DeduBB checkout:

```bash
export DEDUBB_ROOT=/absolute/path/to/DeduBB
```

Build the patched LLVM toolchain:

```bash
git clone https://github.com/llvm/llvm-project.git
cd llvm-project
git checkout 333edde4e
git apply "$DEDUBB_ROOT/patches/llvm-project-dedubb.patch"

cmake -G Ninja -S llvm -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD=X86
ninja -C build clang lld

export PATH="$PWD/build/bin:$PATH"
cd ..
```

Build the patched Propeller tool:

```bash
git clone https://github.com/google/llvm-propeller.git
cd llvm-propeller
git checkout e2c7049
git apply "$DEDUBB_ROOT/patches/llvm-propeller-dedubb.patch"

cmake -G Ninja -B build
ninja -C build generate_propeller_profiles
```

The examples below assume that the patched `clang++`, `ld.lld`, and
`generate_propeller_profiles` executables are on your `PATH`. Alternatively,
invoke the executables by their full paths.

## Usage

Build a baseline binary:

```bash
FLAGS="-O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld \
      -Wl,--lto-basic-block-address-map -Wl,-z,keep-text-section-prefix"
clang++ $FLAGS a.cpp b.cpp -o app
```

Generate the deduplication directives:

```bash
generate_propeller_profiles \
 --binary=app \
 --dedubb_profile=dedubb.txt \
 --dedubb_subsequence
```

Rebuild with the directives:

```bash
clang++ $FLAGS -Wl,-mllvm,-dedubb-directives=dedubb.txt \
 a.cpp b.cpp -o app.dedubb
```

Both builds must use the same sources, compiler, and flags, apart from the
DeduBB directives supplied to the second build. Omit `--dedubb_subsequence`
to fold only whole blocks. With `-Wl,-z,keep-text-section-prefix`, the masters
are placed in a separate `.text.dedubb` section.

## Optimizing Clang

[`optimize_clang.sh`](optimize_clang.sh) builds Clang at `-Oz` with
`--gc-sections` and `--icf=all`. It compares the baseline, DeduBB, and LLVM's
MachineOutliner with one and two rounds. Sizes are written to:

```text
clang_dedubb_binaries/Results/sizes_clang_dedup.txt
```

| Clang, x86-64 | Code (`.text*`) | Stripped binary |
| --- | --- | --- |
| Baseline | 37,975,721 B | 71,377,784 B |
| DeduBB | −9.81% | −6.55% |
| MachineOutliner | −2.60% | +0.85% |
| MachineOutliner (two rounds) | −7.38% | −2.83% |

Each outlined function gets its own unwind entry, so the outliner's binary
shrinks less than its code, and grows with one round. DeduBB's masters share
one entry per module.

In our experiments, additional MachineOutliner reruns
(`-machine-outliner-reruns=5`) made Clang larger in both tested modes.

The [`performance`](https://github.com/chaitanyaupp18/DeduBB/tree/performance)
branch also folds only cold blocks, from a profile, adds Propeller's code
layout, and times each compiler building Clang.

## Directive format

The following example comes from [`examples/seq_test1.cpp`](examples/seq_test1.cpp)
and [`examples/seq_test2.cpp`](examples/seq_test2.cpp). The `body=` values have
been shortened.

```text
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

- `m` and `f` identify the source file and function for the records that follow.
  The source file is informational.
- `bbm` keeps a master; `bbf` folds a duplicate into it. The suffix selects the
  strategy: no suffix for Tail Call, `cr` for Call-Return, and `sj` for
  Save-and-Jump.
- The number after the record type is the block's ID in the basic-block
  address map. The parenthesized name identifies the group shared by a master
  and its folds.
- `at=` is the subsequence's starting instruction, counted from zero.
  `block_insts=` is the number of instructions in the original block, and
  `insts=` is the number of instructions folded. Tail Call folding runs from
  `at=` to the end of the block. Without `at=`, the whole block is folded.
- `callees=` lists the functions called or jumped to. On a master's record,
  `body=` contains the master's machine code in hexadecimal.

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

