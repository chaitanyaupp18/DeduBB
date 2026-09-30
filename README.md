# DeduBB

DeduBB removes duplicate machine code across a whole program. It finds basic
blocks that are identical anywhere in a linked binary, across source files and
ThinLTO modules, keeps one copy of each (the **master**), and turns every other
copy into a jump or a call to it.

It works in two steps:

1. **Find duplicates.** [Propeller](https://github.com/google/llvm-propeller)'s
   `generate_propeller_profiles` reads a binary built with
   `-fbasic-block-address-map`, compares its blocks and writes a *directive
   file*.
2. **Fold them.** The program is built again with the directives, and passes in
   LLVM's code generator (run by lld for ThinLTO builds) replace each duplicate.

This repository holds the patches for LLVM and Propeller, a small example, and
a script that measures DeduBB on clang.

## What DeduBB folds

| Case | Duplicate block | It becomes | Directives |
| --- | --- | --- | --- |
| Tail call | ends in a return or a tail call | a `jmp` to the master | `bbm` / `bbf` |
| Save-and-Jump | falls through or ends in a `jmp`; no calls | a `jmp`, with its successor in `%r11` | `bbmsj` / `bbfsj` |
| Two-exit Save-and-Jump | ends in a conditional branch; no calls | a `jmp`, with both successors in `%r11` and `%r10` | `bbmsj2` / `bbfsj2` |
| Call-Return | the body before the block's branches, calls included | a `call` to a shared copy of the body | `bbmcr` / `bbfcr` |

```asm
# Tail call: the master's own return or tail call finishes for the duplicate.
dup:    jmp   DeduBB.master.K

# Save-and-Jump: the duplicate passes its successor, the master jumps back.
dup:    lea   next(%rip), %r11           master:  <the shared block>
        jmp   DeduBB.master.sj.K                  jmp   *%r11

# Two-exit Save-and-Jump: both successors, and the master's branch picks one.
dup:    lea   taken(%rip), %r11          master:  <the shared block>
        lea   not_taken(%rip), %r10               j<cc> 1f
        jmp   DeduBB.master.sj2.K                 jmp   *%r10
                                              1:  jmp   *%r11

# Call-Return: the duplicate calls the shared body, then runs its own branches.
dup:    call  DeduBB.master.cr.K         master:  <the shared body>
        <its own branches>                        ret
```

What makes a fold safe:

* Every copy must do the same thing at its own address. A direct call or jump
  must reach the same function from every copy (the directive lists these
  targets), and blocks with `%rip`-relative data references are left alone.
* Tail-call and Save-and-Jump folds never touch the stack: the master runs in
  the duplicate's frame. Save-and-Jump needs a block without calls, since a
  call clobbers `%r11` and `%r10`.
* A Call-Return stub pushes a return address (and, when the body makes calls,
  8 bytes of padding with `push %rax` ... `lea 8(%rsp),%rsp`). So the body must
  not use `%rsp`, its function must not keep data in the red zone, and a body
  with calls must not pass arguments on the stack. The masters live in one
  function per module, `DeduBB.cr.masters`, emitted from the bytes Step 1
  compared.
* The compiler re-checks what it can see (a block's calls, its successors,
  and for Call-Return its number of instructions) and leaves a block alone if
  they do not match. It cannot see the rest of the code, so the directives must
  come from a binary built from the same sources, compiler and flags.

## Directive file

```
m <module>                                   # the source file (informational)
f <function>                                 # the blocks below are in it
bbm <bb> (DeduBB.master.<K>) [callees=<c>]   # tail call: block <bb> is master K
bbf <bb> (DeduBB.master.<K>) [callees=<c>]   # tail call: fold block <bb> into K
bbmsj / bbfsj   <bb> (DeduBB.master.sj.<K>)  # Save-and-Jump
bbmsj2 / bbfsj2 <bb> (DeduBB.master.sj2.<K>) # two-exit Save-and-Jump
bbmcr / bbfcr   <bb> (DeduBB.master.cr.<K>) callees=<c> insts=<n> [body=<hex>]
```

`<bb>` is the block's ID in the basic-block address map, and all blocks of one
group share `<K>`.

* `callees=` lists the targets of the block's direct calls and jumps, in order
  and separated by `,`. A target with several names (aliases) lists them
  separated by `|`, and `*` stands for an indirect call (Call-Return only).
* `insts=` is the number of instructions in a Call-Return body.
* `body=` is the Call-Return master's code in hex, split by `.` where each
  direct call goes. Only the master's line has it.

For the [examples](examples), Step 1 writes (tail-call part):

```
m test1.cpp
f _Z10sj_block_1mmmPm
bbm 3 (DeduBB.master.1)
f _Z17identical_block_1i
bbm 0 (DeduBB.master.0)
f _Z9tc_call_1m
bbm 0 (DeduBB.master.2) callees=_Z6finishm
m test2.cpp
f _Z10sj_block_2mmmPm
bbf 3 (DeduBB.master.1)
f _Z17identical_block_2i
bbf 0 (DeduBB.master.0)
f _Z9tc_call_2m
bbf 0 (DeduBB.master.2) callees=_Z6finishm
```

and, with `--dedubb_call_return` (Call-Return part):

```
m cr_test1.cpp
f _Z10cr_block_1mPm
bbmcr 1 (DeduBB.master.cr.1) callees=_Z3mixmm insts=13 body=48b9157c4a7fb979379e480fafc14989064889c74889de.4889c148c1e91f4831c149894e08488d0c1849894e10a801
m cr_test2.cpp
f _Z10cr_block_2mPm
bbfcr 1 (DeduBB.master.cr.1) callees=_Z3mixmm insts=13
```

`tc_call_1` and `tc_call_2` tail-call the same function from different
addresses, so their bytes differ in the `jmp`; the block matches because its
target does.

## Quickstart

### Building the toolchain

DeduBB is a patch on LLVM (`clang` and `lld`) and one on Propeller. Propeller's
own prerequisites are listed in its
[README](https://github.com/google/llvm-propeller#prerequisites-and-dependencies).

```bash
# LLVM, with the DeduBB passes.
git clone https://github.com/llvm/llvm-project.git
cd llvm-project && git checkout 333edde4e
git apply /path/to/this/repo/patches/llvm-project-dedubb.patch
cmake -G Ninja -S llvm -B build -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD=X86
ninja -C build clang lld
cd ..

# Propeller, with DeduBB's Step 1.
git clone https://github.com/google/llvm-propeller.git
cd llvm-propeller && git checkout e2c7049
git apply /path/to/this/repo/patches/llvm-propeller-dedubb.patch
cmake -G Ninja -B build
ninja -C build generate_propeller_profiles
```

### Deduplicating a program

With the `clang++` and `generate_propeller_profiles` built above:

```bash
# 1. Build with the basic-block address map.
clang++ -O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld \
    -Wl,--lto-basic-block-address-map a.cpp b.cpp -o app

# 2. Find the identical blocks and write the directives.
generate_propeller_profiles --binary=app --dedubb_profile=dedubb.txt \
    --dedubb_call_return

# 3. Build again with the same flags, plus the directives.
clang++ -O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld \
    -Wl,--lto-basic-block-address-map \
    -Wl,-mllvm,-dedubb-directives=dedubb.txt a.cpp b.cpp -o app.dedubb
```

* Both builds need the same compiler and the same flags,
  `-fbasic-block-address-map` included: directives name blocks by their IDs.
* Without LTO, pass `-mllvm -dedubb-directives=dedubb.txt` to each compile.
* With a ThinLTO cache, give step 3 a new cache directory: the cache key covers
  neither the directives nor the linker, so an old cache returns the old code.

Other options of step 2:

| Option | Effect |
| --- | --- |
| `--dedubb_call_return` | also write Call-Return directives |
| `--dedubb_call_return_estimate` | only log what Call-Return would save |
| `--dedubb_intra_module_only` | fold only within a module |
| `--dedubb_skip_aliased_functions` | leave alone functions with several names, such as the ones `--icf` merged, so the linker can merge them again (default `true`) |
| `--dedubb_cold_only` | fold only blocks that never ran, according to the profile |

### Trying the examples

`examples/test1.cpp` and `examples/test2.cpp` hold one pair of identical
functions per tail-call and Save-and-Jump case, one function of each pair per
file. `examples/cr_test1.cpp` and `examples/cr_test2.cpp` hold a block with a
call in its middle, for Call-Return.

```bash
cd examples
CXX="clang++ -g -O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld -Wl,--lto-basic-block-address-map"

$CXX test1.cpp test2.cpp -o before
generate_propeller_profiles --binary=before --dedubb_profile=dedubb.txt
$CXX -Wl,-mllvm,-dedubb-directives=dedubb.txt test1.cpp test2.cpp -o after
diff <(./before) <(./after) && echo "same output"
objdump -d after | grep -A1 '<_Z9tc_call_2m>:'   # jmp <_Z9tc_call_1m>, the master

$CXX cr_test1.cpp cr_test2.cpp -o cr_before
generate_propeller_profiles --binary=cr_before --dedubb_profile=cr.txt --dedubb_call_return
$CXX -Wl,-mllvm,-dedubb-directives=cr.txt cr_test1.cpp cr_test2.cpp -o cr_after
diff <(./cr_before) <(./cr_after) && echo "same output"
```

`-g` only gives Step 1 the module names of the `m` lines.

## Reproducing on clang

`reproduce_dedubb_clang.sh` clones LLVM and Propeller at the commits above,
applies the patches, builds clang once with the basic-block address map and
once with the DeduBB directives, and prints both sizes to
`clang_dedubb_binaries/Results/sizes_clang_dedup.txt`. Both builds use `-Oz`,
`-ffunction-sections -fdata-sections`, `--gc-sections` and `--icf=all`.
`DEDUBB_SIZE_OPT=0` builds at `-O3` instead, and `DEDUBB_CALL_RETURN=0` leaves
out Call-Return.

```bash
./reproduce_dedubb_clang.sh
```
