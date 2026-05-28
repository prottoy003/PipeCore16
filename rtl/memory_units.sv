// ============================================================
// MODULE: program_counter.sv
// DESC:   16-bit Program Counter
//
// - Holds the address of the current instruction being fetched
// - Updates on every rising clock edge unless stalled
// - On branch taken: loads branch target address
// - On stall: holds current value (load-use hazard)
// - On reset: goes to 0x0000
// ============================================================

module program_counter (
    input  logic        clk,
    input  logic        rst,

    input  logic        stall,          // Freeze PC (load-use hazard)
    input  logic        branch_taken,   // Override PC with branch target
    input  logic [15:0] branch_target,  // Branch destination address

    output logic [15:0] pc_out          // Current PC value
);

    always_ff @(posedge clk) begin
        if (rst) begin
            pc_out <= 16'h0000;
        end else if (stall) begin
            // Hold: do not advance (pipeline stall)
            pc_out <= pc_out;
        end else if (branch_taken) begin
            // Jump to branch target
            pc_out <= branch_target;
        end else begin
            // Normal advance: next sequential instruction (word-addressed)
            pc_out <= pc_out + 16'h0001;
        end
    end

endmodule


// ============================================================
// MODULE: instruction_memory.sv
// DESC:   256-word x 16-bit ROM-style Instruction Memory
//
// - Word addressed (each address = one 16-bit instruction)
// - Combinational read (async): instruction available same cycle
// - Preloaded with a sample program demonstrating:
//     * Arithmetic (ADD, SUB, ADDI)
//     * Logic (AND, OR)
//     * Memory (LOAD, STORE)
//     * Branching (BEQ)
//     * Hazard scenarios (load-use, RAW forwarding)
//
// INSTRUCTION ENCODING (16-bit):
//   R-Type: [15:12]=opcode [11:9]=rs [8:6]=rt [5:3]=rd [2:0]=000
//   I-Type: [15:12]=opcode [11:9]=rs [8:6]=rd [5:0]=imm6
//
// OPCODE TABLE:
//   0000=ADD  0001=SUB  0010=AND  0011=OR
//   0100=LOAD 0101=STORE 0110=BEQ 0111=ADDI
// ============================================================

module instruction_memory (
    input  logic [15:0] addr,       // Word address (= PC)
    output logic [15:0] instr       // 16-bit instruction out
);

    logic [15:0] mem [0:255];

    // --------------------------------------------------------
    // Helper macro for encoding instructions
    // R-Type: opcode[3:0], rs[2:0], rt[2:0], rd[2:0], 000
    // I-Type: opcode[3:0], rs[2:0], rd[2:0], imm[5:0]
    // --------------------------------------------------------

    initial begin
        // Initialize all to NOP (zero word)
        integer idx;
        for (idx = 0; idx < 256; idx++) begin
            mem[idx] = 16'h0000;  // NOP (ADD R0,R0,R0)
        end

        // ====================================================
        // SAMPLE PROGRAM — demonstrates all instruction types,
        // forwarding paths, and a load-use stall.
        //
        // Register alias convention used here:
        //   R1 = scratch / loop counter
        //   R2 = value A
        //   R3 = value B
        //   R4 = result
        //   R5 = memory data
        //   R6 = temp
        //   R7 = branch comparison target
        // ====================================================

        // --- Instruction 0 ---
        // ADDI R1, R0, 5    -> R1 = 0 + 5 = 5
        // opcode=0111, rs=000, rd=001, imm=000101
        // [15:12]=0111 [11:9]=000 [8:6]=001 [5:0]=000101
        mem[0] = {4'b0111, 3'b000, 3'b001, 6'b000101};  // ADDI R1, R0, 5

        // --- Instruction 1 ---
        // ADDI R2, R0, 10   -> R2 = 10
        // opcode=0111, rs=000, rd=010, imm=001010
        mem[1] = {4'b0111, 3'b000, 3'b010, 6'b001010};  // ADDI R2, R0, 10

        // --- Instruction 2 ---
        // ADDI R3, R0, 3    -> R3 = 3
        mem[2] = {4'b0111, 3'b000, 3'b011, 6'b000011};  // ADDI R3, R0, 3

        // --- Instruction 3 ---
        // ADD R4, R1, R2    -> R4 = R1 + R2 = 15
        // Demonstrates EX-EX forwarding from instr 0 & 1
        // opcode=0000, rs=001, rt=010, rd=100, funct=000
        mem[3] = {4'b0000, 3'b001, 3'b010, 3'b100, 3'b000};  // ADD R4,R1,R2

        // --- Instruction 4 ---
        // SUB R5, R4, R3    -> R5 = 15 - 3 = 12
        // R4 forwarded from EX/MEM (just written by instr 3)
        mem[4] = {4'b0001, 3'b100, 3'b011, 3'b101, 3'b000};  // SUB R5,R4,R3

        // --- Instruction 5 ---
        // AND R6, R4, R2    -> R6 = 15 & 10 = 10
        // R4 forwarded from MEM/WB
        mem[5] = {4'b0010, 3'b100, 3'b010, 3'b110, 3'b000};  // AND R6,R4,R2

        // --- Instruction 6 ---
        // OR  R4, R1, R3    -> R4 = 5 | 3 = 7
        mem[6] = {4'b0011, 3'b001, 3'b011, 3'b100, 3'b000};  // OR R4,R1,R3

        // --- Instruction 7 ---
        // STORE R5, R0, 0   -> MEM[0+0] = R5 = 12
        // opcode=0101, rs=000, rd(=rt)=101, imm=000000
        // For STORE: rs=base, rd field holds the source reg (rt)
        mem[7] = {4'b0101, 3'b000, 3'b101, 6'b000000};  // STORE R5, MEM[R0+0]

        // --- Instruction 8 ---
        // STORE R2, R0, 1   -> MEM[0+1] = R2 = 10
        mem[8] = {4'b0101, 3'b000, 3'b010, 6'b000001};  // STORE R2, MEM[R0+1]

        // --- Instruction 9 ---
        // LOAD R7, R0, 0    -> R7 = MEM[0] = 12
        // This creates a LOAD-USE hazard if instr 10 uses R7
        mem[9] = {4'b0100, 3'b000, 3'b111, 6'b000000};  // LOAD R7, MEM[R0+0]

        // --- Instruction 10 ---
        // ADD R5, R7, R3    -> R5 = 12 + 3 = 15
        // LOAD-USE HAZARD: R7 not ready yet -> pipeline STALLS 1 cycle
        mem[10] = {4'b0000, 3'b111, 3'b011, 3'b101, 3'b000}; // ADD R5,R7,R3

        // --- Instruction 11 ---
        // LOAD R6, R0, 1    -> R6 = MEM[1] = 10
        mem[11] = {4'b0100, 3'b000, 3'b110, 6'b000001};  // LOAD R6, MEM[R0+1]

        // --- Instruction 12 ---
        // NOP (bubble) — safe instruction to avoid hazard for demonstration
        mem[12] = 16'h0000;  // NOP

        // --- Instruction 13 ---
        // BEQ R1, R3, +2   -> branch to PC+1+2 if R1==R3 (5!=3, not taken)
        // opcode=0110, rs=001, rd=011, imm=000010
        mem[13] = {4'b0110, 3'b001, 3'b011, 6'b000010};  // BEQ R1,R3,+2

        // --- Instruction 14 ---
        // ADDI R1, R1, -1   -> R1 = R1 - 1 = 4  (imm = 6'b111111 = -1 signed)
        mem[14] = {4'b0111, 3'b001, 3'b001, 6'b111111};  // ADDI R1,R1,-1

        // --- Instruction 15 ---
        // BEQ R2, R6, +1   -> branch if R2==R6 (10==10 -> TAKEN)
        // Branch target = PC+1+1 = 17
        mem[15] = {4'b0110, 3'b010, 3'b110, 6'b000001};  // BEQ R2,R6,+1

        // --- Instruction 16 ---
        // This instruction will be FLUSHED when branch above is taken
        // ADDI R7, R0, 99  -> should NOT execute
        mem[16] = {4'b0111, 3'b000, 3'b111, 6'b100011};  // (flushed)

        // --- Instruction 17 ---
        // ADDI R4, R0, 42   -> R4 = 42 (final result marker)
        mem[17] = {4'b0111, 3'b000, 3'b100, 6'b101010};  // ADDI R4,R0,42

        // --- Instructions 18+ ---
        // NOP sled — simulation runs to completion
    end

    // Combinational (async) read
    assign instr = mem[addr[7:0]];  // 8-bit word address -> 256 words

endmodule


// ============================================================
// MODULE: data_memory.sv
// DESC:   256-word x 16-bit Data Memory (SRAM-style)
//
// - Synchronous write (rising edge)
// - Combinational read (async) for simplicity
//   (In real ASIC this would be synchronous, but async
//    keeps the pipeline timing simple for this design)
// ============================================================

module data_memory (
    input  logic        clk,
    input  logic        mem_read,
    input  logic        mem_write,
    input  logic [15:0] addr,        // byte/word address (word-addressed here)
    input  logic [15:0] write_data,

    output logic [15:0] read_data
);

    logic [15:0] mem [0:255];

    // Initialize to zero
    initial begin
        integer idx;
        for (idx = 0; idx < 256; idx++) begin
            mem[idx] = 16'h0000;
        end
    end

    // Synchronous write
    always_ff @(posedge clk) begin
        if (mem_write) begin
            mem[addr[7:0]] <= write_data;
        end
    end

    // Combinational (async) read
    assign read_data = mem_read ? mem[addr[7:0]] : 16'h0000;

endmodule


// ============================================================
// MODULE: sign_extend.sv
// DESC:   Sign-Extension Unit
//
// Extends a 6-bit immediate (from I-type instructions)
// to a full 16-bit signed value.
//
// Example:
//   6'b111111 = -1  ->  16'b1111111111111111
//   6'b000101 = +5  ->  16'b0000000000000101
// ============================================================

module sign_extend (
    input  logic [5:0]  imm6,
    output logic [15:0] imm16
);

    // SystemVerilog sign-extension: replicate the MSB (bit 5)
    assign imm16 = {{10{imm6[5]}}, imm6};

endmodule
