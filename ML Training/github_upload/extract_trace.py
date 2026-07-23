#!/usr/bin/env python3
"""
extract_trace.py — PipeCore16 Branch Trace Extractor
=====================================================
Parses the simulation log output from cpu_tb_trace.sv and
extracts all branch events into a clean CSV file.

Usage:
    # Redirect simulation output to a log file first:
    #   On EDA Playground: copy the log text, paste into sim_log.txt
    #   On local iverilog: ./sim > sim_log.txt

    python3 extract_trace.py sim_log.txt branch_trace.csv

Output CSV columns:
    pc          — branch instruction PC (integer)
    ghr         — 4-bit global history at fetch time (integer 0-15)
    ghr_bits    — binary string e.g. "0110"
    taken       — actual outcome: 1=taken, 0=not-taken
    predicted   — predictor's guess: 1/0 (0 if no predictor active)
    mispredict  — 1 if wrong, 0 if correct
    seq         — sequence number (branch execution order)

Also prints a summary statistics table to stdout.
"""

import sys
import csv
import os
from collections import defaultdict


def parse_log(log_text):
    """
    Parse simulation log lines.
    Only lines starting with BRANCH_TRACE, are processed.
    Everything else is ignored — safe to include full simulation output.

    Expected format:
        BRANCH_TRACE,<pc>,<ghr_bits>,<taken>,<predicted>,<mispredict>
    """
    records = []
    in_trace = False
    seq = 0

    for line in log_text.splitlines():
        line = line.strip()

        if line == "TRACE_START":
            in_trace = True
            continue
        if line == "TRACE_END":
            in_trace = False
            continue

        if line.startswith("BRANCH_TRACE,"):
            parts = line.split(",")
            if len(parts) != 6:
                print(f"  [WARN] Malformed trace line (skipping): {line}")
                continue
            try:
                _, pc, ghr_bits, taken, predicted, mispredict = parts
                records.append({
                    "seq":        seq,
                    "pc":         int(pc),
                    "ghr_bits":   ghr_bits.strip(),
                    "ghr":        int(ghr_bits.strip(), 2),
                    "taken":      int(taken),
                    "predicted":  int(predicted),
                    "mispredict": int(mispredict),
                })
                seq += 1
            except (ValueError, TypeError) as e:
                print(f"  [WARN] Could not parse line (skipping): {line} — {e}")

    return records


def write_csv(records, output_path):
    """Write records to CSV file."""
    fieldnames = ["seq", "pc", "ghr", "ghr_bits", "taken", "predicted", "mispredict"]
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(records)


def print_summary(records):
    """Print branch statistics summary to stdout."""
    if not records:
        print("  [INFO] No branch events found in log.")
        return

    total      = len(records)
    taken      = sum(r["taken"] for r in records)
    mispred    = sum(r["mispredict"] for r in records)
    predictor_active = any(r["predicted"] != 0 for r in records)

    print(f"\n{'='*58}")
    print(f"  BRANCH TRACE SUMMARY")
    print(f"{'='*58}")
    print(f"  Total branch executions  : {total}")
    print(f"  Taken                    : {taken}  ({100*taken/total:.1f}%)")
    print(f"  Not-taken                : {total-taken}  ({100*(total-taken)/total:.1f}%)")

    if predictor_active:
        print(f"  Mispredictions           : {mispred}  ({100*mispred/total:.1f}%)")
        print(f"  Correct predictions      : {total-mispred}  ({100*(total-mispred)/total:.1f}%)")
    else:
        print(f"  Predictor                : NONE (baseline run)")

    # Per-PC breakdown
    by_pc = defaultdict(list)
    for r in records:
        by_pc[r["pc"]].append(r)

    print(f"\n  Per-Branch-PC Breakdown:")
    print(f"  {'PC':>4}  {'Executions':>10}  {'Taken':>6}  {'NT':>6}  {'TakenRate':>10}")
    print(f"  {'----':>4}  {'----------':>10}  {'------':>6}  {'------':>6}  {'----------':>10}")
    for pc in sorted(by_pc.keys()):
        rows   = by_pc[pc]
        t      = sum(r["taken"] for r in rows)
        nt     = len(rows) - t
        rate   = 100 * t / len(rows)
        print(f"  {pc:>4}  {len(rows):>10}  {t:>6}  {nt:>6}  {rate:>9.1f}%")

    # GHR pattern distribution
    ghr_counts = defaultdict(int)
    for r in records:
        ghr_counts[r["ghr_bits"]] += 1

    print(f"\n  GHR Pattern Distribution (top 8):")
    sorted_ghrs = sorted(ghr_counts.items(), key=lambda x: -x[1])[:8]
    for ghr_bits, count in sorted_ghrs:
        print(f"    GHR={ghr_bits}  : {count:3d} times  ({100*count/total:.1f}%)")

    print(f"{'='*58}\n")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 extract_trace.py <sim_log.txt> [output.csv]")
        print("")
        print("  sim_log.txt  — paste your EDA Playground log here")
        print("  output.csv   — branch trace CSV (default: branch_trace.csv)")
        sys.exit(1)

    log_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else "branch_trace.csv"

    if not os.path.exists(log_path):
        print(f"[ERROR] Log file not found: {log_path}")
        sys.exit(1)

    print(f"[INFO] Reading log: {log_path}")
    with open(log_path, "r") as f:
        log_text = f.read()

    records = parse_log(log_text)
    print(f"[INFO] Found {len(records)} branch events")

    if records:
        write_csv(records, out_path)
        print(f"[INFO] Wrote: {out_path}")

    print_summary(records)


if __name__ == "__main__":
    main()
