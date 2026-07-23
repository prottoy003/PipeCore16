// ============================================================
//  BENCHMARK PROGRAMS — PipeCore16 Branch Prediction Study
//
//  Four programs, each replacing instruction_memory in cpu_complete_bp.sv.
//  Select which benchmark to use by swapping the module at the bottom.
//
//  ISA ENCODING REFERENCE:
//    R-type : {op[3:0], rs[2:0], rt[2:0], rd[2:0], 3'b000}
//    I-type : {op[3:0], rs[2:0], rd[2:0], imm6[5:0]}
//    BEQ    : {4'b0110, rs[2:0], rt[2:0], imm6[5:0]}
//             jumps to PC+1+imm6 if rs==rt
//             BEQ R0,R0,offset = unconditional jump (R0==R0 always)
//
//  OPCODES : 0000=ADD  0001=SUB  0010=AND  0011=OR
//            0100=LOAD 0101=STORE 0110=BEQ  0111=ADDI
//
//  BRANCH STATISTICS SUMMARY (for paper):
//  ┌─────────┬────────┬────────┬─────────┬──────────────────────────────┐
//  │ Program │ Iters  │ Total  │  Taken  │ Pattern                      │
//  │         │        │ Branch │         │                              │
//  ├─────────┼────────┼────────┼─────────┼──────────────────────────────┤
//  │ BM1     │  20    │  39    │  20     │ always-taken back-branch     │
//  │ BM2     │  10    │  19    │  10     │ accumulate loop              │
//  │ BM3     │ 4×5=20 │  40    │  24     │ nested loops (2 branch PCs) │
//  │ BM4     │  15    │  44    │  16     │ mixed taken/not-taken        │
//  └─────────┴────────┴────────┴─────────┴──────────────────────────────┘
//  Combined: 142 branch executions — sufficient for ML training data
// ============================================================

`timescale 1ns/1ps

// ============================================================
//  BENCHMARK 1: COUNT_DOWN
//
//  A tight countdown loop — the most common loop structure.
//  Back-branch (PC5) is always taken (19 times).
//  Exit branch  (PC4) is not-taken 19 times, taken once.
//
//  Registers used:
//    R1 = counter (starts at 20, decrements to 0)
//    R2 = accumulator (sum of 20+19+...+1 = 210)
//
//  Assembly:
//    [0] ADDI R1, R0, 20      counter = 20
//    [1] ADDI R2, R0, 0       accum   = 0
//    ; --- loop (PC 2) ---
//    [2] ADD  R2, R2, R1      accum += counter
//    [3] ADDI R1, R1, -1      counter--
//    [4] BEQ  R1, R0, +1      if counter==0 → exit (PC 6)
//    [5] BEQ  R0, R0, -4      unconditional back → PC 2
//    ; --- end ---
//    [6] NOP
//
//  Branch profile:
//    PC4 (exit) : NT×19, T×1   → predictor should learn NOT-TAKEN
//    PC5 (back) : T×19          → predictor should learn TAKEN immediately
//
//  Expected result: R2 = 210 (sum 1..20), R1 = 0
//  Cycles (no predictor): ~90  (20 iters × ~4.5 cyc + pipeline drain)
// ============================================================
module bm1_countdown (
    input  logic [15:0] addr,
    output logic [15:0] instr
);
    logic [15:0] mem [0:255];

    initial begin : bm1_init
        integer i;
        for (i = 0; i < 256; i++) mem[i] = 16'h0000;  // NOP sled

        // [0] ADDI R1, R0, 20  →  op=0111 rs=000 rd=001 imm=010100
        mem[0] = {4'b0111, 3'd0, 3'd1, 6'd20};

        // [1] ADDI R2, R0, 0   →  clear accumulator
        mem[1] = {4'b0111, 3'd0, 3'd2, 6'd0};

        // [2] ADD R2, R2, R1   →  op=0000 rs=010 rt=001 rd=010
        mem[2] = {4'b0000, 3'd2, 3'd1, 3'd2, 3'b000};

        // [3] ADDI R1, R1, -1  →  imm6 = 6'b111111 = -1
        mem[3] = {4'b0111, 3'd1, 3'd1, 6'b111111};

        // [4] BEQ R1, R0, +1   →  exit: offset=1  (→ PC 6)
        //     taken when counter reaches 0 (once only)
        mem[4] = {4'b0110, 3'd1, 3'd0, 6'd1};

        // [5] BEQ R0, R0, -4   →  back: offset=-4 (→ PC 2)
        //     R0==R0 always → unconditional loop-back
        //     6-bit signed -4 = 6'b111100
        mem[5] = {4'b0110, 3'd0, 3'd0, 6'b111100};

        // [6] NOP — end marker
        mem[6] = 16'h0000;
    end

    assign instr = mem[addr[7:0]];
endmodule


// ============================================================
//  BENCHMARK 2: ACCUMULATE
//
//  Simple accumulation loop with load/store —
//  exercises forwarding AND branch prediction together.
//
//  Registers used:
//    R1 = counter (10 → 0)
//    R2 = step    = 3
//    R3 = accum   (0 → 30)
//
//  Assembly:
//    [0] ADDI R1, R0, 10      counter = 10
//    [1] ADDI R2, R0, 3       step    = 3
//    [2] ADDI R3, R0, 0       accum   = 0
//    ; --- loop (PC 3) ---
//    [3] ADD  R3, R3, R2      accum += step
//    [4] ADDI R1, R1, -1      counter--
//    [5] BEQ  R1, R0, +1      if counter==0 → exit (PC 7)
//    [6] BEQ  R0, R0, -4      back → PC 3
//    ; --- end ---
//    [7] STORE R3, R0+0       MEM[0] = result (30)
//    [8] NOP
//
//  Branch profile:
//    PC5 (exit): NT×9,  T×1
//    PC6 (back): T×9
//
//  Expected result: R3 = 30, MEM[0] = 30, R1 = 0
// ============================================================
module bm2_accumulate (
    input  logic [15:0] addr,
    output logic [15:0] instr
);
    logic [15:0] mem [0:255];

    initial begin : bm2_init
        integer i;
        for (i = 0; i < 256; i++) mem[i] = 16'h0000;

        // [0] ADDI R1, R0, 10
        mem[0] = {4'b0111, 3'd0, 3'd1, 6'd10};

        // [1] ADDI R2, R0, 3
        mem[1] = {4'b0111, 3'd0, 3'd2, 6'd3};

        // [2] ADDI R3, R0, 0
        mem[2] = {4'b0111, 3'd0, 3'd3, 6'd0};

        // [3] ADD R3, R3, R2   →  op=0000 rs=011 rt=010 rd=011
        mem[3] = {4'b0000, 3'd3, 3'd2, 3'd3, 3'b000};

        // [4] ADDI R1, R1, -1
        mem[4] = {4'b0111, 3'd1, 3'd1, 6'b111111};

        // [5] BEQ R1, R0, +1   →  offset=1 (→ PC 7)
        mem[5] = {4'b0110, 3'd1, 3'd0, 6'd1};

        // [6] BEQ R0, R0, -4   →  offset=-4 (→ PC 3)
        mem[6] = {4'b0110, 3'd0, 3'd0, 6'b111100};

        // [7] STORE R3, R0+0   →  op=0101 rs=000 rt=011 imm=0
        mem[7] = {4'b0101, 3'd0, 3'd3, 6'd0};

        // [8] NOP
        mem[8] = 16'h0000;
    end

    assign instr = mem[addr[7:0]];
endmodule


// ============================================================
//  BENCHMARK 3: NESTED LOOP
//
//  Outer loop (4 iterations) × inner loop (5 iterations).
//  Key test: predictor must distinguish FOUR branch PCs
//  at different addresses — tests table indexing quality.
//
//  Registers:
//    R1 = outer counter (4 → 0)
//    R2 = inner_init    = 5 (constant)
//    R3 = inner counter (reloaded each outer iter)
//    R4 = accumulator   (counts to 20 = 4×5)
//
//  Assembly:
//    [0]  ADDI R1, R0, 4       outer = 4
//    [1]  ADDI R2, R0, 5       inner_init = 5
//    [2]  ADDI R4, R0, 0       accum = 0
//    ; --- outer loop (PC 3) ---
//    [3]  ADDI R3, R2, 0       R3 = inner_init  (ADDI R3,R2,0)
//    ; --- inner loop (PC 4) ---
//    [4]  ADDI R4, R4, 1       accum++
//    [5]  ADDI R3, R3, -1      inner--
//    [6]  BEQ  R3, R0, +1      inner done? → PC 8
//    [7]  BEQ  R0, R0, -4      back → PC 4
//    ; --- inner done ---
//    [8]  ADDI R1, R1, -1      outer--
//    [9]  BEQ  R1, R0, +1      outer done? → PC 11
//    [10] BEQ  R0, R0, -8      back → PC 3
//    ; --- end ---
//    [11] NOP
//
//  Branch profile:
//    PC6  inner_exit : NT×16, T×4  (not-taken most of the time)
//    PC7  inner_back : T×16         (always taken when reached)
//    PC9  outer_exit : NT×3,  T×1
//    PC10 outer_back : T×3
//
//  Expected: R4=20, R1=0
// ============================================================
module bm3_nested (
    input  logic [15:0] addr,
    output logic [15:0] instr
);
    logic [15:0] mem [0:255];

    initial begin : bm3_init
        integer i;
        for (i = 0; i < 256; i++) mem[i] = 16'h0000;

        // [0] ADDI R1, R0, 4
        mem[0] = {4'b0111, 3'd0, 3'd1, 6'd4};

        // [1] ADDI R2, R0, 5
        mem[1] = {4'b0111, 3'd0, 3'd2, 6'd5};

        // [2] ADDI R4, R0, 0   (clear accumulator)
        mem[2] = {4'b0111, 3'd0, 3'd4, 6'd0};

        // [3] ADDI R3, R2, 0   →  R3 = R2 + 0 = inner_init
        //     op=0111 rs=010 rd=011 imm=0
        mem[3] = {4'b0111, 3'd2, 3'd3, 6'd0};

        // [4] ADDI R4, R4, 1   →  op=0111 rs=100 rd=100 imm=1
        mem[4] = {4'b0111, 3'd4, 3'd4, 6'd1};

        // [5] ADDI R3, R3, -1
        mem[5] = {4'b0111, 3'd3, 3'd3, 6'b111111};

        // [6] BEQ R3, R0, +1   →  offset=1 (→ PC 8)
        mem[6] = {4'b0110, 3'd3, 3'd0, 6'd1};

        // [7] BEQ R0, R0, -4   →  offset=-4 (→ PC 4)
        //     6-bit -4 = 6'b111100
        mem[7] = {4'b0110, 3'd0, 3'd0, 6'b111100};

        // [8] ADDI R1, R1, -1
        mem[8] = {4'b0111, 3'd1, 3'd1, 6'b111111};

        // [9] BEQ R1, R0, +1   →  offset=1 (→ PC 11)
        mem[9] = {4'b0110, 3'd1, 3'd0, 6'd1};

        // [10] BEQ R0, R0, -8  →  offset=-8 (→ PC 3)
        //      6-bit -8 = 6'b111000
        mem[10] = {4'b0110, 3'd0, 3'd0, 6'b111000};

        // [11] NOP
        mem[11] = 16'h0000;
    end

    assign instr = mem[addr[7:0]];
endmodule


// ============================================================
//  BENCHMARK 4: MIXED PATTERN
//
//  Stress-tests prediction with three branches per iteration:
//  one mostly-not-taken (fires once), one always-not-taken exit,
//  one always-taken back. The mid-branch fires only when
//  counter == 2, creating an irregular spike in the trace.
//
//  Registers:
//    R1 = counter (15 → 0)
//    R2 = const 1  (for comparison)
//    R3 = const 2  (threshold for mid-branch)
//    R5 = accum
//
//  Assembly:
//    [0]  ADDI R1, R0, 15     counter = 15
//    [1]  ADDI R2, R0, 1      const1  = 1  (unused in cmp; kept for realism)
//    [2]  ADDI R3, R0, 2      threshold = 2
//    [3]  ADDI R5, R0, 0      accum = 0
//    ; --- loop (PC 4) ---
//    [4]  ADD  R5, R5, R1     accum += counter
//    [5]  SUB  R4, R1, R3     R4 = counter - 2
//    [6]  BEQ  R4, R0, +1     if counter==2 → skip bonus (PC 8)
//    [7]  ADDI R5, R5, 1      bonus +1 for iterations where counter≠2
//    [8]  ADDI R1, R1, -1     counter--
//    [9]  BEQ  R1, R0, +1     exit if counter==0 (→ PC 11)
//    [10] BEQ  R0, R0, -7     back → PC 4
//           offset = 4 - (10+1) = -7  → 6'b111001
//    ; --- end ---
//    [11] NOP
//
//  Branch profile (15 iterations):
//    PC6  (mid)  : NT×14, T×1   (taken only when counter hits 2)
//    PC9  (exit) : NT×14, T×1
//    PC10 (back) : T×14
//    Total: 44 branch executions  Taken: 16  Not-taken: 28
//
//  This is the hardest benchmark — the mid-branch PC6 is almost
//  always not-taken but fires once, which is difficult to predict.
// ============================================================
module bm4_mixed (
    input  logic [15:0] addr,
    output logic [15:0] instr
);
    logic [15:0] mem [0:255];

    initial begin : bm4_init
        integer i;
        for (i = 0; i < 256; i++) mem[i] = 16'h0000;

        // [0] ADDI R1, R0, 15
        mem[0] = {4'b0111, 3'd0, 3'd1, 6'd15};

        // [1] ADDI R2, R0, 1
        mem[1] = {4'b0111, 3'd0, 3'd2, 6'd1};

        // [2] ADDI R3, R0, 2
        mem[2] = {4'b0111, 3'd0, 3'd3, 6'd2};

        // [3] ADDI R5, R0, 0
        mem[3] = {4'b0111, 3'd0, 3'd5, 6'd0};

        // [4] ADD R5, R5, R1   →  op=0000 rs=101 rt=001 rd=101
        mem[4] = {4'b0000, 3'd5, 3'd1, 3'd5, 3'b000};

        // [5] SUB R4, R1, R3   →  op=0001 rs=001 rt=011 rd=100
        mem[5] = {4'b0001, 3'd1, 3'd3, 3'd4, 3'b000};

        // [6] BEQ R4, R0, +1   →  offset=1 (→ PC 8)
        mem[6] = {4'b0110, 3'd4, 3'd0, 6'd1};

        // [7] ADDI R5, R5, 1
        mem[7] = {4'b0111, 3'd5, 3'd5, 6'd1};

        // [8] ADDI R1, R1, -1
        mem[8] = {4'b0111, 3'd1, 3'd1, 6'b111111};

        // [9] BEQ R1, R0, +1   →  offset=1 (→ PC 11)
        mem[9] = {4'b0110, 3'd1, 3'd0, 6'd1};

        // [10] BEQ R0, R0, -7  →  offset=-7 (→ PC 4)
        //      PC10 + 1 + (-7) = 4  ✓
        //      6-bit -7 = 6'b111001
        mem[10] = {4'b0110, 3'd0, 3'd0, 6'b111001};

        // [11] NOP
        mem[11] = 16'h0000;
    end

    assign instr = mem[addr[7:0]];
endmodule


// ============================================================
//  ACTIVE BENCHMARK SELECTOR
//
//  Rename whichever benchmark you want to run as
//  "instruction_memory" to plug it into cpu_complete_bp.sv.
//  Only one should be active at a time.
//
//  Instructions:
//    1. In cpu_complete_bp.sv, delete or comment out the
//       existing instruction_memory module.
//    2. Include this file, then uncomment ONE of the aliases below.
// ============================================================

// UNCOMMENT ONE:
// (Rename the chosen module to instruction_memory for the CPU)

// BM1 — uncomment to activate:
// `define ACTIVE_BM bm1_countdown

// BM2 — uncomment to activate:
// `define ACTIVE_BM bm2_accumulate

// BM3 — uncomment to activate:
// `define ACTIVE_BM bm3_nested

// BM4 — uncomment to activate:
// `define ACTIVE_BM bm4_mixed

// ============================================================
//  BENCHMARK TESTBENCH
//  Verifies correctness of each benchmark in isolation.
//  Run this file standalone (not with cpu_complete_bp.sv).
