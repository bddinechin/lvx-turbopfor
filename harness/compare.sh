#!/usr/bin/env bash
# Compare two TurboPFor harness runs, per row. GPL-2.0, as the repository is.
#
#   ./harness/compare.sh results/lvx-2-O2.tsv /path/to/older/lvx-2-O2.tsv
#
# Reports every metric that moved beyond THRESH (default 2%) and every change
# in the correctness column. Per row, deliberately: a row here is
# config/codec/width, and an aggregate over those would average a 0.482 against
# a 104.220 and report something true of neither.
#
# IT REFUSES TO COMPARE CYCLES ACROSS ISS CPU MODELS. gem5's default model is
# `atomic', which is FUNCTIONAL -- its cycles are not timing at all -- while
# this suite sets `minor', the pipeline model, and records it per row. Two runs
# under different models are not comparable, and the difference looks exactly
# like a uniform regression: a MiBench sweep taken under minor against a series
# taken under atomic read as +60-240% with bundle counts flat, and was
# initially diagnosed as a simulator change rather than a model switch. That
# mistake is cheap to make and cheap to prevent, so this checks rather than
# trusts.
#
# A correctness change is reported first and loudly. A row that "got faster"
# and stopped round-tripping did not get faster -- on this target a miscompile
# is exactly what that looks like.
set -u
THRESH=${THRESH:-2}
[ $# -eq 2 ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

awk -v thresh="$THRESH" -v oldf="$1" -v newf="$2" '
function pct(o, n) { return (o == 0 || o == "") ? 0 : (n - o) * 100.0 / o }
function load(f, correct, cyc, cpi, bpi, cks, txt, ins, bnd, smd, cpu, order, cnt) {
    while ((getline line < f) > 0) {
        n = split(line, t, "\t")
        if (n < 12 || t[1] == "config" || t[1] == "") continue
        k = t[1] "/" t[2] "/" t[3]
        correct[k]=t[6]; cyc[k]=t[7]; bpi[k]=t[10]; cpi[k]=t[11]; cks[k]=t[12]
        txt[k]=t[13]; ins[k]=t[14]; bnd[k]=t[15]; smd[k]=t[16]; cpu[k]=t[18]
        order[++cnt[0]] = k
    }
    close(f)
}
BEGIN {
    load(oldf, oc, ocy, ocpi, obpi, ocks, otx, oin, obn, osm, ocpu, oord, ocnt)
    load(newf, nc, ncy, ncpi, nbpi, ncks, ntx, nin, nbn, nsm, ncpu, nord, ncnt)

    # Model mismatch first: it invalidates every cycle comparison below it.
    bad = 0
    for (i = 1; i <= ncnt[0]; i++) {
        k = nord[i]
        if (!(k in oc)) continue
        if (ocpu[k] != "" && ncpu[k] != "" && ocpu[k] != ncpu[k]) {
            if (!bad++) print "ISS CPU MODEL DIFFERS -- cycles are NOT comparable:"
            printf "  %-22s %s -> %s\n", k, ocpu[k], ncpu[k]
        }
    }
    if (bad) {
        print "  A model switch looks like a uniform regression. Re-run both"
        print "  sides under the same LVX_CPU before reading any cycle figure."
        print ""
    }

    print "CORRECTNESS:"
    any = 0
    for (i = 1; i <= ncnt[0]; i++) {
        k = nord[i]
        if (!(k in oc)) { printf "  %-22s NEW (%s)\n", k, nc[k]; any=1; continue }
        if (oc[k] != nc[k]) { printf "  %-22s %s -> %s\n", k, oc[k], nc[k]; any=1 }
        else if (ocks[k] != ncks[k]) {
            printf "  %-22s checksum %s -> %s  (verdict still %s)\n", k, ocks[k], ncks[k], nc[k]; any=1
        }
    }
    for (i = 1; i <= ocnt[0]; i++) if (!(oord[i] in nc)) { printf "  %-22s GONE\n", oord[i]; any=1 }
    if (!any) print "  (no change)"

    printf "\nMETRICS (only moves beyond %s%%):\n", thresh
    moved = 0
    for (i = 1; i <= ncnt[0]; i++) {
        k = nord[i]; if (!(k in oc)) continue
        line = ""
        d = pct(ocy[k],  ncy[k]);  if (d>thresh||d<-thresh) line = line sprintf("  cycles %+.1f%%", d)
        d = pct(obpi[k], nbpi[k]); if (d>thresh||d<-thresh) line = line sprintf("  bits/int %+.1f%%", d)
        d = pct(otx[k],  ntx[k]);  if (d>thresh||d<-thresh) line = line sprintf("  text %+.1f%%", d)
        d = pct(oin[k],  nin[k]);  if (d>thresh||d<-thresh) line = line sprintf("  insns %+.1f%%", d)
        d = pct(obn[k],  nbn[k]);  if (d>thresh||d<-thresh) line = line sprintf("  bundles %+.1f%%", d)
        d = pct(osm[k],  nsm[k]);  if (d>thresh||d<-thresh) line = line sprintf("  simd %+.1f%%", d)
        if (line != "") { printf "  %-22s%s\n", k, line; moved = 1 }
    }
    if (!moved) print "  (nothing moved beyond the threshold)"

    printf "\nCYCLES PER INTEGER (the headline, lower is better):\n"
    for (i = 1; i <= ncnt[0]; i++) {
        k = nord[i]
        printf "  %-22s %9s -> %-9s %s\n", k, (k in oc) ? ocpi[k] : "-", ncpi[k], \
               (nc[k] == "ok") ? "" : "  (" nc[k] " -- NOT a performance result)"
    }

    # The scalar row is the same source through the same compiler in every
    # config, so it must agree across them. Checking it here costs nothing and
    # catches a build difference nobody intended -- which would otherwise be
    # read as a property of the machine.
    printf "\nSCALAR CONTROL (same code in every config; should agree):\n"
    for (i = 1; i <= ncnt[0]; i++) {
        k = nord[i]
        if (k ~ /\/scalar$/) printf "  %-22s %s\n", k, ncpi[k]
    }
}'
