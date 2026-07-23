# PipeCore16 — ML-Based Branch Prediction for a 16-Bit Pipelined RISC Processor

**Paper:** A Machine Learning based Branch Prediction for a 16-Bit Pipelined RISC Processor using SystemVerilog  
**Author:** Aquib Ahmed Prottoy  
**Conference:** LURS 3rd Student Research Conference 2026 (LURSSRC 2026)

---

## Repository Structure

```
PipeCore16/
├── cpu_complete_bp.sv      # Full CPU design with branch predictors integrated
├── branch_predictor.sv     # Standalone branch predictor module (2-bit SAT + Perceptron)
├── cpu_tb_trace.sv         # Instrumented testbench — emits branch trace log
├── benchmarks.sv           # Four benchmark programs (BM1–BM4)
├── extract_trace.py        # Phase 1: Parse simulation log → branch_trace.csv
├── train_predictor.py      # Phase 2 & 3: Train perceptron offline → pretrained_weights.sv
└── README.md
```

---

## How to Run

### Step 1 — Simulate (EDA Playground or local Icarus Verilog)

```bash
# On local machine:
iverilog -g2012 -o sim cpu_complete_bp.sv cpu_tb_trace.sv
./sim > sim_log.txt
```

Select predictor mode by changing `predictor_sel` in `cpu_tb_trace.sv`:
- `2'd0` — No predictor (baseline)
- `2'd1` — 2-bit Saturating Counter
- `2'd2` — Perceptron Predictor

Select benchmark by replacing the `instruction_memory` module in `cpu_complete_bp.sv` with one of the four benchmarks from `benchmarks.sv`.

---

### Step 2 — Extract Branch Trace

```bash
python3 extract_trace.py sim_log.txt branch_trace.csv
```

Parses all `BRANCH_TRACE` lines from the simulation log and writes a CSV with columns: `seq, pc, ghr, ghr_bits, taken, predicted, mispredict`.

---

### Step 3 — Train Offline & Export Weights

```bash
python3 train_predictor.py branch_trace.csv
```

Outputs:
- `pretrained_weights.sv` — paste into `branch_predictor.sv` to replace zero-initialisation
- `training_report.txt` — accuracy comparison: static / online / offline

---

## Key Results

| Benchmark | Base IPC | SAT IPC | Perceptron IPC | SAT Gain |
|---|---|---|---|---|
| BM1 Count-Down | 0.1736 | 0.2270 | 0.2270 | +30.8% |
| BM2 Accumulate | 0.1690 | 0.2087 | 0.2087 | +23.5% |
| BM3 Nested Loop | 0.1717 | 0.2208 | — | +28.6% |
| BM4 Mixed | 0.2386 | 0.2863 | 0.2863 | +20.0% |
| **Average** | **0.1884** | **0.2357** | — | **+25.7%** |

**ML Training:**
| Method | Accuracy |
|---|---|
| Static Not-Taken | 51.6% |
| Online Hardware | 92.55% |
| Offline Batch (50 epochs) | 94.41% |

---

## Predictor Parameters

| Parameter | Value |
|---|---|
| Table size | 16 entries (PC[3:0] index) |
| History length | 4 bits (GHR) |
| Weight bits | 5-bit signed (−16 to +15) |
| Training threshold | θ = 6 |
| Offline epochs | 50 |

---

## Requirements

**Simulation:** Icarus Verilog (`iverilog`) or any SystemVerilog-2012 compatible simulator  
**Python:** 3.7+ (no external libraries required — standard library only)  
**EDA Playground:** Paste `cpu_complete_bp.sv` in Design pane, `cpu_tb_trace.sv` in Testbench pane

---

## Citation

If you use this work, please cite:

> A. A. Prottoy, "A Machine Learning based Branch Prediction for a 16-Bit Pipelined RISC Processor using SystemVerilog," in Proc. LURS 3rd Student Research Conference (LURSSRC 2026), 2026.
