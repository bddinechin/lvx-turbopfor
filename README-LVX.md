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

## Porting cost: two lines

    lib/include_/conf.h  @228, @246   add `defined(__lvx__)` to the
                                      direct-cast unaligned-access branch

LVX performs unaligned scalar loads in a single instruction (`ld`, `lwz`), so it
belongs with x86 and RISC-V rather than with the ARM packed-struct branch.

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

## Known blocker: an lvx-gcc ICE at -O2

`lib/bitpack.c` currently **ICEs the LVX back end** at `-O2` on lvx-2:

    lib/bitpack_.h: In function 'bitxpack16_16':
    error: unrecognizable insn:
    (insn ... (set (reg:TI 655)
        (ashift:TI (mem:TI (plus:DI (reg/v/f:DI 522 [ in ]) (const_int 48)))
                   (const_int 16))))
    during RTL pass: vregs
    internal compiler error: in extract_insn, at recog.cc:2894

A 128-bit shift with a *memory* operand. LVX has `sllq`, so the operation
exists; the pattern evidently wants a register and nothing forced the vector
load into one, and the insn reaches `vregs` never having been validated.

    lvx-2 -O0/-O1   ok
    lvx-2 -O2       ICE          an optimisation pass builds the bad insn
    lvx-1 -O2       ok           lvx-2 only

Handed to the `lvx-csw` session on 2026-10-19 as compiler work. Until it is
fixed, `-O1` builds and is the fallback — but note that a `-O1` number is not a
performance result worth tracking, so the harness should refuse to record one
rather than quietly report it.

It is worth saying plainly that this benchmark found a compiler bug within
minutes of first compiling, before measuring anything. That is the second kind
of value here, alongside the shape coverage: 465 KB and 547 KB of
macro-unrolled headers in `bitpack_.h` and `bitunpack_.h` exercise the compiler
itself far harder than hand-written kernels do — relevant to
`-munfold-inner-loops` and `-munfold-max-insns=`.

## Licensing

Upstream is **GPL-2.0** and this fork does not alter that. `lvx-perf` is
Apache-2.0 WITH LLVM-exception, and carrying a GPL-2.0 submodule alongside is
the same arrangement as `lvx-mds` in `lvx-csw`. One consequence worth stating:
code written *into* this repository is GPL-2.0 and **cannot flow back** to
`lvx-perf` or `lvx-ssw`. Anything meant to be shared between benchmarks has to
live on the permissive side and be copied in, never the reverse.
