<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:6EE7B7,100:3B82F6&height=200&section=header&text=DeduBB&fontSize=48&fontColor=ffffff&fontAlignY=38&desc=Cross-module%20basic%20block%20deduplication%20(DeduBB)%20as%20a%20BOLT%20pass.&descAlignY=58&descSize=16" width="100%" />
</div>

# DeduBB

DeduBB reduces binary code size by deduplicating machine code across functions and modules. It finds identical basic blocks and instruction sequences in a linked binary, keeps one copy (the master), and replaces the duplicates with jumps or calls to that copy.

This branch implements DeduBB as a [BOLT](https://github.com/llvm/llvm-project/tree/main/bolt) pass, which finds the duplicates in the linked binary and folds them in the same run, without rebuilding the program. The [`main`](https://github.com/chaitanyaupp18/DeduBB) branch uses Propeller to find them and LLVM CodeGen to fold them. It supports whole-block and subsequence folding.

For details, see [DeduBB: Binary Code Size Reduction via Post-Link Basic Block
Deduplication](https://dl.acm.org/doi/10.1145/3814943.3816169) (LCTES '26).

On Clang ([ThinLTO](https://dl.acm.org/doi/10.5555/3049832.3049845) build),
BOLT with DeduBB removes 9.77% of the machine code, against 0.04% for BOLT
alone. The savings come on top of a baseline already built for size: ThinLTO
at `-Oz`, linked with `--gc-sections` and `--icf=all`, and with
`--emit-relocs` for BOLT. Every build in the table uses these flags.

| Clang, x86-64 | Code (`.text*`) | Stripped binary |
| --- | --- | --- |
| Baseline: `-Oz`, `--gc-sections`, `--icf=all` | 37.9 MB | 71.3 MB |
| [BOLT](https://doi.org/10.1109/CGO.2019.8661201) | −0.04% | +4.09% |
| BOLT + DeduBB | −9.77% | +5.62% |

BOLT rewrites the linked binary in place. The sections after the code keep
their addresses, so the bytes DeduBB folds away stay in the file, and BOLT
appends what no longer fits where it was: the jump tables it moves and, with
DeduBB, the index of unwind entries, which gains one entry for the masters.
The [`main`](https://github.com/chaitanyaupp18/DeduBB) branch folds while
linking, so its stripped binary shrinks with its code (−6.55%).
[Optimizing Clang](#optimizing-clang) shows how to reproduce these numbers.

## How it works

1. Link the program with `-Wl,--emit-relocs`, so that BOLT can rewrite it.
2. Run `llvm-bolt` with `--dedubb`. The pass finds the duplicates in the
   binary and replaces each with a jump or call to its master.

DeduBB uses three folding strategies:

| Strategy | Eligible code | Replacement |
| --- | --- | --- |
| Tail Call | A block, or its final instructions, ending in a return or tail call | A `jmp` to the master |
| Save-and-Jump | An instruction sequence that uses the stack | A `jmp` to the master, which jumps back through `%r11` |
| Call-Return | An instruction sequence that may make calls but leaves the stack alone | A `call` to the master, which returns |

Subsequence folding applies these strategies to part of a block: its final
instructions or an instruction sequence within it.

The masters are placed in a `.text.dedubb` section. A Call-Return master's
calls may not take arguments on the stack, so the pass leaves out any call
that a write to `0(%rsp)`, where a call's first stack argument goes, reaches
after the call before it. Unlike `main`, this branch does not fold blocks
together with their branches by Save-and-Jump.

## Building

The following commands build the X86 target using the revision required by
the patch. You will need Git, CMake, Ninja, and a C/C++ build toolchain.

Set `DEDUBB_ROOT` to the absolute path of your DeduBB checkout:

```bash
export DEDUBB_ROOT=/absolute/path/to/DeduBB
```

Build the patched LLVM toolchain, BOLT included:

```bash
git clone https://github.com/llvm/llvm-project.git
cd llvm-project
git checkout 333edde4e
git apply "$DEDUBB_ROOT/patches/llvm-project-bolt-dedubb.patch"

cmake -G Ninja -S llvm -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld;bolt" \
  -DLLVM_TARGETS_TO_BUILD=X86
ninja -C build clang lld llvm-bolt

export PATH="$PWD/build/bin:$PATH"
cd ..
```

The examples below assume that the patched `clang++`, `ld.lld`, and
`llvm-bolt` executables are on your `PATH`. Alternatively, invoke the
executables by their full paths.

## Usage

Build a baseline binary, keeping its relocations for BOLT:

```bash
FLAGS="-O2 -flto=thin -fuse-ld=lld -Wl,--emit-relocs"
clang++ $FLAGS a.cpp b.cpp -o app
```

Fold the duplicates, then strip the result:

```bash
llvm-bolt app -o app.dedubb --dedubb
llvm-strip app.dedubb
```

With `--dedubb`, BOLT also defaults to `--use-old-text`, `--use-gnu-stack`,
and `--align-functions=1`, and aligns the new code as the original `.text`
was: the new code goes where the original code was, the program header table
stays in place, and functions get no padding. Options given explicitly take
precedence. When BOLT must add a segment, `--use-gnu-stack` turns the
`GNU_STACK` program header into it, so the output no longer marks its stack
as non-executable.

| Option | Description |
| --- | --- |
| `--dedubb` | Fold repeated machine code |
| `--dedubb-kinds=tc,cr,sj` | Strategies to use: Tail Call, Call-Return, and Save-and-Jump |
| `--dedubb-call-return-calls` | Let Call-Return masters make calls (default: on) |
| `--dedubb-cold-only` | Fold only blocks that the profile (`-data`) shows did not run |
| `--dedubb-skip-aliased` | Leave alone functions with more than one symbol (default: on) |
| `--print-dedubb` | Print the functions after the pass |

## Optimizing Clang

[`optimize_clang.sh`](optimize_clang.sh) builds Clang at `-Oz` with
`--gc-sections` and `--icf=all`, then optimizes it with BOLT, without and with
DeduBB. Sizes are written to:

```text
clang_dedubb_binaries/Results/sizes_clang_dedup.txt
```

Each compiler, stripped, then rebuilds Clang. The script times the builds and
checks that each compiler builds the same Clang, bit for bit, as the baseline
compiler:

```text
clang_dedubb_binaries/Results/perf_clang_dedup.txt
```

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

## License

Original DeduBB contributions are licensed under the
[Apache License 2.0](LICENSE), except where otherwise noted.

The BOLT patch is provided under
[Apache License 2.0 with LLVM Exceptions](LICENSE-LLVM), the license of
BOLT and the rest of the LLVM Project. Upstream copyright and license
notices are retained.

See [NOTICE](NOTICE) for attribution.
