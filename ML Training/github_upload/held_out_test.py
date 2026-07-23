#!/usr/bin/env python3
"""
Held-out test: Train on BM1 + BM2 + BM3, evaluate on BM4 (unseen).
This addresses Reviewer Comment 3.
"""
import sys, csv
sys.path.insert(0, '/home/claude')
from train_predictor import simulate_online, train, evaluate, load_trace

WORK = "/home/claude/step5"

# ── Collect per-benchmark traces from simulation logs ──────────────
def extract_trace_from_log(log_path):
    records = []; seq = 0
    try:
        with open(log_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("BRANCH_TRACE,"):
                    parts = line.split(",")
                    if len(parts) == 6:
                        _, pc, ghr_bits, taken, predicted, mispredict = parts
                        records.append({
                            "seq": seq, "pc": int(pc),
                            "ghr": int(ghr_bits.strip(), 2),
                            "ghr_bits": ghr_bits.strip(),
                            "taken": int(taken),
                            "predicted": int(predicted),
                            "mispredict": int(mispredict),
                        })
                        seq += 1
    except FileNotFoundError:
        pass
    return records

# Load baseline (predictor_sel=0) logs for each benchmark
bm1 = extract_trace_from_log(f"{WORK}/def_BM1_COUNTDOWN_p0.log")
bm2 = extract_trace_from_log(f"{WORK}/def_BM2_ACCUMULATE_p0.log")
bm3 = extract_trace_from_log(f"{WORK}/def_BM3_NESTED_p0.log")
bm4 = extract_trace_from_log(f"{WORK}/def_BM4_MIXED_p0.log")  # HELD OUT

print(f"Trace sizes:")
print(f"  BM1: {len(bm1)} branches (training)")
print(f"  BM2: {len(bm2)} branches (training)")
print(f"  BM3: {len(bm3)} branches (training)")
print(f"  BM4: {len(bm4)} branches (HELD-OUT test)")

# ── Training set: BM1 + BM2 + BM3 ──────────────────────────────────
train_set = bm1 + bm2 + bm3
# Re-number sequences
for i, r in enumerate(train_set): r["seq"] = i

print(f"\n  Training set total: {len(train_set)} branches")
print(f"  Test set (BM4):     {len(bm4)} branches")

# ── Baseline 1: Static not-taken on BM4 ────────────────────────────
static_acc_bm4 = 100 * sum(1 - r["taken"] for r in bm4) / len(bm4) if bm4 else 0

# ── Baseline 2: Online hardware on BM4 (single pass, no prior) ─────
online_acc_bm4, online_weights = simulate_online(bm4)

# ── Baseline 3: Online hardware on full trace (original paper) ──────
full_trace = bm1 + bm2 + bm3 + bm4
for i, r in enumerate(full_trace): r["seq"] = i
online_acc_full, _ = simulate_online(full_trace)

# ── Train offline on BM1+BM2+BM3 only ─────────────────────────────
print(f"\nTraining offline on BM1+BM2+BM3...")
weights_trained, epoch_accs = train(train_set)

# ── Evaluate on BM4 (held-out) ─────────────────────────────────────
eval_bm4 = evaluate(weights_trained, bm4)

# ── Also evaluate on full set for comparison ───────────────────────
eval_full = evaluate(weights_trained, full_trace)

# ── Online on training set only (for fair comparison) ──────────────
online_acc_train, _ = simulate_online(train_set)

print(f"\n{'='*60}")
print(f"  HELD-OUT TEST RESULTS (BM4 = unseen test set)")
print(f"{'='*60}")
print(f"  Training set          : BM1 + BM2 + BM3 ({len(train_set)} branches)")
print(f"  Test set              : BM4 Mixed ({len(bm4)} branches, HELD-OUT)")
print(f"")
print(f"  ON HELD-OUT BM4:")
print(f"  Static not-taken      : {static_acc_bm4:.2f}%")
print(f"  Online (BM4 only)     : {online_acc_bm4:.2f}%")
print(f"  Offline (trained on   ")
print(f"   BM1+BM2+BM3)        : {eval_bm4['accuracy']:.2f}%")
print(f"  Generalization gain   : +{eval_bm4['accuracy'] - online_acc_bm4:.2f}pp")
print(f"")
print(f"  Confusion (BM4 test):")
print(f"  TP={eval_bm4['tp']} TN={eval_bm4['tn']} "
      f"FP={eval_bm4['fp']} FN={eval_bm4['fn']}")
print(f"")
print(f"  ON FULL TRACE (all 4 benchmarks):")
print(f"  Online (full trace)   : {online_acc_full:.2f}%")
print(f"  Offline (trained on   ")
print(f"   BM1+BM2+BM3)        : {eval_full['accuracy']:.2f}%")
print(f"{'='*60}")

# ── Format for paper Table III update ──────────────────────────────
print(f"\n{'='*60}")
print(f"  UPDATED TABLE III FOR PAPER")
print(f"{'='*60}")
print(f"  {'Metric':<35} {'Static':>8} {'Online':>8} {'Offline':>8}")
print(f"  {'-'*59}")
print(f"  {'Accuracy (full trace)':<35} {'51.6%':>8} {'92.55%':>8} {'94.41%':>8}")
print(f"  {'Accuracy (held-out BM4 test)':<35} {static_acc_bm4:>7.1f}% "
      f"{online_acc_bm4:>7.2f}% {eval_bm4['accuracy']:>7.2f}%")
print(f"  {'False Positives (BM4 test)':<35} {'—':>8} {'—':>8} {eval_bm4['fp']:>8}")
print(f"  {'False Negatives (BM4 test)':<35} {'—':>8} {'—':>8} {eval_bm4['fn']:>8}")
print(f"  {'Generalization gain (BM4)':<35} {'—':>8} {'baseline':>8} "
      f"+{eval_bm4['accuracy']-online_acc_bm4:.2f}pp")
print(f"{'='*60}")

# ── Write sentence for paper ────────────────────────────────────────
print(f"""
SENTENCE TO ADD IN PAPER (Section II-C, Phase 2):

"To evaluate generalization, BM4 was held out from training 
and used exclusively as a test benchmark. The perceptron was 
trained on traces from BM1, BM2, and BM3 only ({len(train_set)} branch 
events) and evaluated on the unseen BM4 trace ({len(bm4)} branch events). 
The offline-trained model achieves {eval_bm4['accuracy']:.2f}% accuracy on 
the held-out benchmark, compared to {online_acc_bm4:.2f}% for online 
hardware learning on the same benchmark, a generalization gain 
of +{eval_bm4['accuracy']-online_acc_bm4:.2f} percentage points."
""")
