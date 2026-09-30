# DeduBB: Cross-Module Reproducibility Guide

A minimal test case that shows Propeller and the `DeduBB` CodeGen pass finding identical basic blocks in different modules and folding every duplicate into one shared copy, the **master**.

## How blocks are folded

| Kind | Block shape | Directives |
|---|---|---|
| **Tail call** | ends in a return or tail call | `bbm` / `bbf` |
| **Save-and-Jump** | ends in an unconditional branch or falls through, no calls | `bbmsj` / `bbfsj` |
| **Two-exit Save-and-Jump** | ends in a conditional branch, no calls | `bbmsj2` / `bbfsj2` |
| **Call-Return** | any body before the block's branches, calls included (`--dedubb_call_return`) | `bbmcr` / `bbfcr` |

```asm
# Tail call: the master's own `ret` returns for the duplicate.
duplicate:  jmp   DeduBB.master.K

# Save-and-Jump: the duplicate passes its successor in %r11.
duplicate:  lea   Succ(%rip), %r11
            jmp   DeduBB.master.sj.K
master:     ...                          # the shared block
            jmp   *%r11                  # continue at the duplicate's successor

# Two-exit Save-and-Jump: both successors travel in registers.
duplicate:  lea   Taken(%rip), %r11
            lea   NotTaken(%rip), %r10
            jmp   DeduBB.master.sj2.K
master:     ...                          # the shared block, same condition
            j<cc> 1f
            jmp   *%r10                  # branch not taken
1:          jmp   *%r11                  # branch taken

# Call-Return: the duplicate calls the shared body, then runs its own branches.
duplicate:  call  DeduBB.master.cr.K     # a body without calls
            <its own branches>
duplicate:  push  %rax                   # a body with calls: keep the stack
            call  DeduBB.master.cr.K     #   16-byte aligned for them
            lea   8(%rsp), %rsp          # (push and lea leave the flags alone)
            <its own branches>
master:     ...                          # the shared body, in DeduBB.cr.masters
            ret
```

Tail-call and Save-and-Jump folds never touch the stack: the master runs in the duplicate's frame and continues exactly where the duplicate would have. A Call-Return fold only pushes onto the stack (the return address, plus 8 bytes of padding when the body makes calls), so its body must not use `%rsp` itself, and its function must not keep data below `%rsp` (the red zone) or, for a body with calls, pass arguments on the stack.

## 1. The Test Case (Before & After Assembly)

`examples/test1.cpp` and `examples/test2.cpp` hold two pairs of identical functions, one function of each pair per file:

* `identical_block_1` / `identical_block_2`: a single block that ends in `ret`.
* `sj_block_1` / `sj_block_2`: besides the entry check, three foldable blocks:
  * **bb 1** mixes the input and ends in `if (h & 1)`, a conditional branch: *two-exit Save-and-Jump*;
  * **bb 2** holds the stores of the `if` and falls through to the return block: *Save-and-Jump*;
  * **bb 3** is the return block: *tail call*.

Because the copies live in separate translation units, the standard compiler cannot deduplicate them.

### 1a. Tail call

**Before (Baseline):** the two functions are byte-identical.

```assembly
00000000000017f0 <_Z17identical_block_1i>:
    17f0:       8d 04 7f                lea    (%rdi,%rdi,2),%eax
    17f3:       8d 04 87                lea    (%rdi,%rax,4),%eax
    17f6:       83 c0 2a                add    $0x2a,%eax
    17f9:       35 ef be ad de          xor    $0xdeadbeef,%eax
    17fe:       83 c0 9c                add    $0xffffff9c,%eax
    1801:       c3                      ret

0000000000001890 <_Z17identical_block_2i>:
    1890:       8d 04 7f                lea    (%rdi,%rdi,2),%eax
    1893:       8d 04 87                lea    (%rdi,%rax,4),%eax
    1896:       83 c0 2a                add    $0x2a,%eax
    1899:       35 ef be ad de          xor    $0xdeadbeef,%eax
    189e:       83 c0 9c                add    $0xffffff9c,%eax
    18a1:       c3                      ret
```

**After DeduBB:** the block in `identical_block_1` becomes the global `DeduBB.master.0` (at the function's first instruction, so `objdump` shows the function name). The copy in `identical_block_2` is replaced with a jump to it, which the ThinLTO link resolves across modules.

```assembly
00000000000018a8 <_Z17identical_block_2i>:
    18a8:       e9 43 ff ff ff          jmp    17f0 <_Z17identical_block_1i>
```

### 1b. Save-and-Jump

**Before (Baseline):** `sj_block_1` is byte-identical to `sj_block_2`, shown here.

```assembly
00000000000018b0 <_Z10sj_block_2mmmPm>:
    18b0:       48 85 d2                test   %rdx,%rdx                     # bb 0: if (n == 0)
    18b3:       74 6c                   je     1921 <_Z10sj_block_2mmmPm+0x71>
    18b5:       48 89 f8                mov    %rdi,%rax                     # bb 1: mix, then if (h & 1)
    18b8:       48 c1 e8 21             shr    $0x21,%rax
    18bc:       48 31 f8                xor    %rdi,%rax
    18bf:       49 b8 cd 8c 55 ed d7    movabs $0xff51afd7ed558ccd,%r8
    18c6:       af 51 ff
    18c9:       4c 0f af c0             imul   %rax,%r8
    18cd:       4c 89 c0                mov    %r8,%rax
    18d0:       48 c1 e8 21             shr    $0x21,%rax
    18d4:       4c 31 c0                xor    %r8,%rax
    18d7:       49 b8 53 ec 85 1a fe    movabs $0xc4ceb9fe1a85ec53,%r8
    18de:       b9 ce c4
    18e1:       4c 0f af c0             imul   %rax,%r8
    18e5:       4c 89 c0                mov    %r8,%rax
    18e8:       48 c1 e8 21             shr    $0x21,%rax
    18ec:       4c 31 c0                xor    %r8,%rax
    18ef:       a8 01                   test   $0x1,%al
    18f1:       74 20                   je     1913 <_Z10sj_block_2mmmPm+0x63>
    18f3:       4c 8d 04 40             lea    (%rax,%rax,2),%r8             # bb 2: the stores
    18f7:       4c 89 01                mov    %r8,(%rcx)
    18fa:       48 31 c7                xor    %rax,%rdi
    18fd:       48 89 79 08             mov    %rdi,0x8(%rcx)
    1901:       48 8d 3c 30             lea    (%rax,%rsi,1),%rdi
    1905:       48 89 79 10             mov    %rdi,0x10(%rcx)
    1909:       48 89 c7                mov    %rax,%rdi
    190c:       48 29 d7                sub    %rdx,%rdi
    190f:       48 89 79 18             mov    %rdi,0x18(%rcx)
    1913:       48 31 d6                xor    %rdx,%rsi                     # bb 3: return
    1916:       48 31 c6                xor    %rax,%rsi
    1919:       48 c1 e8 11             shr    $0x11,%rax
    191d:       48 31 f0                xor    %rsi,%rax
    1920:       c3                      ret
    1921:       31 c0                   xor    %eax,%eax                     # bb 4: return 0
    1923:       c3                      ret
```

**After DeduBB:** `sj_block_1` keeps the three blocks and now holds the three masters, each with a global label. Inside `sj_block_1` itself, the way into a Save-and-Jump master first passes the `lea`s that load that master's own return addresses (at `1819`, `1820` and `186b`).

```assembly
0000000000001810 <_Z10sj_block_1mmmPm>:
    1810:       48 85 d2                test   %rdx,%rdx
    1813:       0f 84 8a 00 00 00       je     18a3 <DeduBB.master.1+0xe>
    1819:       4c 8d 1d 75 00 00 00    lea    0x75(%rip),%r11        # 1895 <DeduBB.master.1>
    1820:       4c 8d 15 44 00 00 00    lea    0x44(%rip),%r10        # 186b <DeduBB.master.sj2.3+0x44>

0000000000001827 <DeduBB.master.sj2.3>:
    1827:       48 89 f8                mov    %rdi,%rax
    ...                                 (the rest of bb 1, unchanged)
    1861:       a8 01                   test   $0x1,%al
    1863:       74 03                   je     1868 <DeduBB.master.sj2.3+0x41>
    1865:       41 ff e2                jmp    *%r10
    1868:       41 ff e3                jmp    *%r11
    186b:       4c 8d 1d 23 00 00 00    lea    0x23(%rip),%r11        # 1895 <DeduBB.master.1>

0000000000001872 <DeduBB.master.sj.2>:
    1872:       4c 8d 04 40             lea    (%rax,%rax,2),%r8
    ...                                 (the rest of bb 2, unchanged)
    188e:       48 89 79 18             mov    %rdi,0x18(%rcx)
    1892:       41 ff e3                jmp    *%r11

0000000000001895 <DeduBB.master.1>:
    1895:       48 31 d6                xor    %rdx,%rsi
    1898:       48 31 c6                xor    %rax,%rsi
    189b:       48 c1 e8 11             shr    $0x11,%rax
    189f:       48 31 f0                xor    %rsi,%rax
    18a2:       c3                      ret
    18a3:       31 c0                   xor    %eax,%eax
    18a5:       c3                      ret
```

`sj_block_2` shrinks from 0x74 to 0x2c bytes: each of its three blocks is now a stub that jumps into `sj_block_1`.

```assembly
00000000000018b0 <_Z10sj_block_2mmmPm>:
    18b0:       48 85 d2                test   %rdx,%rdx
    18b3:       74 24                   je     18d9 <_Z10sj_block_2mmmPm+0x29>
    18b5:       4c 8d 1d 18 00 00 00    lea    0x18(%rip),%r11        # 18d4 <_Z10sj_block_2mmmPm+0x24>
    18bc:       4c 8d 15 05 00 00 00    lea    0x5(%rip),%r10         # 18c8 <_Z10sj_block_2mmmPm+0x18>
    18c3:       e9 5f ff ff ff          jmp    1827 <DeduBB.master.sj2.3>
    18c8:       4c 8d 1d 05 00 00 00    lea    0x5(%rip),%r11         # 18d4 <_Z10sj_block_2mmmPm+0x24>
    18cf:       e9 9e ff ff ff          jmp    1872 <DeduBB.master.sj.2>
    18d4:       e9 bc ff ff ff          jmp    1895 <DeduBB.master.1>
    18d9:       31 c0                   xor    %eax,%eax
    18db:       c3                      ret
```

Following a call to `sj_block_2`:

1. **bb 1 at `18b5` (two-exit Save-and-Jump).** It loads where to continue in `sj_block_2`, `18d4` if the branch is taken and `18c8` if not, into `%r11` and `%r10`, then jumps to `DeduBB.master.sj2.3`. The master computes `h`, tests it, and jumps through `%r11` or `%r10`.
2. **bb 2 at `18c8` (Save-and-Jump).** It loads its successor `18d4` into `%r11` and jumps to `DeduBB.master.sj.2`, which does the stores and returns with `jmp *%r11`.
3. **bb 3 at `18d4` (tail call).** It jumps to `DeduBB.master.1`, whose `ret` returns from `sj_block_2`.

### 1c. Call-Return

`examples/cr_test1.cpp` and `examples/cr_test2.cpp` hold `cr_block_1` / `cr_block_2`. Their bb 1 makes a call in its middle, so the folds above cannot share it: a tail call needs a block that ends the function, and Save-and-Jump a block without calls (a call clobbers `%r11` and `%r10`). This example is built with `--dedubb_call_return` (Step 2 below).

**Before (Baseline):** `cr_block_1` is byte-identical to `cr_block_2`, shown here.

```assembly
00000000000018e0 <_Z10cr_block_2mPm>:
    18e0:       41 56                   push   %r14                          # bb 0: h = step(a); if (h == 0)
    18e2:       53                      push   %rbx
    18e3:       50                      push   %rax
    18e4:       49 89 f6                mov    %rsi,%r14
    18e7:       48 89 fb                mov    %rdi,%rbx
    18ea:       e8 a1 ff ff ff          call   1890 <_Z4stepm>
    18ef:       48 85 c0                test   %rax,%rax
    18f2:       74 3f                   je     1933 <_Z10cr_block_2mPm+0x53>
    18f4:       48 b9 15 7c 4a 7f b9    movabs $0x9e3779b97f4a7c15,%rcx      # bb 1: the shared body,
    18fb:       79 37 9e                                                     #   with a call in it
    18fe:       48 0f af c1             imul   %rcx,%rax
    1902:       49 89 06                mov    %rax,(%r14)
    1905:       48 89 c7                mov    %rax,%rdi
    1908:       48 89 de                mov    %rbx,%rsi
    190b:       e8 b0 ff ff ff          call   18c0 <_Z3mixmm>
    1910:       48 89 c1                mov    %rax,%rcx
    1913:       48 c1 e9 1f             shr    $0x1f,%rcx
    1917:       48 31 c1                xor    %rax,%rcx
    191a:       49 89 4e 08             mov    %rcx,0x8(%r14)
    191e:       48 8d 0c 18             lea    (%rax,%rbx,1),%rcx
    1922:       49 89 4e 10             mov    %rcx,0x10(%r14)
    1926:       a8 01                   test   $0x1,%al
    1928:       74 04                   je     192e <_Z10cr_block_2mPm+0x4e> #   ... then if (h & 1)
    192a:       49 89 46 18             mov    %rax,0x18(%r14)               # bb 2
    192e:       48 31 d8                xor    %rbx,%rax                     # bb 3
    1931:       eb 02                   jmp    1935 <_Z10cr_block_2mPm+0x55>
    1933:       31 c0                   xor    %eax,%eax                     # bb 5
    1935:       48 83 c4 08             add    $0x8,%rsp                     # bb 4: return
    1939:       5b                      pop    %rbx
    193a:       41 5e                   pop    %r14
    193c:       c3                      ret
```

**After DeduBB:** bb 1 of both functions becomes a call to `DeduBB.master.cr.1`. The compiler emits that master, from the bytes Step 1 compared, in a function of its own, `DeduBB.cr.masters`, which has its own unwind info (`objdump` shows the function's name, since the first master sits at its start). The body makes a call itself, so the stub keeps the stack 16-byte aligned for it with `push %rax` and `lea 0x8(%rsp),%rsp`. Neither writes the flags, so the `je` after the stub still tests the body's `test $0x1,%al`. The return block, bb 4, is a tail-call fold as before.

```assembly
0000000000001910 <_Z10cr_block_2mPm>:
    1910:       41 56                   push   %r14
    1912:       53                      push   %rbx
    1913:       50                      push   %rax
    1914:       49 89 f6                mov    %rsi,%r14
    1917:       48 89 fb                mov    %rdi,%rbx
    191a:       e8 a1 ff ff ff          call   18c0 <_Z4stepm>
    191f:       48 85 c0                test   %rax,%rax
    1922:       74 16                   je     193a <_Z10cr_block_2mPm+0x2a>
    1924:       50                      push   %rax                          # bb 1: the stub
    1925:       e8 5a ff ff ff          call   1884 <DeduBB.cr.masters>
    192a:       48 8d 64 24 08          lea    0x8(%rsp),%rsp
    192f:       74 04                   je     1935 <_Z10cr_block_2mPm+0x25>
    1931:       49 89 46 18             mov    %rax,0x18(%r14)
    1935:       48 31 d8                xor    %rbx,%rax
    1938:       eb 02                   jmp    193c <_Z10cr_block_2mPm+0x2c>
    193a:       31 c0                   xor    %eax,%eax
    193c:       e9 3b ff ff ff          jmp    187c <DeduBB.master.0>        # bb 4: tail call

0000000000001884 <DeduBB.cr.masters>:
    1884:       48 b9 15 7c 4a 7f b9    movabs $0x9e3779b97f4a7c15,%rcx      # DeduBB.master.cr.1
    188b:       79 37 9e
    188e:       48 0f af c1             imul   %rcx,%rax
    1892:       49 89 06                mov    %rax,(%r14)
    1895:       48 89 c7                mov    %rax,%rdi
    1898:       48 89 de                mov    %rbx,%rsi
    189b:       e8 50 00 00 00          call   18f0 <_Z3mixmm>
    18a0:       48 89 c1                mov    %rax,%rcx
    18a3:       48 c1 e9 1f             shr    $0x1f,%rcx
    18a7:       48 31 c1                xor    %rax,%rcx
    18aa:       49 89 4e 08             mov    %rcx,0x8(%r14)
    18ae:       48 8d 0c 18             lea    (%rax,%rbx,1),%rcx
    18b2:       49 89 4e 10             mov    %rcx,0x10(%r14)
    18b6:       a8 01                   test   $0x1,%al
    18b8:       c3                      ret
```

`cr_block_2` shrinks from 93 to 49 bytes and `cr_block_1` from 93 to 52; the routine they share takes 53. A body without calls needs only the 5-byte `call`.

A block calls the master only if the compiler can tell that its own instructions produce the master's bytes: as many instructions as Step 1 decoded, the same callees, and no operand that the linker fills in other than a call's target. Otherwise the block keeps its body. The master is emitted from the directive's bytes rather than copied from its block, since the linker rewrites some code (for example thread-local accesses), so a block's instructions do not always match its bytes.

---

## 2. Step-by-Step Commands

Run the commands from this repository's `examples/` directory. They need the DeduBB-patched toolchains from your `tail-call` root: clang and lld built from `llvm-project` (here `llvm-project/build-lld`) and `generate_propeller_profiles` built from `llvm-propeller`.

```bash
TC=/path/to/tail-call
CLANGXX=$TC/llvm-project/build-lld/bin/clang++
GEN=$TC/llvm-propeller/build/propeller/generate_propeller_profiles
cd examples
```

### Step 1: Compile with BBAddrMap
First, compile the two files into a single binary. We compile with ThinLTO (`-flto=thin`) and pass `-Wl,--lto-basic-block-address-map` to ensure the LLD linker correctly preserves the map.

```bash
$CLANGXX -g -O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld -Wl,--lto-basic-block-address-map test1.cpp test2.cpp -o test_lto_labels
```

### Step 2: Generate Propeller Directives
Run the offline Propeller analysis on the binary. It reads the `BBAddrMap`, disassembles the candidate blocks, compares their bytes, and writes the deduplication directives.

```bash
$GEN --binary=test_lto_labels --dedubb_profile=dedubb_directives.txt
```

Other options: `--dedubb_call_return` (also write Call-Return directives; see below), `--dedubb_call_return_estimate` (only log what it would save), `--dedubb_cold_only` (only blocks with zero post-link frequency), `--dedubb_intra_module_only` (only folds within a module), and `--dedubb_skip_aliased_functions` (default `true`: leave alone functions whose address carries more than one name, i.e. aliases and functions merged by `--icf`, so the linker can still merge them). The older spellings `--tail_call_profile`, `--tail_call_dedup_cold_only` and `--tail_call_dedup_intra_module_only` still work but are deprecated.

You should see:

```
DeduBB: skipping 0 function(s) whose address carries more than one name (aliases or identical-code-folded functions)
DeduBB tail-call dedup: 7 candidate blocks, 2 master group(s), 2 fold(s), ~22 bytes saved; wrote dedubb_directives.txt
DeduBB save-and-jump: 4 blocks scanned; rejected: branch=0, call=0, r11=0, r10=0, rip-relative=0, rsp=0, system=0, no-successor=0, jump-only=0, decode-error=0
DeduBB save-and-jump, one exit: 2 eligible, 1 master group(s), 1 fold(s), ~10 bytes saved
DeduBB save-and-jump, two exits: 2 eligible, 1 master group(s), 1 fold(s), ~23 bytes saved
```

and `dedubb_directives.txt` contains one section per kind of fold:

```
m test1.cpp
f _Z10sj_block_1mmmPm
bbm 3 (DeduBB.master.1)
f _Z17identical_block_1i
bbm 0 (DeduBB.master.0)
m test2.cpp
f _Z10sj_block_2mmmPm
bbf 3 (DeduBB.master.1)
f _Z17identical_block_2i
bbf 0 (DeduBB.master.0)
m test1.cpp
f _Z10sj_block_1mmmPm
bbmsj 2 (DeduBB.master.sj.2)
m test2.cpp
f _Z10sj_block_2mmmPm
bbfsj 2 (DeduBB.master.sj.2)
m test1.cpp
f _Z10sj_block_1mmmPm
bbmsj2 1 (DeduBB.master.sj2.3)
m test2.cpp
f _Z10sj_block_2mmmPm
bbfsj2 1 (DeduBB.master.sj2.3)
```

### Step 3: Apply Deduplication
Re-compile the source files, this time passing the generated directives file to the LLVM backend.
> [!IMPORTANT]
> You must include `-fbasic-block-address-map` here as well so the blocks are assigned the `BBID`s that the `DeduBB` pass expects to match against!

```bash
$CLANGXX -g -O2 -flto=thin -fbasic-block-address-map \
    -fuse-ld=lld -Wl,--lto-basic-block-address-map \
    -Wl,-mllvm,-dedubb-directives=dedubb_directives.txt \
    test1.cpp test2.cpp -o test_deduplicated
```

> [!NOTE]
> If you link with a ThinLTO cache (`-Wl,--thinlto-cache-dir=...`), use a new cache directory whenever the directives or the linker change: the cache key covers neither, so an old cache returns the old code.

### Step 4: Verify the Fold
Disassemble the resulting binary to compare with the "After" assembly above:

```bash
objdump -d test_deduplicated | awk '/^[0-9a-f]+ <(_Z17identical_block_|_Z10sj_block_|DeduBB)/,/^$/'
```

Then check that the program still computes the same results. `main` calls both functions of each pair, on inputs that take both sides of `if (h & 1)`:

```bash
./test_lto_labels > before.txt
./test_deduplicated > after.txt
diff before.txt after.txt && echo "same output"
```

### Call-Return

The same four steps for the Call-Return example, with `--dedubb_call_return` in Step 2:

```bash
$CLANGXX -g -O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld -Wl,--lto-basic-block-address-map \
    cr_test1.cpp cr_test2.cpp -o cr_lto_labels
$GEN --binary=cr_lto_labels --dedubb_profile=cr_directives.txt --dedubb_call_return
$CLANGXX -g -O2 -flto=thin -fbasic-block-address-map -fuse-ld=lld -Wl,--lto-basic-block-address-map \
    -Wl,-mllvm,-dedubb-directives=cr_directives.txt cr_test1.cpp cr_test2.cpp -o cr_deduplicated
objdump -d cr_deduplicated | awk '/^[0-9a-f]+ <(_Z10cr_block_|DeduBB)/,/^$/'
./cr_lto_labels > cr_before.txt && ./cr_deduplicated > cr_after.txt && diff cr_before.txt cr_after.txt && echo "same output"
```

Step 2 adds a Call-Return report to its log:

```
DeduBB call-return: 9 blocks scanned, 0 red-zone function(s); rejected: branch=0, rsp=1, rip-relative=0, system=0, unresolved-call=0, returns-twice=0, tls=0, prefixed-call=0, red-zone=0, empty=0, decode-error=0
DeduBB call-return, no call in the body: 6 eligible, 0 master group(s), 0 stub(s)
DeduBB call-return, calls in the body: 2 eligible, 1 master group(s), 2 stub(s)
DeduBB call-return: ~29 bytes saved in .text; masters in 1 module(s), ~-3 bytes with one FDE each
```

and writes, next to the tail-call fold of the return block:

```
m cr_test1.cpp
f _Z10cr_block_1mPm
bbmcr 1 (DeduBB.master.cr.1) callees=_Z3mixmm insts=13 body=48b9157c4a7fb979379e480fafc14989064889c74889de.4889c148c1e91f4831c149894e08488d0c1849894e10a801
m cr_test2.cpp
f _Z10cr_block_2mPm
bbfcr 1 (DeduBB.master.cr.1) callees=_Z3mixmm insts=13
```

`callees=` lists the body's calls in order (`|` separates the names of one target, `*` stands for an indirect call) and `insts=` its instruction count; the compiler checks both against every block. `body=` holds the master's bytes, split by `.` where each direct call goes.

## 3. Results on clang

`reproduce_dedubb_clang.sh` builds clang twice, once with the BBAddrMap and once with the DeduBB directives, and compares them. By default both builds use `-Oz -ffunction-sections -fdata-sections -Wl,--gc-sections -Wl,--icf=all`, and Step 1 runs with `--dedubb_call_return`. `DEDUBB_SIZE_OPT=0` builds at `-O3`, and `DEDUBB_CALL_RETURN=0` leaves out Call-Return.

| clang-23 `.text` (bytes) | Baseline | Tail call + Save-and-Jump | + Call-Return |
|---|---|---|---|
| `-Oz`, `--gc-sections`, `--icf=all` | 37,946,290 | 37,459,018 (−1.28%) | 37,193,206 (**−1.98%**) |
| `-O3` | 84,477,871 | 82,550,399 (−2.28%) | 78,373,918 (**−7.23%**) |

`llvm-size` (text + read-only data + unwind tables): `-Oz` 69,214,012 → 67,966,180 (−1.80%); `-O3` 114,901,597 → 108,386,992 (−5.67%).

At `-Oz`, most locals are addressed from `%rsp`, which rules out Call-Return for those blocks (440K of the 1.05M blocks); they stay with Save-and-Jump.

Both Call-Return clangs were checked against their baselines: `--help` works; `-O2 -S` of `APInt.cpp`, `StringRef.cpp`, `raw_ostream.cpp`, `X86InstrInfo.cpp`, `DeduBB.cpp` and `DeduBBCallReturn.cpp` gives identical assembly; no identical-code-folding group is split; and an audit of every Call-Return master and call site finds nothing amiss. The `-O3` one also compiles 490 LLVM and clang sources (`llvm/lib/{Support,IR,Analysis}`, InstCombine, SelectionDAG, parts of clang's Sema and AST) to byte-identical objects.
