#!/usr/bin/env bash
# TurboPFor integer bit-packing on LVX. This repository is GPL-2.0; so is this
# script.
#
#   ./lvx/run-tpf.sh                 scalar config, lvx-2, -O2, under gem5
#   CONFIG=sse ./lvx/run-tpf.sh      the library's 128-bit SSE path via SIMDe
#   CONFIG=avx2 ./lvx/run-tpf.sh     its 256-bit AVX2 path via SIMDe
#   MARCH=lvx-1 ./lvx/run-tpf.sh     the scalar core
#   STATIC_ONLY=1 ./lvx/run-tpf.sh   build + static metrics, no ISS
#   ./lvx/run-tpf.sh --native        the x86 reference, same source
#   ./lvx/run-tpf.sh --csw /path/to/lvx-csw
#
# CONFIG selects which translation layer is measured. One source tree, three
# layers -- that is the point of the benchmark:
#
#   scalar  plain C, no SIMDe at all. GCC's auto-vectorizer decides, and it
#           does a great deal (2145 SIMD instructions in bitunpack.o).
#   sse     the library's hand-written SSE path through SIMDe's 128-bit
#           lowering onto native LVX vectors.
#   avx2    its AVX2 path through SIMDe's 256-bit lowering onto a 128-bit
#           machine. LVX-2 has NO 256-bit datapath, so this measures the
#           emulation layer, not a wide one.
#
# The macro names differ PER FILE and that is a trap worth stating: bitpack.c
# guards on __SSE3__ while bitunpack.c guards on __SSE2__ and __SSSE3__. Define
# only one and the build silently takes the scalar path while the row claims to
# be SIMD -- which is exactly what happened on the first attempt here, with a
# byte-identical object as the only clue. So `sse' defines all three.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=${CONFIG:-scalar}
MARCH=${MARCH:-lvx-2}
OPT=${OPT:-O2}

CSW_ARG=
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   CSW_ARG=${2:?--csw needs a path}; shift 2 ;;
        --csw=*) CSW_ARG=${1#--csw=}; shift ;;
        *)       args+=("$1"); shift ;;
    esac
done
set -- ${args[@]+"${args[@]}"}

# lvx-csw holds the toolchain, the ISS and SIMDe; its location is a parameter.
# Resolution is DELEGATED to the superproject's bin/lvx-csw-path rather than
# reimplemented, and deliberately by INVOCATION rather than by copying: that
# script is Apache-2.0 WITH LLVM-exception, this repository is GPL-2.0, and
# Apache-2.0's patent and indemnification terms are additional restrictions
# under GPLv2 -- so its code cannot be combined in here, while running it as a
# program is not combining at all. One resolver, no license mixing.
resolve_csw() {
    [ -n "$CSW_ARG" ] && { printf '%s\n' "$CSW_ARG"; return 0; }
    [ -n "${LVX_CSW:-}" ] && { printf '%s\n' "$LVX_CSW"; return 0; }
    local super
    super=$(git -C "$HERE" rev-parse --show-superproject-working-tree 2>/dev/null) || super=
    if [ -n "$super" ] && [ -x "$super/bin/lvx-csw-path" ]; then
        "$super/bin/lvx-csw-path" 2>/dev/null && return 0
    fi
    local c
    for c in ${super:+"$super/../lvx-csw"} "$HERE/../lvx-csw" "$HOME/lvx-csw"; do
        [ -d "$c/lvx-mds" ] || [ -d "$c/validation" ] || continue
        (cd "$c" && pwd); return 0
    done
    return 1
}
CSW=$(resolve_csw) || {
    echo "error: cannot find lvx-csw. It holds the toolchain, the ISS and" >&2
    echo "       SIMDe, none of which are in this repository." >&2
    echo "       Pass --csw <path>, set \$LVX_CSW, or put the checkouts as" >&2
    echo "       siblings. lvx-perf's bin/lvx-csw-path owns the full chain." >&2
    exit 2
}
[ -d "$CSW" ] || { echo "error: lvx-csw path does not exist: $CSW" >&2; exit 2; }

case $CONFIG in
    scalar) CFG_CF="" ;;
    # All three, because the guard macro differs per file -- see the note above.
    sse)    CFG_CF="-D__SSE2__ -D__SSSE3__ -D__SSE3__" ;;
    avx2)   CFG_CF="-D__AVX2__" ;;
    *) echo "error: unknown CONFIG='$CONFIG' (scalar, sse or avx2)" >&2; exit 2 ;;
esac

# bitutil.c IS needed: the encoders call bit32/bitd32 from it to compute each
# block's bit width. (An earlier version of this script dropped it on the
# strength of bitunpack.o having no undefined bit* symbols -- true, but that is
# the DECODER; the check should have been run against bitpack.o too.)
#
# It is also the only file pulling round() and roundf(), for FP "razor" helpers
# this benchmark never calls. Linking libm for them would force a hosted link,
# which collides with the freestanding crt.S -- newlib's crt0.o and crt.S both
# define _start -- so tpf-shim.c supplies those two as loud traps instead and
# the link stays freestanding, like lvx-ssw's.
SRCS="$HERE/lvx/tpf-bench.c $HERE/lvx/tpf-shim.c $HERE/lib/bitunpack.c $HERE/lib/bitpack.c $HERE/lib/bitutil.c $HERE/lib/vint.c"

if [ "${1:-}" = "--native" ]; then
    # CONFIG=scalar has no native equivalent and cannot have one: x86-64
    # predefines __SSE2__ as part of its baseline, so the library takes its SSE
    # path on the host whatever we pass. Worse, __SSE2__ WITHOUT __SSSE3__ does
    # not compile upstream -- bitunpack.c references _shuffle_16 outside the
    # #if defined(__SSSE3__) block that defines it -- so the half-way
    # combination is broken as well as unreachable. The scalar row therefore
    # exists only on LVX, which predefines no x86 feature macros at all. Say
    # this rather than emit a confusing error from inside a 547 KB header.
    if [ "$CONFIG" = scalar ]; then
        echo "CONFIG=scalar has no native build: x86-64 predefines __SSE2__," >&2
        echo "so the host always takes the library's SSE path. Use" >&2
        echo "CONFIG=sse or CONFIG=avx2 for the native reference; the scalar" >&2
        echo "row is an LVX-only configuration." >&2
        exit 2
    fi
    nflags=""
    [ "$CONFIG" = sse  ] && nflags="-msse2 -mssse3"
    [ "$CONFIG" = avx2 ] && nflags="-mavx2"
    # shellcheck disable=SC2086
    # The shim is for the freestanding target link only -- natively it would
    # collide with the host's libc.
    nsrc=$(printf '%s\n' $SRCS | grep -v tpf-shim | tr '\n' ' ')
    # shellcheck disable=SC2086
    cc -$OPT $nflags $CFG_CF -I"$HERE" -w -o /tmp/tpf-native-$CONFIG $nsrc || exit 1
    exec /tmp/tpf-native-$CONFIG
fi

BIN=$CSW/lvx-toolchain/bin
SIMDE=$CSW/lvx-simde
[ -x "$BIN/lvx-mbr-gcc" ] || {
    echo "error: $CSW has no built cross-toolchain (lvx-toolchain/bin/lvx-mbr-gcc)" >&2
    echo "       build it:  make -C '$CSW' install-minimal-toolchain" >&2; exit 2; }
[ -r "$SIMDE/simde/x86/avx2.h" ] || {
    echo "error: no SIMDe headers at $SIMDE -- the sse and avx2 configs reach" >&2
    echo "       the library's intrinsics through them" >&2
    echo "       fix:  git -C '$CSW' submodule update --init lvx-simde" >&2; exit 2; }

case $MARCH in
    lvx-1) GEM5BIN=gem5-lvx-1.opt ;;
    lvx-2) GEM5BIN=gem5-lvx-2.opt ;;
    # Wrong-core runs are SILENT: lvx-2 code under gem5-lvx-1.opt does not
    # error, it returns wrong answers.
    *) echo "error: unknown MARCH='$MARCH' (lvx-1 or lvx-2)" >&2; exit 2 ;;
esac
[ "${STATIC_ONLY:-0}" = 1 ] || [ -x "$CSW/lvx-gem5/build/$GEM5BIN" ] || {
    echo "error: missing ISS for $MARCH: $CSW/lvx-gem5/build/$GEM5BIN" >&2; exit 2; }

WD=$(mktemp -d); trap 'rm -rf "$WD"' EXIT

# lvx/x86shim must come FIRST: it stands in for <immintrin.h> and the other x86
# headers, which do not exist for lvx-mbr, forwarding to SIMDe.
CF="-$OPT -march=$MARCH $CFG_CF -I$HERE/lvx/x86shim -I$HERE -I$SIMDE"
CF="$CF -DSIMDE_ENABLE_NATIVE_ALIASES -ffreestanding -fno-strict-aliasing -w"
# -ffunction-sections with --gc-sections at link time, so the linker DROPS the
# functions this benchmark never calls -- and with them their libc references.
# bitutil.c's FP "razor" helpers are the case that forced this: _fprazor32
# reaches conf.h's AS() assert macro, which wants _impure_ptr, fflush and
# fprintf, and bitutil.c itself wants round and roundf. Stubbing that list was
# the alternative, and it was growing with each link attempt. Garbage
# collection removes the cause rather than the symptoms, and shrinks the image
# besides.
CF="$CF -ffunction-sections -fdata-sections"

echo "== $CONFIG $MARCH -$OPT =="
t0=$SECONDS
objs=""
for src in $SRCS; do
    o=$WD/$(basename "$src" .c).o
    "$BIN/lvx-mbr-gcc" $CF -c "$src" -o "$o" || { echo "COMPILE FAIL: $src"; exit 1; }
    objs="$objs $o"
done

# The AVX2 configuration needs each codec file compiled TWICE and both objects
# linked. That is upstream's own scheme, not a workaround: its makefile builds
# bitunpack.o and bitunpack_avx2.o (lines 117-121) and links both (128, 130).
#
# The reason is the guard nesting. bitunpack.c opens `#ifndef __AVX2__' around
# the plain block, and the AVX2/SSE2 selection is nested INSIDE it. So defining
# __AVX2__ removes the plain block entirely -- while the AVX2 routines call
# into it: bitnunpack256v32 calls bitunpack32 for tail blocks, bitnpack256v32
# calls bit32 for the block width. Compiling only with __AVX2__ therefore
# leaves those undefined, which is exactly how this first failed here.
#
# The two compilations are disjoint by construction (#ifndef vs #ifdef), so
# linking both yields the union with no duplicate symbols.
if [ "$CONFIG" = avx2 ]; then
    for src in "$HERE/lib/bitunpack.c" "$HERE/lib/bitpack.c" "$HERE/lib/bitutil.c"; do
        o=$WD/$(basename "$src" .c)-plain.o
        # Same flags MINUS $CFG_CF: this is the plain build that supplies the
        # scalar helpers the AVX2 routines call.
        "$BIN/lvx-mbr-gcc" -$OPT -march="$MARCH" -I"$HERE/lvx/x86shim" -I"$HERE" -I"$SIMDE" \
            -DSIMDE_ENABLE_NATIVE_ALIASES -ffreestanding -fno-strict-aliasing -w \
            -ffunction-sections -fdata-sections -c "$src" -o "$o" \
            || { echo "COMPILE FAIL (plain half): $src"; exit 1; }
        objs="$objs $o"
    done
fi
# Compile time is a METRIC here, not a nuisance: SIMDe's 256-bit emulation took
# 24 minutes for bitunpack.c alone against 46 seconds for the scalar path, and
# that ratio is the clearest single signal of what the layer is doing.
echo "compile_seconds $((SECONDS - t0))"

"$BIN/lvx-mbr-as" -march="$MARCH" "$CSW/validation/lib/crt.S" -o "$WD/crt.o" || exit 1
# Freestanding, as lvx-ssw links: crt.S provides _start, write and exit, and
# every buffer here is static so no allocator is needed at all.
"$BIN/lvx-mbr-gcc" -march="$MARCH" -nostartfiles -nostdlib \
    -Wl,-e,_start -Wl,-Ttext=0x10000 -Wl,--gc-sections \
    "$WD/crt.o" $objs -lgcc -o "$WD/tpf.elf" \
    || { echo "LINK FAIL"; exit 1; }

"$BIN/lvx-mbr-objdump" -d "$WD/tpf.elf" > "$WD/dis.txt" 2>/dev/null
echo "text_bytes $("$BIN/lvx-mbr-size" -A "$WD/tpf.elf" | awk '$1==".text"{print $2}')"
echo "insns_static $(grep -cE '^[[:space:]]+[0-9a-f]+:' "$WD/dis.txt")"
echo "bundles_static $(grep -c ';;' "$WD/dis.txt")"
echo "simd_insns $(grep -coE '\b[a-z]+(dp|wq|ho|bx)\b' "$WD/dis.txt" || true)"

[ "${STATIC_ONLY:-0}" = 1 ] && exit 0

# gem5's default model is `atomic', which is FUNCTIONAL -- its cycles are not
# timing at all. Set `minor' explicitly and REPORT it, because leaving this to
# a default is how lvx-polybench and lvx-mibench both ended up with
# functional-model series nobody realised were functional, and a model switch
# then read as a 60-240% regression.
LVX_CPU=${LVX_CPU:-minor}
echo "cpu_model $LVX_CPU"
LVX_CPU=$LVX_CPU timeout "${TMO:-3600}" \
    "$CSW/lvx-gem5/build/$GEM5BIN" --outdir="$WD/m5out" \
    "$CSW/lvx-gem5/tests/lvx/run_lvx.py" "$WD/tpf.elf" 2>&1 |
    grep -E '^RESULT|^src_checksum|^ok|^FAIL|^MISMATCH|target exited'
