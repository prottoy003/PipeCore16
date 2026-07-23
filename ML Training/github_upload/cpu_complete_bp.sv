// ============================================================
//  BRANCH PREDICTOR — PipeCore16
//
//  Two hardware-synthesizable predictors, selectable via
//  PREDICTOR_TYPE parameter:
//    0 = 2-Bit Saturating Counter (classical baseline)
//    1 = Perceptron Predictor     (ML-based, Jiménez & Lin 2001)
//
//  INTERFACE
//  ─────────
//  IF stage  → pc_fetch  → predict_taken  (combinational)
//  MEM stage → train_en, pc_train, actual_taken → weight/counter update
//
//  PARAMETERS
//  ──────────
//    PREDICTOR_TYPE : 0=2-bit SAT  1=Perceptron
//    TABLE_BITS     : index bits into predictor table (2^N entries)
//    HIST_LEN       : global history register length (perceptron only)
//    WEIGHT_BITS    : signed weight width (perceptron only)
//    THRESHOLD      : training threshold ≈ 1.93*HIST_LEN + 14
// ============================================================

`timescale 1ns/1ps

module branch_predictor #(
    parameter PREDICTOR_TYPE = 1,
    parameter TABLE_BITS     = 4,
    parameter HIST_LEN       = 4,
    parameter WEIGHT_BITS    = 5,
    parameter THRESHOLD      = 6
)(
    input  logic        clk,
    input  logic        rst,

    // IF stage: prediction request (combinational output)
    input  logic [15:0] pc_fetch,
    output logic        predict_taken,

    // MEM stage: training / correction
    input  logic        train_en,
    input  logic [15:0] pc_train,
    input  logic        actual_taken,
    input  logic        pred_was_taken,

    // Debug
    output logic        mispredict,
    output logic [15:0] dbg_ghr
);

    localparam TABLE_SIZE = 1 << TABLE_BITS;

    wire [TABLE_BITS-1:0] fetch_idx = pc_fetch[TABLE_BITS-1:0];
    wire [TABLE_BITS-1:0] train_idx = pc_train[TABLE_BITS-1:0];

    assign mispredict = train_en && (pred_was_taken != actual_taken);

    // ============================================================
    // PREDICTOR 0: 2-BIT SATURATING COUNTER
    // ============================================================
    generate
    if (PREDICTOR_TYPE == 0) begin : gen_twobit

        logic [1:0] sat_table [0:TABLE_SIZE-1];

        // Predict taken when top bit is 1 (states 10 or 11)
        assign predict_taken = sat_table[fetch_idx][1];
        assign dbg_ghr       = '0;

        always_ff @(posedge clk) begin
            if (rst) begin : sat_reset
                integer i;
                for (i = 0; i < TABLE_SIZE; i++)
                    sat_table[i] <= 2'b01;  // init: Weakly Not-Taken
            end else if (train_en) begin
                if (actual_taken) begin
                    if (sat_table[train_idx] != 2'b11)
                        sat_table[train_idx] <= sat_table[train_idx] + 1;
                end else begin
                    if (sat_table[train_idx] != 2'b00)
                        sat_table[train_idx] <= sat_table[train_idx] - 1;
                end
            end
        end

    end // gen_twobit

    // ============================================================
    // PREDICTOR 1: PERCEPTRON PREDICTOR
    //
    // y = w[0] + sum_{i=1}^{HIST_LEN} w[i] * x[i]
    // x[i] = +1 if history bit i was taken, -1 if not-taken
    // predict_taken = (y >= 0)
    //
    // Train when: mispredicted OR |y| < THRESHOLD
    //   w[i] += (actual_taken==history[i]) ? +1 : -1
    //   w[0] += actual_taken ? +1 : -1
    // ============================================================
    else begin : gen_perceptron

        // Weight storage: [TABLE_SIZE entries][HIST_LEN+1 weights each]
        // Index 0 = bias weight, 1..HIST_LEN = history weights
        logic signed [WEIGHT_BITS-1:0] weights [0:TABLE_SIZE-1][0:HIST_LEN];

        // Global History Register
        logic [HIST_LEN-1:0] ghr;

        assign dbg_ghr = 16'(unsigned'(ghr));

        // ── Combinational dot-product for prediction ───────────
        // SUM_BITS must hold: HIST_LEN weights each up to 2^(WEIGHT_BITS-1)
        // Maximum sum magnitude = (HIST_LEN+1) * 2^(WEIGHT_BITS-1)
        // Using WEIGHT_BITS+4 gives ample headroom for HIST_LEN up to 16
        localparam SUM_BITS = WEIGHT_BITS + 4;

        logic signed [SUM_BITS-1:0] predict_sum;
        logic signed [SUM_BITS-1:0] w_ext [0:HIST_LEN]; // sign-extended weights

        // Sign-extend each weight to SUM_BITS for the sum
        genvar gi;
        for (gi = 0; gi <= HIST_LEN; gi++) begin : sign_ext
            assign w_ext[gi] = SUM_BITS'(signed'(weights[fetch_idx][gi]));
        end

        // Dot product: add or subtract each weight based on history bit
        always_comb begin : dot_product
            integer j;
            predict_sum = w_ext[0];  // start with bias
            for (j = 1; j <= HIST_LEN; j++) begin
                if (ghr[j-1])
                    predict_sum = predict_sum + w_ext[j];
                else
                    predict_sum = predict_sum - w_ext[j];
            end
        end

        assign predict_taken = (predict_sum > 0);

        // ── GHR snapshots: pipe history forward through stages ─
        // Branch takes 3 cycles from IF to MEM resolution.
        // We snapshot GHR at fetch time and shift it to MEM stage
        // so training uses the history that was active at fetch.
        logic [HIST_LEN-1:0]         ghr_snap [0:2];
        logic signed [SUM_BITS-1:0]  sum_snap [0:2];

        // ── Weight clamp function ──────────────────────────────
        localparam signed [WEIGHT_BITS-1:0] W_MAX =  (1 << (WEIGHT_BITS-1)) - 1;
        localparam signed [WEIGHT_BITS-1:0] W_MIN = -(1 << (WEIGHT_BITS-1));

        function automatic logic signed [WEIGHT_BITS-1:0] clamp_w;
            input logic signed [WEIGHT_BITS:0] v;  // one extra bit
            if (v > $signed({1'b0, W_MAX}))
                clamp_w = W_MAX;
            else if (v < $signed({W_MIN[WEIGHT_BITS-1], W_MIN}))
                clamp_w = W_MIN;
            else
                clamp_w = v[WEIGHT_BITS-1:0];
        endfunction

        // ── Synchronous training ───────────────────────────────
        always_ff @(posedge clk) begin : perceptron_ff
            if (rst) begin : perc_reset
                integer ii, kk;
                ghr <= '0;
                for (ii = 0; ii < TABLE_SIZE; ii++)
                    for (kk = 0; kk <= HIST_LEN; kk++)
                        weights[ii][kk] <= '0;
                ghr_snap[0] <= '0; ghr_snap[1] <= '0; ghr_snap[2] <= '0;
                sum_snap[0] <= '0; sum_snap[1] <= '0; sum_snap[2] <= '0;
            end else begin
                // Shift GHR and sum snapshots toward MEM stage
                ghr_snap[0] <= ghr;          sum_snap[0] <= predict_sum;
                ghr_snap[1] <= ghr_snap[0];  sum_snap[1] <= sum_snap[0];
                ghr_snap[2] <= ghr_snap[1];  sum_snap[2] <= sum_snap[1];

                if (train_en) begin : do_train
                    integer jj;
                    logic signed [WEIGHT_BITS:0] new_w;
                    logic [HIST_LEN-1:0]         t_ghr;
                    logic signed [SUM_BITS-1:0]  t_sum;

                    t_ghr = ghr_snap[2];
                    t_sum = sum_snap[2];

                    // Train on misprediction OR low confidence
                    if ((pred_was_taken != actual_taken) ||
                        (t_sum < $signed(THRESHOLD) &&
                         t_sum > $signed(-THRESHOLD))) begin

                        // Bias update
                        new_w = {weights[train_idx][0][WEIGHT_BITS-1],
                                  weights[train_idx][0]}
                                  + (actual_taken ? 1 : -1);
                        weights[train_idx][0] <= clamp_w(new_w);

                        // History weight updates
                        for (jj = 1; jj <= HIST_LEN; jj++) begin
                            // Agreement between outcome and history → increment
                            if (actual_taken == t_ghr[jj-1])
                                new_w = {weights[train_idx][jj][WEIGHT_BITS-1],
                                          weights[train_idx][jj]} + 1;
                            else
                                new_w = {weights[train_idx][jj][WEIGHT_BITS-1],
                                          weights[train_idx][jj]} - 1;
                            weights[train_idx][jj] <= clamp_w(new_w);
                        end
                    end

                    // Update GHR with actual outcome
                    ghr <= {ghr[HIST_LEN-2:0], actual_taken};
                end
            end
        end // perceptron_ff

    end // gen_perceptron
    endgenerate

endmodule
// ============================================================
//  16-BIT 5-STAGE PIPELINED RISC CPU
//  Complete Single-File Version for EDA Playground
//
//  Author:  [Your Name]
//  Tool:    EDA Playground (Aldec Riviera-PRO or Cadence Xcelium)
//  Lang:    SystemVerilog (IEEE 1800-2012)
//
//  HOW TO USE ON EDA PLAYGROUND:
//  1. Go to https://www.edaplayground.com
//  2. Choose SystemVerilog/Verilog -> Select simulator
//     (Aldec Riviera-PRO 2022.04 OR Cadence Xcelium 20.09)
//  3. Paste this ENTIRE file into the "Design" pane
//  4. Leave the "Testbench" pane empty (TB is included here)
//  5. Check "Open EPWave after run"
//  6. Click Run
//
//  ARCHITECTURE OVERVIEW:
//  ┌─────────────────────────────────────────────────────┐
//  │  IF → [IF/ID] → ID → [ID/EX] → EX → [EX/MEM]      │
//  │      → MEM → [MEM/WB] → WB                         │
//  │                                                     │
//  │  Hazard Unit: stalls pipeline on load-use hazard    │
//  │  Forwarding:  EX/MEM→EX and MEM/WB→EX paths        │
//  │  Branch:      resolved in MEM, flushes IF/ID        │
//  └─────────────────────────────────────────────────────┘
//
//  ISA ENCODING (16-bit instruction word):
//  R-Type: [15:12]=op [11:9]=rs [8:6]=rt [5:3]=rd [2:0]=---
//  I-Type: [15:12]=op [11:9]=rs [8:6]=rd [5:0]=imm6
//
//  OPCODES:
//   0000=ADD  0001=SUB  0010=AND  0011=OR
//   0100=LOAD 0101=STORE 0110=BEQ 0111=ADDI
// ============================================================

`timescale 1ns/1ps

// ============================================================
// MODULE 1: ALU
// ============================================================
module alu (
    input  logic [15:0] a,
    input  logic [15:0] b,
    input  logic [2:0]  alu_op,
    output logic [15:0] result,
    output logic        zero_flag
);
    localparam ALU_ADD = 3'b000;
    localparam ALU_SUB = 3'b001;
    localparam ALU_AND = 3'b010;
    localparam ALU_OR  = 3'b011;

    always_comb begin
        case (alu_op)
            ALU_ADD : result = a + b;
            ALU_SUB : result = a - b;
            ALU_AND : result = a & b;
            ALU_OR  : result = a | b;
            default : result = 16'b0;
        endcase
    end

    assign zero_flag = (result == 16'b0);
endmodule

// ============================================================
// MODULE 2: CONTROL UNIT
// Decodes opcode → generates all datapath control signals
// ============================================================
module control_unit (
    input  logic [3:0] opcode,
    output logic       reg_write,
    output logic       mem_read,
    output logic       mem_write,
    output logic       mem_to_reg,
    output logic       alu_src,
    output logic       branch,
    output logic [2:0] alu_op
);
    localparam OP_ADD   = 4'b0000;
    localparam OP_SUB   = 4'b0001;
    localparam OP_AND   = 4'b0010;
    localparam OP_OR    = 4'b0011;
    localparam OP_LOAD  = 4'b0100;
    localparam OP_STORE = 4'b0101;
    localparam OP_BEQ   = 4'b0110;
    localparam OP_ADDI  = 4'b0111;

    always_comb begin
        reg_write  = 0; mem_read  = 0; mem_write  = 0;
        mem_to_reg = 0; alu_src   = 0; branch     = 0;
        alu_op     = 3'b000;
        case (opcode)
            OP_ADD  : begin reg_write=1; alu_op=3'b000; end
            OP_SUB  : begin reg_write=1; alu_op=3'b001; end
            OP_AND  : begin reg_write=1; alu_op=3'b010; end
            OP_OR   : begin reg_write=1; alu_op=3'b011; end
            OP_LOAD : begin reg_write=1; mem_read=1; mem_to_reg=1;
                           alu_src=1; alu_op=3'b000; end
            OP_STORE: begin mem_write=1; alu_src=1; alu_op=3'b000; end
            OP_BEQ  : begin branch=1; alu_op=3'b001; end
            OP_ADDI : begin reg_write=1; alu_src=1; alu_op=3'b000; end
            default : begin end
        endcase
    end
endmodule

// ============================================================
// MODULE 3: REGISTER FILE
// 8 x 16-bit, R0 hardwired to zero
// Dual read (async), single write (sync)
// ============================================================
module register_file (
    input  logic        clk, rst,
    input  logic [2:0]  rs_addr, rt_addr,
    output logic [15:0] rs_data, rt_data,
    input  logic [2:0]  rd_addr,
    input  logic [15:0] write_data,
    input  logic        reg_write
);
    logic [15:0] regs [0:7];

    always_ff @(posedge clk) begin
        if (rst) begin : reset_block
            integer i;
            for (i = 0; i < 8; i++) regs[i] <= 0;
        end else if (reg_write && rd_addr != 0) begin
            regs[rd_addr] <= write_data;
        end
    end

    assign rs_data = (rs_addr == 0) ? 16'b0 : regs[rs_addr];
    assign rt_data = (rt_addr == 0) ? 16'b0 : regs[rt_addr];
endmodule

// ============================================================
// MODULE 4: PROGRAM COUNTER
// Extended to support branch prediction speculative fetch.
//
// Priority (highest → lowest):
//   1. rst          → go to 0
//   2. stall        → hold PC
//   3. mispredict   → correct to real branch target
//   4. predict_taken→ speculatively jump to predicted target
//   5. default      → PC + 1
//
// Misprediction MUST have higher priority than prediction so
// a wrong speculative jump is immediately corrected.
// ============================================================
module program_counter (
    input  logic        clk, rst, stall,
    // Original branch-resolution port (kept for compatibility)
    input  logic        branch_taken,
    input  logic [15:0] branch_target,
    // Prediction ports (from branch_predictor, IF stage)
    input  logic        predict_taken,
    input  logic [15:0] predict_target,
    // Misprediction correction (from MEM stage)
    input  logic        mispredict,
    input  logic [15:0] correct_target,
    output logic [15:0] pc_out
);
    always_ff @(posedge clk) begin
        if      (rst)           pc_out <= 16'h0000;
        else if (stall)         pc_out <= pc_out;
        else if (mispredict)    pc_out <= correct_target;
        else if (predict_taken) pc_out <= predict_target;
        else if (branch_taken)  pc_out <= branch_target;
        else                    pc_out <= pc_out + 16'h0001;
    end
endmodule

// ============================================================
// MODULE 5: INSTRUCTION MEMORY (256 x 16-bit ROM)
//
// PROGRAM LISTING:
//  [0]  ADDI R1, R0, 5      R1 = 5
//  [1]  ADDI R2, R0, 10     R2 = 10
//  [2]  ADDI R3, R0, 3      R3 = 3
//  [3]  ADD  R4, R1, R2     R4 = 15  (EX-EX forward R1,R2)
//  [4]  SUB  R5, R4, R3     R5 = 12  (EX/MEM forward R4)
//  [5]  AND  R6, R4, R2     R6 = 10  (MEM/WB forward R4)
//  [6]  OR   R4, R1, R3     R4 = 7
//  [7]  STORE R5, R0+0      MEM[0]=12
//  [8]  STORE R2, R0+1      MEM[1]=10
//  [9]  LOAD  R7, R0+0      R7=12  (creates load-use hazard)
//  [10] ADD  R5, R7, R3     STALL! then R5 = 12+3 = 15
//  [11] LOAD  R6, R0+1      R6=10
//  [12] NOP
//  [13] BEQ  R1, R3, +2     not taken (5 != 3)
//  [14] ADDI R1, R1, -1     R1 = 4
//  [15] BEQ  R2, R6, +1     TAKEN (10 == 10) -> jump to [17]
//  [16] ADDI R7, R0, 99     FLUSHED (never executes)
//  [17] ADDI R4, R0, 42     R4 = 42 (final result marker)
// ============================================================
module instruction_memory (
    input  logic [15:0] addr,
    output logic [15:0] instr
);
    logic [15:0] mem [0:255];

    initial begin : mem_init
        integer idx;
        for (idx = 0; idx < 256; idx++) mem[idx] = 16'h0000;

        // Format helpers:
        //   R-type: {op[3:0], rs[2:0], rt[2:0], rd[2:0], 3'b000}
        //   I-type: {op[3:0], rs[2:0], rd[2:0], imm[5:0]}

        // [0] ADDI R1, R0, 5  -> op=0111 rs=000 rd=001 imm=000101
        mem[0]  = {4'b0111, 3'd0, 3'd1, 6'd5};

        // [1] ADDI R2, R0, 10
        mem[1]  = {4'b0111, 3'd0, 3'd2, 6'd10};

        // [2] ADDI R3, R0, 3
        mem[2]  = {4'b0111, 3'd0, 3'd3, 6'd3};

        // [3] ADD R4, R1, R2  -> op=0000 rs=001 rt=010 rd=100
        mem[3]  = {4'b0000, 3'd1, 3'd2, 3'd4, 3'b000};

        // [4] SUB R5, R4, R3  -> op=0001 rs=100 rt=011 rd=101
        mem[4]  = {4'b0001, 3'd4, 3'd3, 3'd5, 3'b000};

        // [5] AND R6, R4, R2  -> op=0010 rs=100 rt=010 rd=110
        mem[5]  = {4'b0010, 3'd4, 3'd2, 3'd6, 3'b000};

        // [6] OR R4, R1, R3   -> op=0011 rs=001 rt=011 rd=100
        mem[6]  = {4'b0011, 3'd1, 3'd3, 3'd4, 3'b000};

        // [7] STORE R5, R0+0  -> op=0101 rs=000 rd=101(src) imm=0
        mem[7]  = {4'b0101, 3'd0, 3'd5, 6'd0};

        // [8] STORE R2, R0+1
        mem[8]  = {4'b0101, 3'd0, 3'd2, 6'd1};

        // [9] LOAD R7, R0+0   -> op=0100 rs=000 rd=111 imm=0
        mem[9]  = {4'b0100, 3'd0, 3'd7, 6'd0};

        // [10] ADD R5, R7, R3  -> LOAD-USE HAZARD on R7
        mem[10] = {4'b0000, 3'd7, 3'd3, 3'd5, 3'b000};

        // [11] LOAD R6, R0+1
        mem[11] = {4'b0100, 3'd0, 3'd6, 6'd1};

        // [12] NOP
        mem[12] = 16'h0000;

        // [13] BEQ R1, R3, +2  -> not taken (R1=5, R3=3)
        // op=0110 rs=001 rd=011 imm=000010
        mem[13] = {4'b0110, 3'd1, 3'd3, 6'd2};

        // [14] ADDI R1, R1, -1  -> R1 = 5-1 = 4
        // imm = 6'b111111 = -1 signed
        mem[14] = {4'b0111, 3'd1, 3'd1, 6'b111111};

        // [15] BEQ R2, R6, +1  -> TAKEN (R2=10, R6=10)
        // branch target = PC+1+1 = 17
        mem[15] = {4'b0110, 3'd2, 3'd6, 6'd1};

        // [16] ADDI R7, R0, 99  -> FLUSHED when branch above taken
        mem[16] = {4'b0111, 3'd0, 3'd7, 6'd63};  // should not execute

        // [17] ADDI R4, R0, 42  -> R4 = 42 (confirms branch worked)
        mem[17] = {4'b0111, 3'd0, 3'd4, 6'd42};

        // [18+] NOP sled
    end

    assign instr = mem[addr[7:0]];
endmodule

// ============================================================
// MODULE 6: DATA MEMORY (256 x 16-bit SRAM)
// Sync write, async read
// ============================================================
module data_memory (
    input  logic        clk, mem_read, mem_write,
    input  logic [15:0] addr, write_data,
    output logic [15:0] read_data
);
    logic [15:0] mem [0:255];

    initial begin : dmem_init
        integer idx;
        for (idx = 0; idx < 256; idx++) mem[idx] = 0;
    end

    always_ff @(posedge clk)
        if (mem_write) mem[addr[7:0]] <= write_data;

    assign read_data = mem_read ? mem[addr[7:0]] : 16'h0000;
endmodule

// ============================================================
// MODULE 7: SIGN EXTENSION UNIT
// Extends 6-bit signed immediate to 16-bit
// ============================================================
module sign_extend (
    input  logic [5:0]  imm6,
    output logic [15:0] imm16
);
    assign imm16 = {{10{imm6[5]}}, imm6};
endmodule

// ============================================================
// MODULE 8: HAZARD DETECTION UNIT
//
// Detects load-use RAW hazard:
//   IF the EX-stage instruction is a LOAD (mem_read=1)
//   AND its destination register matches rs or rt
//   of the upcoming instruction in ID stage:
//   -> Stall for 1 cycle (freeze PC + IF/ID, insert NOP bubble)
// ============================================================
module hazard_detection_unit (
    input  logic       idex_mem_read,
    input  logic [2:0] idex_rd,
    input  logic [2:0] ifid_rs,
    input  logic [2:0] ifid_rt,
    output logic       stall_pc,
    output logic       stall_ifid,
    output logic       insert_bubble
);
    // Hazard exists only if LOAD and register match
    wire hazard = idex_mem_read &&
                  ((idex_rd == ifid_rs) || (idex_rd == ifid_rt));

    assign stall_pc     = hazard;
    assign stall_ifid   = hazard;
    assign insert_bubble = hazard;
endmodule

// ============================================================
// MODULE 9: FORWARDING UNIT
//
// Resolves RAW hazards WITHOUT stalling by routing pipeline
// register values directly to ALU inputs.
//
// forward_a / forward_b encoding:
//   2'b00 = no forwarding (use register file)
//   2'b01 = forward from MEM/WB stage
//   2'b10 = forward from EX/MEM stage (higher priority)
// ============================================================
module forwarding_unit (
    input  logic [2:0] ex_rs, ex_rt,
    input  logic [2:0] exmem_rd,
    input  logic       exmem_reg_write,
    input  logic [2:0] memwb_rd,
    input  logic       memwb_reg_write,
    output logic [1:0] forward_a,
    output logic [1:0] forward_b
);
    always_comb begin
        forward_a = 2'b00;
        if      (exmem_reg_write && exmem_rd!=0 && exmem_rd==ex_rs) forward_a = 2'b10;
        else if (memwb_reg_write && memwb_rd!=0 && memwb_rd==ex_rs) forward_a = 2'b01;
    end

    always_comb begin
        forward_b = 2'b00;
        if      (exmem_reg_write && exmem_rd!=0 && exmem_rd==ex_rt) forward_b = 2'b10;
        else if (memwb_reg_write && memwb_rd!=0 && memwb_rd==ex_rt) forward_b = 2'b01;
    end
endmodule

// ============================================================
// MODULE 10: IF/ID PIPELINE REGISTER
// Stall = hold; Flush = insert NOP
// flush_mispredict added for branch predictor misprediction
// ============================================================
module ifid_register (
    input  logic        clk, rst, stall, flush,
    input  logic        flush_mispredict,
    input  logic [15:0] pc_plus1_in, instr_in,
    output logic [15:0] pc_plus1_out, instr_out
);
    always_ff @(posedge clk) begin
        if (rst || flush || flush_mispredict) begin
            pc_plus1_out <= 0; instr_out <= 0;
        end else if (!stall) begin
            pc_plus1_out <= pc_plus1_in;
            instr_out    <= instr_in;
        end
        // stall: hold (no update)
    end
endmodule

// ============================================================
// MODULE 11: ID/EX PIPELINE REGISTER
// Flush = insert NOP bubble (all control signals zeroed)
// ============================================================
module idex_register (
    input  logic        clk, rst, flush,
    input  logic        flush_branch,  // flush when branch fires in MEM
    input  logic [15:0] pc_plus1_in, rs_data_in, rt_data_in, imm_in,
    input  logic [2:0]  rs_addr_in, rt_addr_in, rd_addr_in,
    input  logic        reg_write_in, mem_read_in, mem_write_in,
    input  logic        mem_to_reg_in, alu_src_in, branch_in,
    input  logic [2:0]  alu_op_in,

    output logic [15:0] pc_plus1_out, rs_data_out, rt_data_out, imm_out,
    output logic [2:0]  rs_addr_out, rt_addr_out, rd_addr_out,
    output logic        reg_write_out, mem_read_out, mem_write_out,
    output logic        mem_to_reg_out, alu_src_out, branch_out,
    output logic [2:0]  alu_op_out
);
    always_ff @(posedge clk) begin
        if (rst || flush || flush_branch) begin
            pc_plus1_out<=0; rs_data_out<=0; rt_data_out<=0; imm_out<=0;
            rs_addr_out<=0; rt_addr_out<=0; rd_addr_out<=0;
            reg_write_out<=0; mem_read_out<=0; mem_write_out<=0;
            mem_to_reg_out<=0; alu_src_out<=0; branch_out<=0; alu_op_out<=0;
        end else begin
            pc_plus1_out  <= pc_plus1_in;  rs_data_out  <= rs_data_in;
            rt_data_out   <= rt_data_in;   imm_out      <= imm_in;
            rs_addr_out   <= rs_addr_in;   rt_addr_out  <= rt_addr_in;
            rd_addr_out   <= rd_addr_in;
            reg_write_out <= reg_write_in; mem_read_out <= mem_read_in;
            mem_write_out <= mem_write_in; mem_to_reg_out<=mem_to_reg_in;
            alu_src_out   <= alu_src_in;   branch_out   <= branch_in;
            alu_op_out    <= alu_op_in;
        end
    end
endmodule

// ============================================================
// MODULE 12: EX/MEM PIPELINE REGISTER
// ============================================================
module exmem_register (
    input  logic        clk, rst,
    input  logic        flush_branch,  // squash if branch fires same cycle as this loads
    input  logic [15:0] branch_target_in, alu_result_in, rt_data_in,
    input  logic        zero_flag_in,
    input  logic [2:0]  rd_addr_in,
    input  logic        reg_write_in, mem_read_in, mem_write_in,
    input  logic        mem_to_reg_in, branch_in,

    output logic [15:0] branch_target_out, alu_result_out, rt_data_out,
    output logic        zero_flag_out,
    output logic [2:0]  rd_addr_out,
    output logic        reg_write_out, mem_read_out, mem_write_out,
    output logic        mem_to_reg_out, branch_out
);
    always_ff @(posedge clk) begin
        if (rst || flush_branch) begin
            branch_target_out<=0; alu_result_out<=0; rt_data_out<=0;
            zero_flag_out<=0; rd_addr_out<=0;
            reg_write_out<=0; mem_read_out<=0; mem_write_out<=0;
            mem_to_reg_out<=0; branch_out<=0;
        end else begin
            branch_target_out <= branch_target_in;
            alu_result_out    <= alu_result_in;
            rt_data_out       <= rt_data_in;
            zero_flag_out     <= zero_flag_in;
            rd_addr_out       <= rd_addr_in;
            reg_write_out     <= reg_write_in;
            mem_read_out      <= mem_read_in;
            mem_write_out     <= mem_write_in;
            mem_to_reg_out    <= mem_to_reg_in;
            branch_out        <= branch_in;
        end
    end
endmodule

// ============================================================
// MODULE 13: MEM/WB PIPELINE REGISTER
// ============================================================
module memwb_register (
    input  logic        clk, rst,
    input  logic [15:0] mem_data_in, alu_result_in,
    input  logic [2:0]  rd_addr_in,
    input  logic        reg_write_in, mem_to_reg_in,

    output logic [15:0] mem_data_out, alu_result_out,
    output logic [2:0]  rd_addr_out,
    output logic        reg_write_out, mem_to_reg_out
);
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_data_out<=0; alu_result_out<=0; rd_addr_out<=0;
            reg_write_out<=0; mem_to_reg_out<=0;
        end else begin
            mem_data_out   <= mem_data_in;
            alu_result_out <= alu_result_in;
            rd_addr_out    <= rd_addr_in;
            reg_write_out  <= reg_write_in;
            mem_to_reg_out <= mem_to_reg_in;
        end
    end
endmodule

// ============================================================
// MODULE 14: CPU TOP — Integrates all stages
// ============================================================
module cpu_top (
    input  logic clk, rst,
    // Predictor select: 0=no predictor, 1=2-bit SAT, 2=Perceptron
    input  logic [1:0]  predictor_sel,
    // Debug/observation outputs for testbench
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_instr,
    output logic [15:0] dbg_alu_result,
    output logic [2:0]  dbg_wb_rd,
    output logic [15:0] dbg_wb_data,
    output logic        dbg_wb_write,
    output logic        dbg_stall,
    output logic        dbg_branch_taken,
    output logic [1:0]  dbg_forward_a,
    output logic [1:0]  dbg_forward_b,
    // Predictor debug outputs
    output logic        dbg_predict_taken,
    output logic        dbg_mispredict,
    output logic [15:0] dbg_ghr
);

    // ---- IF Stage Wires ----
    logic [15:0] if_pc, if_pc_plus1, if_instr;

    // ---- IF/ID Register Outputs ----
    logic [15:0] ifid_pc_plus1, ifid_instr;

    // ---- ID Stage Wires ----
    logic [3:0]  id_opcode;
    logic [2:0]  id_rs, id_rt, id_rd_rtype;
    logic [5:0]  id_imm6;
    logic [15:0] id_imm16;
    logic [15:0] id_rs_data, id_rt_data;
    logic        id_reg_write, id_mem_read, id_mem_write;
    logic        id_mem_to_reg, id_alu_src, id_branch;
    logic [2:0]  id_alu_op;

    // ---- ID/EX Register Outputs ----
    logic [15:0] idex_pc_plus1, idex_rs_data, idex_rt_data, idex_imm;
    logic [2:0]  idex_rs, idex_rt, idex_rd;
    logic        idex_reg_write, idex_mem_read, idex_mem_write;
    logic        idex_mem_to_reg, idex_alu_src, idex_branch;
    logic [2:0]  idex_alu_op;

    // ---- EX Stage Wires ----
    logic [15:0] ex_alu_a, ex_alu_b_reg, ex_alu_b_final;
    logic [15:0] ex_alu_result;
    logic        ex_zero;
    logic [15:0] ex_branch_target;
    logic [1:0]  ex_fwd_a, ex_fwd_b;

    // ---- EX/MEM Register Outputs ----
    logic [15:0] exmem_branch_target, exmem_alu_result, exmem_rt_data;
    logic        exmem_zero;
    logic [2:0]  exmem_rd;
    logic        exmem_reg_write, exmem_mem_read, exmem_mem_write;
    logic        exmem_mem_to_reg, exmem_branch;

    // ---- MEM Stage Wires ----
    logic [15:0] mem_read_data;
    logic        branch_taken;

    // ---- MEM/WB Register Outputs ----
    logic [15:0] memwb_mem_data, memwb_alu_result;
    logic [2:0]  memwb_rd;
    logic        memwb_reg_write, memwb_mem_to_reg;

    // ---- WB Stage ----
    logic [15:0] wb_result;

    // ---- Hazard Signals ----
    logic stall_pc, stall_ifid, insert_bubble;

    // ---- Branch Predictor Signals ----
    // Two predictor instances run in parallel; predictor_sel muxes outputs
    logic        sat_predict, perc_predict;
    logic        sat_mispredict, perc_mispredict;
    logic [15:0] sat_ghr, perc_ghr;

    logic        bp_predict_taken;   // active predictor's output
    logic        bp_mispredict;      // misprediction flag (MEM stage)
    logic [15:0] bp_ghr;             // active GHR for debug

    // Predicted branch target = PC + sign_extended_imm
    // Since we don't have the immediate in IF, we use a 1-cycle lookahead:
    // the branch target is computed in EX but we need it at IF.
    // Solution: store the LAST computed branch target as a hint.
    // For a loop branch, the first iteration pays 1 penalty; subsequent
    // iterations are predicted correctly using the stored target.
    // Branch Target Buffer: one target per predictor table entry
    // Indexed by pc[TABLE_BITS-1:0] (same index as predictor weights/counters)
    // Populated when a branch resolves in MEM; used for speculative jump in IF
    localparam BTB_SIZE = 16;  // 2^TABLE_BITS
    logic [15:0] btb_target [0:BTB_SIZE-1];  // predicted target per PC
    logic        btb_valid  [0:BTB_SIZE-1];  // valid flag per entry

    wire [3:0] btb_fetch_idx = if_pc[3:0];          // IF stage lookup index
    wire [3:0] btb_train_idx = exmem_pc[3:0];       // MEM stage update index

    // BTB update: whenever a branch resolves, store its target
    always_ff @(posedge clk) begin : btb_update
        integer bi;
        if (rst) begin
            for (bi = 0; bi < BTB_SIZE; bi++) begin
                btb_target[bi] <= 16'h0;
                btb_valid[bi]  <= 1'b0;
            end
        end else if (exmem_branch) begin
            btb_target[btb_train_idx] <= exmem_branch_target;
            btb_valid[btb_train_idx]  <= 1'b1;
        end
    end

    // PC pipeline: we need the PC of the branch when it entered IF
    // so we can train the correct predictor table entry in MEM.
    // Branch travels: IF(cycle N) → ID(N+1) → EX(N+2) → MEM(N+3)
    // We pipe IF-PC through 3 stages alongside the instruction.
    logic [15:0] ifid_pc;    // PC registered into IF/ID
    logic [15:0] idex_pc;    // PC registered into ID/EX
    logic [15:0] exmem_pc;   // PC registered into EX/MEM (= train PC)

    // Prediction made at IF: must pipe alongside instruction to MEM
    // so we can detect misprediction when branch resolves.
    logic        ifid_pred;   // prediction travelling through pipeline
    logic        idex_pred;
    logic        exmem_pred;  // prediction that was made for this branch

    // Misprediction = branch resolved in MEM with different outcome
    logic        mispredict_en;  // flush + correct PC this cycle

    // ==========================================================
    // IF STAGE
    // ==========================================================
    assign if_pc_plus1 = if_pc + 16'h1;
    assign branch_taken = exmem_branch && exmem_zero;

    // Misprediction: branch resolved (train_en) AND
    // actual outcome differs from what we predicted.
    // Guard with predictor_sel != 0 so baseline mode is untouched.
    assign mispredict_en = (predictor_sel != 2'd0) &&
                           exmem_branch &&
                           (branch_taken != exmem_pred);

    // Active predictor output mux
    always_comb begin
        case (predictor_sel)
            2'd1:    begin bp_predict_taken = sat_predict;
                           bp_mispredict   = sat_mispredict;
                           bp_ghr          = sat_ghr; end
            2'd2:    begin bp_predict_taken = perc_predict;
                           bp_mispredict   = perc_mispredict;
                           bp_ghr          = perc_ghr; end
            default: begin bp_predict_taken = 1'b0;
                           bp_mispredict   = 1'b0;
                           bp_ghr          = 16'b0; end
        endcase
    end

    // Predicted target register: updated whenever EX computes a branch target.
    // On the FIRST execution of a branch, we don't have a target yet (uses PC+1).
    // On subsequent executions the stored target is used — correct for loops.
    // BTB lookup: predict target for current fetch PC

    // PC pipeline registers: carry IF-stage PC to MEM stage for training.
    // Must respect stall so the PC that trained is the one that was actually
    // in each stage — mirrors how ifid/idex/exmem registers behave.
    always_ff @(posedge clk) begin
        if (rst) begin
            ifid_pc  <= 0;
            idex_pc  <= 0;
            exmem_pc <= 0;
        end else begin
            if (!stall_ifid) ifid_pc <= if_pc;
            idex_pc  <= ifid_pc;
            exmem_pc <= idex_pc;
        end
    end

    // Prediction pipeline registers: carry prediction made at IF to MEM
    // to compare against actual branch outcome for misprediction detect.
    always_ff @(posedge clk) begin
        if (rst) begin
            ifid_pred  <= 0;
            idex_pred  <= 0;
            exmem_pred <= 0;
        end else begin
            ifid_pred  <= bp_predict_taken;
            idex_pred  <= ifid_pred;
            exmem_pred <= idex_pred;
        end
    end

    // 2-Bit Saturating Counter predictor instance
    branch_predictor #(
        .PREDICTOR_TYPE(0),
        .TABLE_BITS(4),
        .HIST_LEN(4),
        .WEIGHT_BITS(5),
        .THRESHOLD(6)
    ) u_bp_sat (
        .clk(clk), .rst(rst),
        .pc_fetch(if_pc),
        .predict_taken(sat_predict),
        .train_en(exmem_branch),
        .pc_train(exmem_pc),
        .actual_taken(branch_taken),
        .pred_was_taken(exmem_pred),
        .mispredict(sat_mispredict),
        .dbg_ghr(sat_ghr)
    );

    // Perceptron predictor instance
    branch_predictor #(
        .PREDICTOR_TYPE(1),
        .TABLE_BITS(4),
        .HIST_LEN(4),
        .WEIGHT_BITS(5),
        .THRESHOLD(6)
    ) u_bp_perc (
        .clk(clk), .rst(rst),
        .pc_fetch(if_pc),
        .predict_taken(perc_predict),
        .train_en(exmem_branch),
        .pc_train(exmem_pc),
        .actual_taken(branch_taken),
        .pred_was_taken(exmem_pred),
        .mispredict(perc_mispredict),
        .dbg_ghr(perc_ghr)
    );

    program_counter u_pc (
        .clk(clk), .rst(rst),
        .stall(stall_pc),
        // branch_taken always corrects PC (works in all modes)
        .branch_taken(branch_taken & (predictor_sel == 2'd0)),
        .branch_target(exmem_branch_target),
        // Speculative prediction: only when predictor active
        .predict_taken(bp_predict_taken & (predictor_sel != 2'd0)
                       & (if_instr[15:12] == 4'b0110)        // only on BEQ
                       & btb_valid[btb_fetch_idx]),           // only when BTB has target
        .predict_target(btb_target[btb_fetch_idx]),           // per-PC target from BTB
        // Misprediction correction: overrides speculative fetch
        .mispredict(mispredict_en),
        .correct_target(exmem_branch_target),
        .pc_out(if_pc)
    );

    instruction_memory u_imem (
        .addr(if_pc), .instr(if_instr)
    );

    ifid_register u_ifid (
        .clk(clk), .rst(rst),
        .stall(stall_ifid),
        .flush(branch_taken & (predictor_sel == 0)), // only flush if no predictor
        .flush_mispredict(mispredict_en & (predictor_sel != 0)),
        .pc_plus1_in(if_pc_plus1), .instr_in(if_instr),
        .pc_plus1_out(ifid_pc_plus1), .instr_out(ifid_instr)
    );

    // ==========================================================
    // ID STAGE
    // ==========================================================
    // Field extraction
    assign id_opcode   = ifid_instr[15:12];
    assign id_rs       = ifid_instr[11:9];
    assign id_rt       = ifid_instr[8:6];
    assign id_rd_rtype = ifid_instr[5:3];
    assign id_imm6     = ifid_instr[5:0];

    control_unit u_ctrl (
        .opcode(id_opcode),
        .reg_write(id_reg_write), .mem_read(id_mem_read),
        .mem_write(id_mem_write), .mem_to_reg(id_mem_to_reg),
        .alu_src(id_alu_src), .branch(id_branch), .alu_op(id_alu_op)
    );

    // Register File (WB port also connected here)
    register_file u_rf (
        .clk(clk), .rst(rst),
        .rs_addr(id_rs), .rt_addr(id_rt),
        .rs_data(id_rs_data), .rt_data(id_rt_data),
        .rd_addr(memwb_rd), .write_data(wb_result),
        .reg_write(memwb_reg_write)
    );

    sign_extend u_sext (.imm6(id_imm6), .imm16(id_imm16));

    hazard_detection_unit u_hdu (
        .idex_mem_read(idex_mem_read), .idex_rd(idex_rd),
        .ifid_rs(id_rs), .ifid_rt(id_rt),
        .stall_pc(stall_pc), .stall_ifid(stall_ifid),
        .insert_bubble(insert_bubble)
    );

    idex_register u_idex (
        .clk(clk), .rst(rst), .flush(insert_bubble),
        // flush_branch logic:
        //   predictor_sel=0 : flush on every taken branch (flush-on-taken)
        //   predictor_sel!=0: flush ONLY on misprediction
        //     A correct prediction means the pipeline is already on the right
        //     path — flushing would squash valid speculative work.
        .flush_branch((predictor_sel == 2'd0) ? branch_taken : mispredict_en),
        .pc_plus1_in(ifid_pc_plus1),
        .rs_data_in(id_rs_data), .rt_data_in(id_rt_data),
        .imm_in(id_imm16),
        .rs_addr_in(id_rs), .rt_addr_in(id_rt),
        // I-type: rd is in [8:6] (id_rt); R-type: rd in [5:3]
        .rd_addr_in(id_alu_src ? id_rt : id_rd_rtype),
        .reg_write_in(id_reg_write), .mem_read_in(id_mem_read),
        .mem_write_in(id_mem_write), .mem_to_reg_in(id_mem_to_reg),
        .alu_src_in(id_alu_src), .branch_in(id_branch),
        .alu_op_in(id_alu_op),
        .pc_plus1_out(idex_pc_plus1),
        .rs_data_out(idex_rs_data), .rt_data_out(idex_rt_data),
        .imm_out(idex_imm),
        .rs_addr_out(idex_rs), .rt_addr_out(idex_rt),
        .rd_addr_out(idex_rd),
        .reg_write_out(idex_reg_write), .mem_read_out(idex_mem_read),
        .mem_write_out(idex_mem_write), .mem_to_reg_out(idex_mem_to_reg),
        .alu_src_out(idex_alu_src), .branch_out(idex_branch),
        .alu_op_out(idex_alu_op)
    );

    // ==========================================================
    // EX STAGE
    // ==========================================================
    forwarding_unit u_fwd (
        .ex_rs(idex_rs), .ex_rt(idex_rt),
        .exmem_rd(exmem_rd), .exmem_reg_write(exmem_reg_write),
        .memwb_rd(memwb_rd), .memwb_reg_write(memwb_reg_write),
        .forward_a(ex_fwd_a), .forward_b(ex_fwd_b)
    );

    // ALU Input A Mux
    always_comb begin
        case (ex_fwd_a)
            2'b10:   ex_alu_a = exmem_alu_result;
            2'b01:   ex_alu_a = wb_result;
            default: ex_alu_a = idex_rs_data;
        endcase
    end

    // ALU Input B Mux (before ALU src mux)
    always_comb begin
        case (ex_fwd_b)
            2'b10:   ex_alu_b_reg = exmem_alu_result;
            2'b01:   ex_alu_b_reg = wb_result;
            default: ex_alu_b_reg = idex_rt_data;
        endcase
    end

    // ALU Source Mux: immediate or forwarded register
    assign ex_alu_b_final = idex_alu_src ? idex_imm : ex_alu_b_reg;

    alu u_alu (
        .a(ex_alu_a), .b(ex_alu_b_final),
        .alu_op(idex_alu_op),
        .result(ex_alu_result), .zero_flag(ex_zero)
    );

    // Branch target: PC+1 + sign_ext_imm
    assign ex_branch_target = idex_pc_plus1 + idex_imm;

    exmem_register u_exmem (
        .clk(clk), .rst(rst),
        // Flush when a branch fires: squashes the instruction that escaped
        // ID/EX at the same clock edge (it was captured into EX/MEM before
        // the idex flush could stop it).
        .flush_branch((predictor_sel == 2'd0) ? branch_taken : mispredict_en),
        .branch_target_in(ex_branch_target),
        .alu_result_in(ex_alu_result),
        .rt_data_in(ex_alu_b_reg),
        .zero_flag_in(ex_zero),
        .rd_addr_in(idex_rd),
        .reg_write_in(idex_reg_write), .mem_read_in(idex_mem_read),
        .mem_write_in(idex_mem_write), .mem_to_reg_in(idex_mem_to_reg),
        .branch_in(idex_branch),
        .branch_target_out(exmem_branch_target),
        .alu_result_out(exmem_alu_result),
        .rt_data_out(exmem_rt_data),
        .zero_flag_out(exmem_zero),
        .rd_addr_out(exmem_rd),
        .reg_write_out(exmem_reg_write), .mem_read_out(exmem_mem_read),
        .mem_write_out(exmem_mem_write), .mem_to_reg_out(exmem_mem_to_reg),
        .branch_out(exmem_branch)
    );

    // ==========================================================
    // MEM STAGE
    // ==========================================================
    data_memory u_dmem (
        .clk(clk),
        .mem_read(exmem_mem_read), .mem_write(exmem_mem_write),
        .addr(exmem_alu_result), .write_data(exmem_rt_data),
        .read_data(mem_read_data)
    );

    memwb_register u_memwb (
        .clk(clk), .rst(rst),
        .mem_data_in(mem_read_data), .alu_result_in(exmem_alu_result),
        .rd_addr_in(exmem_rd),
        .reg_write_in(exmem_reg_write), .mem_to_reg_in(exmem_mem_to_reg),
        .mem_data_out(memwb_mem_data), .alu_result_out(memwb_alu_result),
        .rd_addr_out(memwb_rd),
        .reg_write_out(memwb_reg_write), .mem_to_reg_out(memwb_mem_to_reg)
    );

    // ==========================================================
    // WB STAGE
    // ==========================================================
    assign wb_result = memwb_mem_to_reg ? memwb_mem_data : memwb_alu_result;

    // ==========================================================
    // DEBUG OUTPUTS
    // ==========================================================
    assign dbg_pc           = if_pc;
    assign dbg_instr        = ifid_instr;
    assign dbg_alu_result   = ex_alu_result;
    assign dbg_wb_rd        = memwb_rd;
    assign dbg_wb_data      = wb_result;
    assign dbg_wb_write     = memwb_reg_write;
    assign dbg_stall        = stall_pc;
    assign dbg_branch_taken = branch_taken;
    assign dbg_forward_a    = ex_fwd_a;
    assign dbg_forward_b    = ex_fwd_b;
    assign dbg_predict_taken = bp_predict_taken;
    assign dbg_mispredict    = mispredict_en & (predictor_sel != 0);
    assign dbg_ghr           = bp_ghr;

endmodule
