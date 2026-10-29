#!/usr/bin/env bash
# TurboPFor on LVX: integer bit-packing performance tracking, correctness-gated.
# This repository is GPL-2.0; so is this script.
#
#   ./harness/run.sh                      # all three configs, lvx-2, -O2
#   CONFIG=sse ./harness/run.sh           # just one
#   ARCH=lvx-1 ./harness/run.sh
#   STATIC_ONLY=1 ./harness/run.sh        # build + static metrics, no ISS
#   ./harness/run.sh --csw /path/to/lvx-csw
#   ./harness/compare.sh results/A.tsv results/B.tsv
#
# Writes results/<arch>-<opt>.tsv and a human summary. Commit the results: the
# series is the point, and lvx-perf's bin/lvx-perf-import snapshots them with
# the toolchain revisions that produced them.
#
# TWO DIMENSIONS, which is what makes this suite worth its runtime.
#
# CONFIG is the build -- which translation layer the library's source went
# through: scalar (plain C, GCC's auto-vectorizer, no SIMDe), sse (its SSE path
# via SIMDe's 128-bit lowering), avx2 (its AVX2 path via SIMDe's 256-bit
# lowering onto a machine with no 256-bit datapath).
#
# WIDTH is the entry point called -- and a SIMD build exports the scalar one
# alongside its vector ones, so one binary measures several widths on one
# dataset in one run. Nothing differs between those rows but the function
# called: no separate build, data, or ISS invocation to drift. That is the same
# held-constant design that made lvx-ssw's inter vs inter-gather mean
# something.
#
# So the scalar row appears in all three configs, and comparing it ACROSS them
# is the control: it should be identical, because it is the same code. If it is
# not, the build differs in some way nobody intended.
#
# CORRECTNESS IS A ROUND TRIP and needs no committed reference. unpack(pack(x))
# must reproduce x element for element, checked twice per width -- before
# timing and on the timed pass. The driver prints no cycle count if it fails.
# A row whose `correct' column is not `ok' is not a performance result: on this
# target a miscompile reads as a speed-up.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

ARCH=${ARCH:-lvx-2}
OPT=${OPT:-O2}
STATIC_ONLY=${STATIC_ONLY:-0}
CONFIGS=${CONFIG:-"scalar sse avx2"}

csw_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   csw_args+=(--csw "${2:?--csw needs a path}"); shift 2 ;;
        --csw=*) csw_args+=("$1"); shift ;;
        *)       echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in lvx-1|lvx-2) ;; *) echo "ARCH must be lvx-1 or lvx-2" >&2; exit 2 ;; esac

outdir="$repo/results"; mkdir -p "$outdir"
tsv="$outdir/$ARCH-$OPT.tsv"
work=$(mktemp -d); trap 'rm -rf "$work"' 0 1 2 3 15

# lvx-perf's bin/lvx-rev-stamp owns the provenance columns, and is CALLED and
# never copied. That matters more here than anywhere: this suite is GPL-2.0 and
# lvx-perf is Apache-2.0 WITH LLVM-exception, which does not combine into
# GPLv2 -- copying a helper in was the mistake lvx/lvx-io.h made once.
# Executing a script is not deriving from it.
#
# Per row, not per sweep: a toolchain reinstalled in place midway is the
# hazard, and a once-per-sweep stamp cannot show it.
super=$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null) || super=
STAMP=
[ -n "$super" ] && [ -x "$super/bin/lvx-rev-stamp" ] && STAMP="$super/bin/lvx-rev-stamp"
stamp_cols=(csw_rev gcc_rev gem5_rev cc_mtime)
stamp_header() {
    if [ -n "$STAMP" ]; then "$STAMP" --tsv-header
    else (IFS=$'\t'; printf '%s\n' "${stamp_cols[*]}"); fi
}
stamp_row() {
    if [ -n "$STAMP" ]; then "$STAMP" --tsv-row ${CSW:+--csw "$CSW"}
    else
        local u=() c
        for c in "${stamp_cols[@]}"; do u+=(unknown); done
        (IFS=$'\t'; printf '%s\n' "${u[*]}")
    fi
}

HEADER='config\tcodec\twidth\tarch\topt\tcorrect\tcycles\tints\tpacked_bytes\tbits_per_int\tcycles_per_int\tchecksum\ttext_bytes\tinsns_static\tbundles_static\tsimd_insns\tcompile_seconds\tcpu_model'
HEADER="$HEADER\t$(stamp_header | sed 's/\t/\\t/g')"
# The field count the merge below pads carried-over rows up to.
want_fields=$(printf "$HEADER\n" | awk -F'\t' '{print NF}')

rows="$work/rows.tsv"; : > "$rows"
printf '%-8s %-6s %-8s %-10s %12s %10s %12s %8s\n' \
       CONFIG CODEC WIDTH CORRECT CYCLES CYC/INT BITS/INT COMPILE

field() { sed -n "s/^$2 \(.*\)$/\1/p" "$1" | tail -1; }

rc=0
for cfg in $CONFIGS; do
    case "$cfg" in scalar|sse|avx2) ;; *) echo "unknown CONFIG '$cfg'" >&2; exit 2 ;; esac
    log="$work/$cfg.log"
    if CONFIG="$cfg" MARCH="$ARCH" OPT="$OPT" STATIC_ONLY="$STATIC_ONLY" \
       "$repo/lvx/run-tpf.sh" "${csw_args[@]+"${csw_args[@]}"}" > "$log" 2>&1
    then run_ok=1; else run_ok=0; fi

    text=$(field "$log" text_bytes);    insns=$(field "$log" insns_static)
    bund=$(field "$log" bundles_static); simd=$(field "$log" simd_insns)
    csec=$(field "$log" compile_seconds); cpu=$(field "$log" cpu_model)

    # Build-level failures produce no RESULT lines at all, so report them as a
    # single row rather than silently emitting nothing for the config.
    if grep -qE '^(COMPILE FAIL|LINK FAIL)' "$log"; then
        printf '%-8s %-6s %-8s %-10s\n' "$cfg" "-" "-" "BUILD_FAIL"
        sed -n '1,8p' "$log" | sed 's/^/  | /'
        rc=1; continue
    fi
    if [ "$STATIC_ONLY" = 1 ]; then
        printf '%-8s %-6s %-8s %-10s %12s %10s %12s %8s\n' "$cfg" "-" "-" static - - - "${csec:--}"
        printf '%s\t-\t-\t%s\t%s\tstatic\t\t\t\t\t\t\t%s\t%s\t%s\t%s\t%s\t\t%s\n' \
               "$cfg" "$ARCH" "$OPT" "${text:-}" "${insns:-}" "${bund:-}" "${simd:-}" "${csec:-}" \
               "$(stamp_row)" >> "$rows"
        continue
    fi

    nres=$(grep -c '^RESULT' "$log" || true)
    if [ "$run_ok" != 1 ] || [ "${nres:-0}" -eq 0 ]; then
        why=RUN_FAIL
        grep -q '^MISMATCH' "$log" && why=MISMATCH
        grep -q '^FAIL'     "$log" && why=SELFCHECK
        printf '%-8s %-6s %-8s %-10s\n' "$cfg" "-" "-" "$why"
        sed -n '1,10p' "$log" | sed 's/^/  | /'
        rc=1; continue
    fi

    # One TSV row per RESULT line. The driver's tag is codec/width.
    while IFS= read -r line; do
        tag=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
        codec=${tag%%/*}; width=${tag##*/}
        get() { printf '%s' "$line" | sed -n "s/.*\\t$1 \\([^\\t]*\\).*/\\1/p"; }
        cyc=$(get cycles); ints=$(get ints); pb=$(get packed_bytes)
        bpi=$(get bits_per_int); cpi=$(get cycles_per_int); cks=$(get checksum)
        # The driver refuses to print a RESULT for a width whose round trip
        # failed, so a RESULT line present means that width verified.
        correct=ok
        printf '%-8s %-6s %-8s %-10s %12s %10s %12s %8s\n' \
               "$cfg" "$codec" "$width" "$correct" "$cyc" "$cpi" "$bpi" "${csec:--}"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
               "$cfg" "$codec" "$width" "$ARCH" "$OPT" "$correct" "$cyc" "$ints" \
               "$pb" "$bpi" "$cpi" "$cks" "${text:-}" "${insns:-}" "${bund:-}" \
               "${simd:-}" "${csec:-}" "${cpu:-}" "$(stamp_row)" >> "$rows"
    done < <(grep '^RESULT' "$log")
done

# Merge: replace the configs this run produced, keep the rest. Writing $tsv
# directly would make a CONFIG=sse re-run truncate the other configs' rows --
# the mistake that cost lvx-mibench a 13-row baseline on 2026-10-09.
merged="$work/merged.tsv"
printf "$HEADER\n" > "$merged"
if [ -f "$tsv" ]; then
    awk -F'\t' -v OFS='\t' -v keep="$(echo $CONFIGS | tr ' ' '|')" \
        -v want="$want_fields" '
        NR==1 && $1=="config" {next}
        { n=split(keep,k,"|"); for(i=1;i<=n;i++) if ($1==k[i]) next
          # Pad a row written before the provenance columns existed, so a
          # single-config re-run cannot leave the file ragged.
          for (i = NF + 1; i <= want; i++) $i = ""
          print }
    ' "$tsv" >> "$merged"
fi
cat "$rows" >> "$merged"
{ head -1 "$merged"; tail -n +2 "$merged" \
    | awk -F'\t' '{o=($1=="scalar")?0:($1=="sse")?1:2; print o"\t"$0}' \
    | sort -k1,1n -k2,2 | cut -f2-; } > "$tsv"

echo
echo "wrote $tsv"
[ "$rc" = 0 ] || echo "NOT ALL ROWS ARE PERFORMANCE RESULTS -- see the correct column" >&2
exit $rc
