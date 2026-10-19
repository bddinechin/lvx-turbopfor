# lvx-turbopfor — integer compression as an LVX-2 SIMD benchmark

Upstream: https://github.com/powturbo/TurboPFor-Integer-Compression
(forked at `1f646d9`, 2026-10-08). This branch, `lvx-turbopfor`, carries the
LVX port; `master` tracks upstream unchanged.

**Why this one.** It is a *third* benchmark shape for `lvx-perf`, and the shape
is the point. `lvx-ssw` already covers a branch-dominated kernel (striped
Smith-Waterman, where a data-dependent early exit is 43% of the run) and a
branch-free throughput kernel (inter-sequence, saturating arithmetic). PolyBench
covers dense FP loop nests. **Nothing covered bit manipulation** — shift, mask,
delta, zigzag, OR-accumulate over packed integers — which is its own instruction
mix and its own scheduling problem.

That matters because of what PolyBench demonstrated on 2026-10-16: a breadth
gate can be entirely blind to a change. Every one of its 240 kernel-measurements
was codegen-identical across a vector-comparison change set, because its kernels
never reach the code that change touched. Coverage of *shapes* beats more
kernels of one shape.

**It is also honest about what it does not test.** LVX-2 has no 256-bit
datapath. 256-bit vectors are legal and lower cleanly to *pairs* of 128-bit
operations — `addwq addwq`, two instructions for twice the data, no overhead and
no gain. So the `__AVX2__` paths here do not measure a wide datapath; they
measure the back end's **pairing**: `OI`-mode register allocation, and whether
the scheduler issues the two halves well. Upstream ships 128-bit *and* 256-bit
implementations of the same codec, macro-selected, which makes that a
one-variable A/B rather than a guess.

## Porting cost: three edits, none of them LVX-specific in nature

    lib/include_/conf.h  @228, @246   add `defined(__lvx__)` to the
                                      direct-cast unaligned-access branch
    lib/include_/conf.h               #include <stdlib.h>
    lib/bitutil.c                     12 pointer casts in four dispatchers

LVX performs unaligned scalar loads in a single instruction (`ld`, `lwz`), so it
belongs with x86 and RISC-V rather than with the ARM packed-struct branch. That
is the only edit that is about this target.

The other two are **modern-compiler strictness, not LVX**, and upstream will
hit both on any GCC 14 or newer:

- `conf.h`'s `AS()` assert macro calls `exit()` and `fprintf()` while including
  neither `<stdlib.h>` nor `<stdio.h>` on that path. Under `-ffreestanding` the
  implicit declaration is an error rather than a warning.
- `bitxenc`/`bitxdec`/`bitzenc`/`bitzdec` are generic dispatchers taking
  `unsigned char *` and calling the typed `*16`/`*32`/`*64` entry points with
  it. `-Wincompatible-pointer-types` became an **error** by default in GCC 14,
  and lvx-gcc is GCC 17. The casts preserve upstream's evident intent (these are
  deliberate reinterpretations, and the library relies on unaligned access
  throughout) without changing behaviour on any target.

Upstream's `UA_MEMCPY` escape hatch — which would have meant *zero* source
changes — **is broken upstream**, also independently of LVX: it defines `stou*`
as `memcpy` calls while `lib/include_/vlcbyte.h` uses them as assignment
targets, so it fails with "lvalue required as left operand of assignment".
Worth knowing before reaching for it.

Upstream's `UA_MEMCPY` escape hatch — which would have meant *zero* source
changes — **is broken upstream**, independently of LVX: it defines `stou*` as
`memcpy` calls while `lib/include_/vlcbyte.h` uses them as assignment targets,
so it fails with "lvalue required as left operand of assignment". Worth knowing
before reaching for it.

## What is scoped out, and why

**`lib/transpose.c` is excluded from the benchmark.** It is built almost
entirely on the one operation class LVX lacks: `_mm256_shuffle_epi8`,
`_mm256_permutevar8x32_epi32`, `_mm256_permute4x64_epi64`,
`_mm256_permute2x128_si256` — runtime-indexed byte and lane gathers. LVX has
only *structured* permutes (`vector.md`'s UZP/ZIP family,
`lvx_expand_vec_perm_shuffle`), so `_mm_shuffle_epi8` costs 22 instructions
here and running `transpose.c` would measure emulation rather than the machine.
`lvx-ssw`'s `inter-gather` row already prices that gap properly, at 14.2x in a
real kernel.

The bitpacking codecs are the opposite: roughly 75% shift / mask / add / or /
sub plus delta and zigzag, with permutes only of the `_mm_shuffle_epi32` kind —
immediate-indexed lane shuffles, which LVX *does* have. Those lower natively.

**The four nested submodules are removed on this branch** (`lib/ext/lz4`,
`zstd`, `bitshuffle`, `Turbo-Range-Coder`). They are referenced only by
`lib/iccodec.c` and `lib/icapp.c` — the comparison-codec and application layer,
which needs a filesystem and is not part of this benchmark. Keeping them would
make every `lvx-perf` clone pull `zstd` and `lz4` for nothing, since the README
there documents `git clone --recurse-submodules`. `master` retains upstream's
`.gitmodules` unchanged, so nothing is lost. (Upstream's version also lists
`Turbo-Range-Coder` twice under one path.)

## What builds today: all of it

Measured on lvx-2, lvx-gcc `ddb027f279a`:

| file | role | `-O2` |
|---|---|---|
| `lib/bitpack.c` | encode | **ok** (also `-O3`, `-Os`) |
| `lib/bitunpack.c` | decode — the hot path | **ok** |
| `lib/bitutil.c` | delta/zigzag helpers | **ok** |
| `lib/vint.c` | variable-byte integers | **ok** |
| `lib/vsimple.c` | SIMPLE-family codecs | ok |
| `lib/transpose.c` | byte transpose | builds, but scoped out above (permute-bound) |

## The lvx-gcc ICE this port found, and what it left behind

First compiling `lib/bitpack.c` ICEd the back end before anything had been
measured:

    lib/bitpack_.h: In function 'bitxpack16_16'
    error: unrecognizable insn:  (set (reg:TI 655)
        (ashift:TI (mem:TI (plus:DI (reg/v/f:DI 522 [ in ]) (const_int 48)))
                   (const_int 16)))
    during RTL pass: vregs — internal compiler error: in extract_insn, at recog.cc:2894

**Fixed in lvx-gcc `ddb027f279a`.** The cause, from the session that fixed it:
`lvx_expand_vector_shift` routes a 128-bit vector shift by a non-word count
through the TImode view — one `SLLQ`/`SRLQ` instead of four word-at-a-time
instructions — by taking `simplify_gen_subreg (TImode, …)` of source and target
and calling `gen_ashlti3`/`gen_lshrti3` directly. A `simplify_gen_subreg` of a
MEM gives back a MEM, and `gen_*` checks no predicate, so the `mem:TI` reached
`recog` unmatched. The rotate pair a few thousand lines down had the same bug,
unhit. Sources are now forced into registers.

**Two things worth keeping from how it was found.**

It needed this input and could not be minimised. Three reductions of mine and
four of theirs all compiled clean, because the trigger is *operand provenance* —
the shift's source has to arrive as memory, which happens when the vectorizer
feeds a memory operand straight into `vec_shr`/`vec_shl`, and the vectorizer is
the only producer. 1 MB of macro-unrolled headers is what reaches that path. A
small reproducer would most likely have missed the bug.

And the fix was scoped, not exhaustive: **140 other direct `emit_insn (gen_…)`
calls in `lvx.cc` were not audited**, of which five take `simplify_gen_subreg`
results into patterns wanting `register_operand` —
`gen_lvx_makedp`, `gen_insvsi`, `gen_lvx_sbmm8dp`, `gen_lvx_catdq`,
`gen_anddi3`. They are reached only from constant-materialisation paths where
the operand is a register by construction *today*, which is why they have not
fired — not a guarantee. **If this benchmark ever produces another
"unrecognizable insn" naming RTL pass `vregs`, those five are the first place to
look, and the same fix applies.**

## On the 256-bit question, settled from both sides

The back end independently agrees with the measurement: lvx-gcc *costs* a
256-bit vector as no gain over a 128-bit one, because a two-half operation is
`issue lite2` and occupies both ALU slots. So there is nothing to fix and
nothing to tune — the pairing is as good as a 128-bit machine can do, and the
`__AVX2__` paths here measure that it stays that way.

`transpose.c`'s permute dependence is likewise not a compiler matter: there is
no runtime-indexed byte permute in the ISA to emit, so it is an `lvx-mds`
question alongside `lvx-ssw`'s 14.2× `inter-gather` row.

## Licensing

Upstream is **GPL-2.0** and this fork does not alter that. `lvx-perf` is
Apache-2.0 WITH LLVM-exception, and carrying a GPL-2.0 submodule alongside is
the same arrangement as `lvx-mds` in `lvx-csw`. One consequence worth stating:
code written *into* this repository is GPL-2.0 and **cannot flow back** to
`lvx-perf` or `lvx-ssw`. Anything meant to be shared between benchmarks has to
live on the permissive side and be copied in, never the reverse.
