# DeduBB: Cross-Module Reproducibility Guide

A minimal test case that shows Propeller and the `DeduBB` CodeGen pass finding identical basic blocks in different modules and folding every duplicate into one shared copy, the **master**.

## How blocks are folded

| Kind | Block shape | Directives |
|---|---|---|
| **Tail call** | ends in a return or tail call | `bbm` / `bbf` |
| **Save-and-Jump** | one successor | `bbmsj` / `bbfsj` |
| **Two-exit Save-and-Jump** | ends in a conditional branch | `bbmsj2` / `bbfsj2` |

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
```

Folds never touch the stack: the master runs in the duplicate's frame and continues exactly where the duplicate would have.

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

Other options: `--dedubb_cold_only` (only blocks with zero post-link frequency), `--dedubb_intra_module_only` (only folds within a module), and `--dedubb_skip_aliased_functions` (default `true`: leave alone functions whose address carries more than one name, i.e. aliases and functions merged by `--icf`, so the linker can still merge them). The older spellings `--tail_call_profile`, `--tail_call_dedup_cold_only` and `--tail_call_dedup_intra_module_only` still work but are deprecated.

You should see:

```
DeduBB: skipping 0 function(s) whose address carries more than one name (aliases or identical-code-folded functions)
DeduBB tail-call dedup: 7 candidate blocks, 2 master group(s), 2 fold(s), ~22 bytes saved; wrote dedubb_directives.txt
DeduBB save-and-jump: 4 blocks scanned; rejected: branch=0, call=0, r10/r11=0, rip-relative=0, rsp=0, system=0, no-successor=0, jump-only=0, decode-error=0
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
