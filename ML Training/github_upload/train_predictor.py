#!/usr/bin/env python3
"""
train_predictor.py — PipeCore16 Offline Perceptron Training
============================================================
Loads branch_trace.csv, trains a perceptron branch predictor
using batch gradient descent (multiple epochs over full trace),
and exports the learned weights as a SystemVerilog initial block
ready to paste into branch_predictor.sv.

This is the key ML contribution of the paper:
  Online hardware learning  → weights updated 1 sample at a time
  Offline batch training    → weights updated over full trace, many epochs
                           → better generalisation, fewer mispredictions

Usage:
    python3 train_predictor.py branch_trace.csv

Outputs:
    pretrained_weights.sv   — drop-in SV initial block
    training_report.txt     — accuracy, confusion matrix, per-PC stats

Parameters (match your branch_predictor.sv):
    TABLE_BITS  = 4   → 16 table entries, indexed by pc[3:0]
    HIST_LEN    = 4   → 4-bit global history register
    WEIGHT_BITS = 5   → weights clamped to [-16, +15]
    THRESHOLD   = 6   → training threshold (same as hardware)
    EPOCHS      = 50  → training passes over full dataset
"""

import sys
import csv
import os
import math
from collections import defaultdict


# ── Hyperparameters (must match branch_predictor.sv) ──────────────────────────
TABLE_BITS  = 4     # 2^4 = 16 table entries
HIST_LEN    = 4     # global history length
WEIGHT_BITS = 5     # signed weight: -2^(W-1) .. 2^(W-1)-1
THRESHOLD   = 6     # train if |y| < threshold OR mispredicted
EPOCHS      = 50    # training passes over full dataset
LR          = 1     # learning rate (perceptron uses ±1 steps)

TABLE_SIZE  = 1 << TABLE_BITS
W_MAX       =  (1 << (WEIGHT_BITS - 1)) - 1   # +15
W_MIN       = -(1 << (WEIGHT_BITS - 1))        # -16


# ── Weight helpers ─────────────────────────────────────────────────────────────
def clamp(v):
    return max(W_MIN, min(W_MAX, v))


def dot_product(weights_row, ghr_int):
    """
    Compute perceptron output y.
    weights_row: list of HIST_LEN+1 weights [bias, w1..wN]
    ghr_int    : integer 0..2^HIST_LEN-1 (GHR as integer)

    y = bias + sum_i(w[i] * x[i])
    where x[i] = +1 if GHR bit (i-1) is 1, else -1
    """
    y = weights_row[0]   # bias
    for i in range(1, HIST_LEN + 1):
        bit = (ghr_int >> (i - 1)) & 1
        x_i = +1 if bit else -1
        y  += weights_row[i] * x_i
    return y


def predict(weights_row, ghr_int):
    return 1 if dot_product(weights_row, ghr_int) > 0 else 0


def train_step(weights_row, ghr_int, actual_taken, y):
    """
    Update weights for one training sample.
    Train if mispredicted OR |y| < threshold (low confidence).
    t = +1 if taken, -1 if not-taken.
    """
    predicted = 1 if y >= 0 else 0
    if (predicted != actual_taken) or (abs(y) < THRESHOLD):
        t = +1 if actual_taken else -1
        # Bias update
        weights_row[0] = clamp(weights_row[0] + t)
        # History weight updates
        for i in range(1, HIST_LEN + 1):
            bit = (ghr_int >> (i - 1)) & 1
            x_i = +1 if bit else -1
            weights_row[i] = clamp(weights_row[i] + t * x_i)
    return weights_row


# ── Load trace ─────────────────────────────────────────────────────────────────
def load_trace(csv_path):
    records = []
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            records.append({
                "seq":    int(row["seq"]),
                "pc":     int(row["pc"]),
                "ghr":    int(row["ghr"]),
                "taken":  int(row["taken"]),
            })
    return records


# ── Training ───────────────────────────────────────────────────────────────────
def train(records):
    """
    Batch training: iterate over full trace EPOCHS times.
    Returns trained weight table.
    """
    # Initialise weights to zero (same as hardware cold start)
    weights = [[0] * (HIST_LEN + 1) for _ in range(TABLE_SIZE)]

    epoch_accuracies = []

    for epoch in range(EPOCHS):
        correct = 0
        for r in records:
            idx  = r["pc"] & (TABLE_SIZE - 1)   # pc[TABLE_BITS-1:0]
            ghr  = r["ghr"]
            actual = r["taken"]

            y    = dot_product(weights[idx], ghr)
            pred = 1 if y >= 0 else 0
            if pred == actual:
                correct += 1

            weights[idx] = train_step(weights[idx], ghr, actual, y)

        acc = 100 * correct / len(records) if records else 0
        epoch_accuracies.append(acc)

        if (epoch + 1) % 10 == 0:
            print(f"  Epoch {epoch+1:3d}/{EPOCHS}  accuracy={acc:.1f}%")

    return weights, epoch_accuracies


# ── Evaluate ───────────────────────────────────────────────────────────────────
def evaluate(weights, records):
    """Final pass: measure accuracy, build confusion matrix."""
    tp = tn = fp = fn = 0
    per_pc = defaultdict(lambda: {"correct": 0, "total": 0})

    for r in records:
        idx    = r["pc"] & (TABLE_SIZE - 1)
        pred   = predict(weights[idx], r["ghr"])
        actual = r["taken"]

        per_pc[r["pc"]]["total"] += 1
        if pred == actual:
            per_pc[r["pc"]]["correct"] += 1

        if actual == 1 and pred == 1: tp += 1
        elif actual == 0 and pred == 0: tn += 1
        elif actual == 0 and pred == 1: fp += 1
        else: fn += 1

    total   = tp + tn + fp + fn
    correct = tp + tn
    return {
        "accuracy":   100 * correct / total if total else 0,
        "mispred":    100 * (fp + fn) / total if total else 0,
        "tp": tp, "tn": tn, "fp": fp, "fn": fn,
        "per_pc": dict(per_pc),
    }


# ── Simulate online hardware learning (baseline) ───────────────────────────────
def simulate_online(records):
    """
    Replicate the hardware's online learning: one update per branch,
    single pass, no revisiting. This is the hardware baseline.
    """
    weights  = [[0] * (HIST_LEN + 1) for _ in range(TABLE_SIZE)]
    correct  = 0

    for r in records:
        idx  = r["pc"] & (TABLE_SIZE - 1)
        ghr  = r["ghr"]
        actual = r["taken"]

        y    = dot_product(weights[idx], ghr)
        pred = 1 if y >= 0 else 0
        if pred == actual:
            correct += 1

        weights[idx] = train_step(weights[idx], ghr, actual, y)

    acc = 100 * correct / len(records) if records else 0
    return acc, weights


# ── Export to SystemVerilog ────────────────────────────────────────────────────
def export_sv(weights, output_path, offline_acc, online_acc):
    """
    Write a SystemVerilog initial block that pre-loads weights.
    Paste this block into branch_predictor.sv inside the
    gen_perceptron always_ff reset block, replacing the
    inner initialisation loop.
    """
    lines = []
    lines.append("// ============================================================")
    lines.append("// PRETRAINED PERCEPTRON WEIGHTS — auto-generated")
    lines.append("// Generated by: train_predictor.py")
    lines.append(f"// Training samples : {sum(1 for _ in weights)}")
    lines.append(f"// Epochs           : {EPOCHS}")
    lines.append(f"// Offline accuracy : {offline_acc:.1f}%")
    lines.append(f"// Online accuracy  : {online_acc:.1f}%  (hardware baseline)")
    lines.append(f"// Improvement      : +{offline_acc - online_acc:.1f}%")
    lines.append(f"//")
    lines.append(f"// Parameters: TABLE_BITS={TABLE_BITS} HIST_LEN={HIST_LEN}")
    lines.append(f"//             WEIGHT_BITS={WEIGHT_BITS} THRESHOLD={THRESHOLD}")
    lines.append("//")
    lines.append("// HOW TO USE:")
    lines.append("// In branch_predictor.sv, inside gen_perceptron always_ff,")
    lines.append("// replace the weight initialisation loop with this block:")
    lines.append("//")
    lines.append("//   if (rst) begin")
    lines.append("//     ghr <= '0;")
    lines.append("//     << PASTE THE initial begin...end BLOCK BELOW HERE >>")
    lines.append("//   end")
    lines.append("// ============================================================")
    lines.append("")
    lines.append("// Paste this entire block into the rst branch of always_ff:")
    lines.append("begin : pretrained_weights")

    for idx in range(TABLE_SIZE):
        row = weights[idx]
        # Only emit non-zero rows to keep it readable
        if any(w != 0 for w in row):
            weight_str = ", ".join(f"{w:4d}" for w in row)
            lines.append(f"    // Table entry {idx:2d} (PC & 0xF == {idx})")
            for j, w in enumerate(row):
                label = "bias" if j == 0 else f"h[{j}]"
                lines.append(
                    f"    weights[{idx:2d}][{j}] = {WEIGHT_BITS}'sd{w:4d};  // {label}"
                )
        else:
            lines.append(f"    // weights[{idx:2d}][*] = 0 (all zero — no training data for this PC)")

    lines.append("end")
    lines.append("")

    # Also emit a flat lookup version for easy copy-paste verification
    lines.append("// ── Flat verification table (comment reference) ──────────────")
    lines.append("// idx | bias | h[1] | h[2] | h[3] | h[4]")
    lines.append("// ----|------|------|------|------|------")
    for idx in range(TABLE_SIZE):
        row = weights[idx]
        lines.append(f"// {idx:3d} |" + "".join(f" {w:4d} |" for w in row))

    with open(output_path, "w") as f:
        f.write("\n".join(lines) + "\n")


# ── Training report ────────────────────────────────────────────────────────────
def write_report(records, eval_result, online_acc, epoch_accs, report_path):
    lines = []
    lines.append("PIPECORE16 BRANCH PREDICTOR TRAINING REPORT")
    lines.append("=" * 58)
    lines.append(f"Training samples  : {len(records)}")
    lines.append(f"Epochs            : {EPOCHS}")
    lines.append(f"Table size        : {TABLE_SIZE} entries")
    lines.append(f"History length    : {HIST_LEN} bits")
    lines.append(f"Weight bits       : {WEIGHT_BITS} (range {W_MIN}..{W_MAX})")
    lines.append(f"Threshold         : {THRESHOLD}")
    lines.append("")
    lines.append("ACCURACY COMPARISON (key paper metric):")
    lines.append(f"  Offline (batch, {EPOCHS} epochs) : {eval_result['accuracy']:.2f}%")
    lines.append(f"  Online  (hardware, 1 pass)   : {online_acc:.2f}%")
    lines.append(f"  Improvement                  : +{eval_result['accuracy']-online_acc:.2f}%")
    lines.append(f"  Static not-taken baseline    : "
                 f"{100*(sum(1-r['taken'] for r in records)/len(records)):.2f}%")
    lines.append("")
    lines.append("CONFUSION MATRIX (offline model):")
    lines.append(f"  True  Taken     (TP): {eval_result['tp']}")
    lines.append(f"  True  Not-Taken (TN): {eval_result['tn']}")
    lines.append(f"  False Taken     (FP): {eval_result['fp']}  ← predicted taken, was NT")
    lines.append(f"  False Not-Taken (FN): {eval_result['fn']}  ← predicted NT, was taken")
    lines.append(f"  Misprediction rate  : {eval_result['mispred']:.2f}%")
    lines.append("")
    lines.append("PER-PC ACCURACY:")
    lines.append(f"  {'PC':>4}  {'Correct':>8}  {'Total':>6}  {'Accuracy':>10}")
    lines.append(f"  {'----':>4}  {'-------':>8}  {'-----':>6}  {'---------':>10}")
    for pc, stats in sorted(eval_result["per_pc"].items()):
        acc = 100 * stats["correct"] / stats["total"]
        lines.append(f"  {pc:>4}  {stats['correct']:>8}  {stats['total']:>6}  {acc:>9.1f}%")
    lines.append("")
    lines.append("LEARNING CURVE (accuracy per epoch):")
    for i, acc in enumerate(epoch_accs):
        if (i + 1) % 5 == 0:
            bar = "#" * int(acc / 5)
            lines.append(f"  Epoch {i+1:3d}: {acc:5.1f}%  {bar}")

    with open(report_path, "w") as f:
        f.write("\n".join(lines) + "\n")


# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 2:
        print("Usage: python3 train_predictor.py <branch_trace.csv>")
        print("")
        print("  Reads branch_trace.csv produced by extract_trace.py")
        print("  Outputs pretrained_weights.sv + training_report.txt")
        sys.exit(1)

    csv_path = sys.argv[1]
    if not os.path.exists(csv_path):
        print(f"[ERROR] CSV not found: {csv_path}")
        sys.exit(1)

    print(f"\n{'='*58}")
    print(f"  PipeCore16 Offline Perceptron Training")
    print(f"{'='*58}")
    print(f"  Loading trace: {csv_path}")

    records = load_trace(csv_path)
    print(f"  Loaded {len(records)} branch events")

    if len(records) == 0:
        print("[ERROR] No records found. Run extract_trace.py first.")
        sys.exit(1)

    # Simulate online hardware learning (baseline to beat)
    print(f"\n  [1/3] Simulating online hardware learning (baseline)...")
    online_acc, _ = simulate_online(records)
    print(f"        Online accuracy: {online_acc:.1f}%")

    # Offline batch training
    print(f"\n  [2/3] Offline batch training ({EPOCHS} epochs)...")
    weights, epoch_accs = train(records)

    # Final evaluation
    print(f"\n  [3/3] Evaluating trained model...")
    eval_result = evaluate(weights, records)
    print(f"        Offline accuracy : {eval_result['accuracy']:.1f}%")
    print(f"        Improvement      : +{eval_result['accuracy'] - online_acc:.1f}%")

    # Export
    sv_path     = "pretrained_weights.sv"
    report_path = "training_report.txt"

    export_sv(weights, sv_path, eval_result["accuracy"], online_acc)
    write_report(records, eval_result, online_acc, epoch_accs, report_path)

    print(f"\n{'='*58}")
    print(f"  OUTPUT FILES")
    print(f"{'='*58}")
    print(f"  {sv_path:<30} ← paste into branch_predictor.sv")
    print(f"  {report_path:<30} ← training metrics for paper")
    print(f"{'='*58}")
    print(f"\n  KEY RESULT FOR PAPER:")
    print(f"  Online learning accuracy  : {online_acc:.1f}%")
    print(f"  Offline training accuracy : {eval_result['accuracy']:.1f}%")
    print(f"  Improvement               : +{eval_result['accuracy'] - online_acc:.1f} percentage points")
    print(f"\n  This delta is your novel contribution.\n")


if __name__ == "__main__":
    main()
