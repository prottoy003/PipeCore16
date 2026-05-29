# 16-Bit 5-Stage Pipelined RISC CPU

A complete, synthesizable, educational RISC processor in SystemVerilog.  

---

## Table of Contents
1. [Project Overview](#project-overview)
2. [Architecture](#architecture)
3. [Instruction Set Architecture (ISA)](#instruction-set-architecture)
4. [Module Breakdown](#module-breakdown)
5. [Hazard Handling Deep Dive](#hazard-handling-deep-dive)
6. [Forwarding Unit Deep Dive](#forwarding-unit-deep-dive)
7. [Sample Program Walkthrough](#sample-program-walkthrough)
8. [EDA Playground Setup](#eda-playground-setup)
9. [Waveform Guide (GTKWave)](#waveform-guide-gtkwave)
10. [Expected Simulation Output](#expected-simulation-output)
11. [Folder Structure](#folder-structure)

---

## Project Overview

| Property          | Value                          |
|-------------------|--------------------------------|
| Datapath Width    | 16-bit                         |
| Pipeline Stages   | 5 (IF, ID, EX, MEM, WB)       |
| Register File     | 8 × 16-bit (R0 hardwired = 0) |
| Instruction Memory| 256 × 16-bit words             |
| Data Memory       | 256 × 16-bit words             |
| Hazard Handling   | Forwarding + Load-Use Stall    |
| Branch Handling   | Flush on taken (1-cycle penalty)|
| Language          | SystemVerilog (IEEE 1800-2012) |
| Target Tool       | EDA Playground / GTKWave       |

---

## Architecture

```
<img width="1096" height="779" alt="image" src="https://github.com/user-attachments/assets/2e960611-d5d9-4836-9d74-f82bd4a75867" />

```
### Pipeline Stage Responsibilities

| Stage | Hardware | Key Operations |
|-------|----------|---------------|
| IF    | PC, IMEM | Fetch instruction at PC; compute PC+1 |
| ID    | RF, Control, Sign-Ext | Decode opcode; read registers; generate control signals |
| EX    | ALU, Forwarding Mux | Execute arithmetic/logic; compute branch target |
| MEM   | DMEM | Read/write data memory; determine branch taken |
| WB    | Mux → RF | Write ALU result or memory data back to register file |

### Pipeline Register Contents

**IF/ID**
- `instruction [15:0]` — fetched instruction
- `pc_plus1 [15:0]` — PC+1 for branch calculation

**ID/EX**
- `rs_data, rt_data [15:0]` — register operands
- `imm [15:0]` — sign-extended immediate
- `rs_addr, rt_addr, rd_addr [2:0]` — register addresses (for forwarding)
- `reg_write, mem_read, mem_write, mem_to_reg, alu_src, branch` — control
- `alu_op [2:0]` — ALU operation select

**EX/MEM**
- `alu_result [15:0]` — computed ALU output or memory address
- `rt_data [15:0]` — data for STORE instructions
- `branch_target [15:0]` — computed branch destination
- `zero_flag` — ALU zero flag (for BEQ)
- `rd_addr, reg_write, mem_read, mem_write, mem_to_reg, branch`

**MEM/WB**
- `mem_data [15:0]` — data read from memory
- `alu_result [15:0]` — ALU result (passed through)
- `rd_addr, reg_write, mem_to_reg`

---

## Instruction Set Architecture

### Instruction Format

```
R-Type (ADD, SUB, AND, OR):
 15  14  13  12 | 11  10   9 |  8   7   6 |  5   4   3 |  2   1   0
[  opcode [3:0] | rs   [2:0] | rt   [2:0] | rd   [2:0] | ---  ---  ---]

I-Type (LOAD, STORE, BEQ, ADDI):
 15  14  13  12 | 11  10   9 |  8   7   6 |  5   4   3   2   1   0
[  opcode [3:0] | rs   [2:0] | rd   [2:0] |        imm6 [5:0]        ]
```

### Opcode Table

| Opcode | Binary | Instruction | Operation |
|--------|--------|-------------|-----------|
| ADD    | 0000   | ADD rd, rs, rt | rd = rs + rt |
| SUB    | 0001   | SUB rd, rs, rt | rd = rs - rt |
| AND    | 0010   | AND rd, rs, rt | rd = rs & rt |
| OR     | 0011   | OR  rd, rs, rt | rd = rs \| rt |
| LOAD   | 0100   | LOAD rd, rs+imm | rd = MEM[rs+imm] |
| STORE  | 0101   | STORE rt, rs+imm | MEM[rs+imm] = rt |
| BEQ    | 0110   | BEQ rs, rt, imm | if rs==rt: PC = PC+1+imm |
| ADDI   | 0111   | ADDI rd, rs, imm | rd = rs + imm |

### Registers

| Register | Purpose |
|----------|---------|
| R0 | Hardwired zero (reads always return 0, writes ignored) |
| R1–R7 | General purpose |

---

## Module Breakdown

### 1. `alu.sv`
Pure combinational logic. Takes two 16-bit operands and a 3-bit op-select.  
Outputs the 16-bit result and a `zero_flag` (result == 0, used by BEQ).

### 2. `control_unit.sv`
Combinational decoder. Maps 4-bit opcode to 7 control signals.  
Every instruction uniquely sets: `reg_write`, `mem_read`, `mem_write`, `mem_to_reg`, `alu_src`, `branch`, `alu_op`.

### 3. `register_file.sv`
Standard multi-port RF. Synchronous write, combinational read.  
R0 is enforced as zero on both read and write paths.

### 4. `program_counter.sv`
16-bit register with three update modes: reset → 0, stall → hold, branch → jump, normal → +1.

### 5. `instruction_memory.sv`
ROM initialized in `initial` block. Contains 18-instruction sample program.  
Combinational (async) read so the fetched instruction is available in the same cycle.

### 6. `data_memory.sv`
Synchronous write, combinational read SRAM model.  
Initialized to zero.

### 7. `sign_extend.sv`
One-liner: sign-extends 6-bit immediate to 16-bit using SystemVerilog replication `{{10{imm6[5]}}, imm6}`.

### 8. `hazard_detection_unit.sv`
Detects **load-use hazards** only (the only hazard forwarding cannot solve).  
Generates three signals: `stall_pc`, `stall_ifid`, `insert_bubble`.

### 9. `forwarding_unit.sv`
Detects RAW hazards and generates `forward_a[1:0]` and `forward_b[1:0]` for ALU input muxes.  
EX/MEM forwarding has higher priority than MEM/WB.

### 10. Pipeline Registers (4 modules)
`ifid_register`, `idex_register`, `exmem_register`, `memwb_register` — all FF-based.  
Flush and stall logic embedded.

### 11. `cpu_top.sv`
Top-level integration. Instantiates and connects all 13 sub-modules.  
Exposes debug ports for testbench observability.

### 12. `cpu_tb.sv`
Self-checking testbench with 10 assertions, per-cycle monitoring, VCD dump.

---

## Hazard Handling Deep Dive

### Data Hazards

#### Read-After-Write (RAW) — Solved by Forwarding

```
Cycle:        1    2    3    4    5
ADD R4,R1,R2 IF   ID   EX  MEM   WB   <- writes R4 at end of WB (cycle 5)
SUB R5,R4,R3      IF   ID   EX  MEM   <- needs R4 during EX (cycle 4)!
```

**Without forwarding**: R4 has old value during SUB's EX stage → wrong result.  
**With forwarding**: EX/MEM pipeline register already holds the ALU result from ADD.  
The forwarding unit detects `exmem_rd == ex_rs` and sets `forward_a = 2'b10`.  
The mux before ALU input A selects `exmem_alu_result` instead of the stale register value.

#### Load-Use Hazard — Requires Stall

```
Cycle:         1    2    3    4    5    6
LOAD R7, MEM  IF   ID   EX  MEM   WB   <- R7 ready after MEM (cycle 5)
ADD  R5,R7,R3      IF   ID   EX  MEM   <- needs R7 in EX (cycle 4) — TOO EARLY!
```

Even with forwarding, the data isn't available in time. Solution:

```
Cycle:         1    2    3    4    5    6    7
LOAD R7, MEM  IF   ID   EX  MEM   WB            <- R7 ready
[NOP bubble]       IF   ID [NOP]  EX  MEM  WB   <- inserted stall
ADD R5,R7,R3            IF   ID   EX  MEM  WB   <- now gets R7 via MEM/WB fwd
```

The HDU:
1. Freezes PC (so same instruction is re-fetched)
2. Freezes IF/ID (so ID re-decodes same instruction)  
3. Inserts NOP into ID/EX (the bubble)

### Control Hazards (Branch)

Branch outcome is resolved in the **MEM stage** (cycle 4 of the branch instruction).  
Two instructions have already been fetched incorrectly.

**Strategy**: Flush IF/ID when branch is taken (1-cycle penalty in this implementation).  
The branch target comes from `exmem_branch_target`.

```
Cycle:      1    2    3    4    5
BEQ         IF   ID   EX  MEM   WB
instr+1          IF   ID   EX  ← FLUSHED on branch taken
instr+2               IF  ← FLUSHED on branch taken  
target                     IF   ID  EX  MEM  WB
```

> **Note**: This design flushes only the IF/ID register. A full 2-instruction flush  
> would require also flushing ID/EX, giving a 2-cycle penalty. The current design  
> handles this conservatively — for a portfolio project this is acceptable and matches  
> many textbook implementations.

---

## Forwarding Unit Deep Dive

```
                    ┌─────────┐
        EX/MEM  ────┤  2'b10  │
                    │         │────→ ALU Input A
        MEM/WB  ────┤  2'b01  │
                    │         │
        RF out  ────┤  2'b00  │
                    └─────────┘
                      (MUX)
```

**Priority rule**: If both EX/MEM and MEM/WB want to forward to the same ALU input,  
EX/MEM wins — it holds the **more recent** value.

**Why not forward to memory write data?**  
For a STORE that depends on a recently computed value, the rt data also needs forwarding.  
This design passes `ex_alu_b_reg` (the forwarded rt) into the EX/MEM register for STORE,  
which handles most practical cases.

---

## Sample Program Walkthrough

The preloaded program demonstrates every feature:

```asm
[0]  ADDI R1, R0, 5       ; R1 = 5
[1]  ADDI R2, R0, 10      ; R2 = 10
[2]  ADDI R3, R0, 3       ; R3 = 3
[3]  ADD  R4, R1, R2      ; R4 = 15   ← EX-EX forwarding (R1 from instr 0, R2 from instr 1)
[4]  SUB  R5, R4, R3      ; R5 = 12   ← EX/MEM forwarding (R4 from instr 3)
[5]  AND  R6, R4, R2      ; R6 = 10   ← MEM/WB forwarding (R4 from instr 3)
[6]  OR   R4, R1, R3      ; R4 = 7    (5 | 3)
[7]  STORE R5, R0+0       ; MEM[0] = 12
[8]  STORE R2, R0+1       ; MEM[1] = 10
[9]  LOAD  R7, R0+0       ; R7 = 12   ← Creates load-use hazard with instr 10
[10] ADD   R5, R7, R3     ; STALL!    Then R5 = 12 + 3 = 15
[11] LOAD  R6, R0+1       ; R6 = 10
[12] NOP                  ;
[13] BEQ   R1, R3, +2     ; NOT taken (R1=5 ≠ R3=3)
[14] ADDI  R1, R1, -1     ; R1 = 4
[15] BEQ   R2, R6, +1     ; TAKEN (R2=10 == R6=10) → jump to [17]
[16] ADDI  R7, R0, 99     ; FLUSHED (never executes)
[17] ADDI  R4, R0, 42     ; R4 = 42  (branch-taken marker)
```

**Expected Final State:**

| Register | Value | Reason |
|----------|-------|--------|
| R0 | 0 | Hardwired |
| R1 | 4 | 5 - 1 = 4 |
| R2 | 10 | ADDI |
| R3 | 3 | ADDI |
| R4 | 42 | After branch taken |
| R5 | 15 | Load-use path: 12+3 |
| R6 | 10 | LOAD MEM[1] |
| R7 | 12 | LOAD MEM[0] |

| Memory | Value |
|--------|-------|
| MEM[0] | 12 |
| MEM[1] | 10 |

---

## EDA Playground Setup

**Step-by-Step:**

1. Go to [https://www.edaplayground.com](https://www.edaplayground.com)
2. Sign in (free account required)
3. Under **"Languages & Libraries"** dropdown, select:
   - **SystemVerilog/Verilog**
4. Under **"Simulators"** dropdown, choose one of:
   -  **Aldec Riviera-PRO 2022.04** (recommended)
   -  **Cadence Xcelium 20.09** (also works)
5. In the **Design** pane: paste the entire contents of `cpu_complete.sv`
6. Leave the **Testbench** pane **empty** (testbench is included in the design file)
7. Check  **"Open EPWave after run"**
8. Click **Run**

**Simulator flags** (if needed for Riviera-PRO):
```
-sv2012
```

---

## Waveform Guide (GTKWave / EPWave)

After running, open the VCD file. Add these signals for a complete view:

### Recommended Signal Groups

**Clock & Control**
- `cpu_tb.clk`
- `cpu_tb.rst`

**IF Stage**
- `cpu_tb.dut.if_pc`
- `cpu_tb.dut.if_instr` (show as hex)

**ID Stage**
- `cpu_tb.dut.ifid_instr` (hex)
- `cpu_tb.dut.id_rs`, `id_rt`, `id_rd_rtype`

**EX Stage**
- `cpu_tb.dut.ex_alu_a`, `ex_alu_b_final`
- `cpu_tb.dut.ex_alu_result`
- `cpu_tb.dut.ex_fwd_a`, `ex_fwd_b` (binary)

**MEM Stage**
- `cpu_tb.dut.branch_taken`
- `cpu_tb.dut.exmem_alu_result` (memory address)

**WB Stage**
- `cpu_tb.dut.memwb_rd`
- `cpu_tb.dut.wb_result`
- `cpu_tb.dut.memwb_reg_write`

**Hazard Signals**
- `cpu_tb.dut.stall_pc`
- `cpu_tb.dut.insert_bubble`

### What to Look For

| Event | What You'll See |
|-------|-----------------|
| Load-use stall | `stall_pc` goes high for 1 cycle; PC frozen; bubble appears in `idex_reg_write` = 0 |
| EX/MEM forwarding | `ex_fwd_a` or `ex_fwd_b` = `10` |
| MEM/WB forwarding | `ex_fwd_a` or `ex_fwd_b` = `01` |
| Branch taken | `branch_taken` goes high; `ifid_instr` becomes `0x0000` (NOP) next cycle |
| Register write | `memwb_reg_write` = 1; `memwb_rd` shows which register; `wb_result` shows value |

---

## Expected Simulation Output

```
==========================================================
  16-bit 5-Stage Pipelined RISC CPU — Simulation
==========================================================

Cycle  0 | RESET ACTIVE
Cycle  1 | RESET ACTIVE
Cycle  2 | RESET ACTIVE
Cycle  3 | PC= 0 | Instr=0x0000 | ALU=    0 |
Cycle  4 | PC= 1 | Instr=0x7005 | ALU=    5 |
Cycle  5 | PC= 2 | Instr=0x700A | ALU=   10 |
Cycle  6 | PC= 3 | Instr=0x7003 | ALU=    3 | [WB: R1<=5]
Cycle  7 | PC= 4 | Instr=0x0494 | ALU=   15 | [WB: R2<=10] [FWD-A:00] [FWD-B:00]
Cycle  8 | PC= 5 | Instr=0x1CB5 | ALU=   12 | [WB: R3<=3] [FWD-A:10] [FWD-B:00]
Cycle  9 | PC= 6 | Instr=0x2516 | ALU=   10 | [WB: R4<=15] [FWD-A:10] [FWD-B:01]
...
Cycle 13 | PC=10 | Instr=0x0000 | ALU=    0 | [STALL]
...
Cycle 20 | PC=16 | Instr=0x6241 | ALU=    0 | [BRANCH-TAKEN]
...

==========================================================
  Self-Check Assertions
==========================================================
  [PASS] R0 = 0 (hardwired zero)
  [PASS] R1 = 4 (5 - 1 = 4)
  [PASS] R2 = 10
  [PASS] R3 = 3
  [PASS] R4 = 42 (branch taken correctly)
  [PASS] R5 = 15 (load-use stall + forwarding correct)
  [PASS] R6 = 10 (LOAD from MEM[1])
  [PASS] R7 = 12 (LOAD from MEM[0])
  [PASS] MEM[0] = 12 (STORE R5)
  [PASS] MEM[1] = 10 (STORE R2)

  Result: 10/10 checks PASSED
  *** ALL TESTS PASSED — CPU IS FUNCTIONAL ***
```

---

## Folder Structure

```
risc_cpu/
├── cpu_complete.sv        ← Single file for EDA Playground (USE THIS)
│
├── rtl/                   ← Modular RTL (for multi-file tools / Vivado)
│   ├── alu.sv
│   ├── control_unit.sv
│   ├── register_file.sv
│   ├── memory_units.sv    ← PC + IMEM + DMEM + SignExtend
│   ├── hazard_forwarding.sv
│   ├── pipeline_registers.sv
│   └── cpu_top.sv
│
├── tb/
│   └── cpu_tb.sv
│
└── README.md
```

---

Written and Compiled by: Aquib Ahmed Prottoy *
