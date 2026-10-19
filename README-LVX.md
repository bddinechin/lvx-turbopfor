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

## Why three translation layers and not four: NEON cannot be reached

TurboPFor has NEON paths, and SIMDe's NEON lowering is the layer `lvx-csw`
validates hardest — 4133 of 4134 subtests across 289 test files, against 1246
for the whole x86 corpus. A `neon` config was attempted for exactly that reason
and **cannot work**, for a structural reason rather than a configuration one.

TurboPFor ships **its own SSE-to-NEON emulation layer**:
`lib/include_/sse_neon.h`, 360 lines defining **111 `_mm_*` names** in terms of
NEON intrinsics (`vld1q_u8`, `vcombine_u32`, …), pulled in by `bitutil_.h`,
`transpose.c`, `vsimple.c` and `trled.c` whenever `__ARM_NEON` is set.

So under `__ARM_NEON` there are two emulation layers both claiming `_mm_*`:

- `sse_neon.h` defines `_mm_set_epi8` as a NEON function returning `uint32x4_t`
- SIMDe defines it as a macro expanding to `simde_mm_set_epi8`, and it arrives
  unavoidably: SIMDe's own NEON implementation internally includes its x86
  layer (`simde/arm/neon/qrshl.h` → `x86/avx.h`), which under
  `SIMDE_ENABLE_NATIVE_ALIASES` publishes the x86 aliases

They collide with `conflicting types for 'simde_mm_set_epi8'`. No combination
of `SIMDE_*_NO_NATIVE` flags fixes it, because the problem is not native versus
emulated — it is two emulators competing for the same 111 symbol names, and
SIMDe's native aliases are all-or-nothing, so its NEON names cannot be taken
while declining its x86 names.

On real ARM this is the right design: TurboPFor maps SSE to NEON itself and the
hardware does the rest. On LVX it would have to be SSE → NEON → LVX, two
stages, and SIMDe cannot be configured to supply only the second.

Two things would change that, neither of them a benchmark change: patching
`sse_neon.h` out on this branch (surgery on upstream, for a config that would
then differ from `sse` only in `bitpack.c`'s two `#ifdef __ARM_NEON` blocks),
or selective aliasing in SIMDe — NEON names without x86 names — which is an
upstream SIMDe feature.

**The gap this leaves is worth stating plainly: no benchmark in `lvx-perf`
exercises SIMDe's NEON layer at all.** `lvx-ssw` reaches LVX through SSE2 and
so does this suite, while the NEON lowering — the most heavily validated one —
has never been measured for performance. Closing that needs a benchmark written
against NEON intrinsics directly, not one ported through another project's SSE
shim.

## Results, 2026-10-19, lvx-2 `-O2`, `LVX_CPU=minor`

Cycles per integer decoded, lower better. Encode is hoisted out; only the
unpack call is timed. Every row round-trip verified.

| config | codec | width | cycles/int | bits/int |
|---|---|---|---|---|
| scalar | `bitn` | scalar | 1.668 | 26.07 |
| sse | `bitn` | scalar | 1.655 | 26.07 |
| avx2 | `bitn` | scalar | 1.659 | 26.07 |
| sse | `bitn` | **128v32** | **0.666** | 26.07 |
| avx2 | `bitn` | **256v32** | **0.482** | 26.05 |
| scalar | `bitnd` | scalar | 1.779 | 12.10 |
| sse | `bitnd` | scalar | 1.787 | 12.10 |
| avx2 | `bitnd` | scalar | 1.780 | 12.10 |
| sse | `bitnd` | **128v32** | **1.501** | 12.10 |
| avx2 | `bitnd` | **256v32** | **104.220** | 12.11 |

**The control holds.** The scalar row is the same source through the same
compiler in all three configs, and it lands at 1.668 / 1.655 / 1.659 and
1.779 / 1.787 / 1.780 — agreeing to under 1%. That validates the method
before any SIMD row is read, and it is the reason the rest can be trusted.

### Writing WIDER than the machine pays here, as long as you avoid permutes

`bitn` at 256 bits is **1.38× faster than at 128** (0.482 against 0.666) on a
machine with **no 256-bit datapath**. That is not a contradiction. A 256-bit
operation becomes a pair of 128-bit ones, the pair occupies both ALU slots, and
the surrounding code is effectively unrolled by two — so on a VLIW with slots
to fill, the emulation buys instruction-level parallelism rather than costing
it. lvx-gcc's own cost model already rates a 256-bit vector as *no gain* over a
128-bit one; this says that for straight-line integer work it can be a real
one.

### Unless the path needs a runtime-indexed permute, and then it is 69× worse

`bitnd` at 256 bits costs **104.220 cycles/int — 69× the 128-bit path and 58×
plain scalar.** The cause is the gap `lvx-ssw` already priced: the AVX2 delta
decode uses `_mm256_permutevar8x32_epi32` and `_mm256_permute2x128_si256` for
its prefix sum, and LVX has **no runtime-indexed permute at all** — only
structured UZP/ZIP shuffles. SIMDe emulates them, and here the emulation sits
on every block's critical path.

So this is a second, independent confirmation of the finding behind
`lvx-ssw`'s `inter-gather` row (14.2× for `_mm_shuffle_epi8`): two different
algorithms, two different benchmarks, one missing instruction class. Closing it
is an ISA change in `lvx-mds`; nothing in GCC or SIMDe can move it.

The practical reading for anyone choosing a width on this target: **go wide for
shift/mask/arithmetic, stay narrow for anything that permutes.** That is a
conclusion neither row gives alone, and it is why the suite measures both
codecs rather than one.

### Two smaller things the numbers record

The delta codec gains far less from SIMD than the raw one even at 128 bits
(1.19× against 2.5×), because its prefix-sum dependency after unpacking does
not vectorise. Measuring only `bitn` would have overstated SIMD's value on this
library by roughly double.

`bits_per_int` differs marginally at 256 bits (26.054 against 26.074, 12.105
against 12.099): the AVX2 path blocks the data slightly differently, so the
encodings are not byte-identical. The round trip still verifies, so this is a
legitimate encoding difference rather than a defect — worth knowing before
reading a 0.1% ratio change as noise or as a bug.

## Licensing

Upstream is **GPL-2.0** and this fork does not alter that. `lvx-perf` is
Apache-2.0 WITH LLVM-exception, and carrying a GPL-2.0 submodule alongside is
the same arrangement as `lvx-mds` in `lvx-csw`.

**Nothing crosses the boundary in either direction, and the inbound direction
is the surprising one.** Code written into this repository is GPL-2.0 and
cannot flow back out — that much is obvious. Less obvious: Apache-2.0 code
cannot come *in* either, because Apache-2.0's patent and indemnification terms
are additional restrictions under **GPLv2** specifically. (Apache-2.0 into
GPLv3 is fine; v2 is the awkward one, and TurboPFor is v2.) The LLVM Exception
may bear on it, but that is a question for counsel rather than one to decide in
a commit, so the safe course is no sharing at all.

Three files here are deliberate duplicates of `lvx-ssw` equivalents for that
reason, each carrying a comment saying so, so that nobody later tidies them
into a shared location:

| here | duplicates | why not shared |
|---|---|---|
| the I/O helpers inside `lvx/tpf-bench.c` | `lvx-ssw/lvx/lvx-io.h` | that file is Apache-2.0 |
| `lvx/tpf-shim.c` | `lvx-ssw/lvx/lvx-shim.c` | same |
| the resolver block in `lvx/run-tpf.sh` | `lvx-ssw/lvx/run-lvx.sh` | same |

The `lvx-csw` location itself is **not** duplicated: `lvx/run-tpf.sh` *invokes*
`lvx-perf`'s `bin/lvx-csw-path` as a program, which is not combining, so there
is still exactly one resolver.
