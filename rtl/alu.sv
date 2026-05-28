// ============================================================
// MODULE: alu.sv
// DESC:   16-bit Arithmetic Logic Unit
//
// Performs arithmetic and logic operations based on ALUOp:
//   3'b000 -> ADD  (also used for ADDI, LOAD, STORE address)
//   3'b001 -> SUB  (also used for BEQ comparison)
//   3'b010 -> AND
//   3'b011 -> OR
//
// Outputs:
//   result     : 16-bit computed value
//   zero_flag  : 1 if result == 0 (used by BEQ)
// ============================================================

module alu (
    input  logic [15:0] a,          // First operand (rs)
    input  logic [15:0] b,          // Second operand (rt or sign-ext imm)
    input  logic [2:0]  alu_op,     // ALU operation select

    output logic [15:0] result,     // ALU result
    output logic        zero_flag   // High when result == 0
);

    // ALU operation encoding
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

    // zero_flag is used by BEQ: if rs - rt == 0, they are equal
    assign zero_flag = (result == 16'b0);

endmodule
