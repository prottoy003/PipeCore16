// ============================================================
// MODULE: control_unit.sv
// DESC:   Main Control Unit — decodes opcode and drives
//         all datapath control signals.
//
// Opcode Encoding (bits [15:12] of instruction):
//   4'b0000 -> ADD   (R-type)
//   4'b0001 -> SUB   (R-type)
//   4'b0010 -> AND   (R-type)
//   4'b0011 -> OR    (R-type)
//   4'b0100 -> LOAD  (I-type: rd = MEM[rs + imm])
//   4'b0101 -> STORE (I-type: MEM[rs + imm] = rt)
//   4'b0110 -> BEQ   (I-type: branch if rs == rt)
//   4'b0111 -> ADDI  (I-type: rd = rs + imm)
//
// Control Signals:
//   reg_write   : 1 = write result to register file
//   mem_read    : 1 = read from data memory
//   mem_write   : 1 = write to data memory
//   mem_to_reg  : 1 = write memory data to reg (0 = ALU result)
//   alu_src     : 1 = second ALU operand is immediate (0 = register)
//   branch      : 1 = instruction is a branch
//   alu_op[2:0] : selects ALU operation
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

    // Opcode definitions
    localparam OP_ADD   = 4'b0000;
    localparam OP_SUB   = 4'b0001;
    localparam OP_AND   = 4'b0010;
    localparam OP_OR    = 4'b0011;
    localparam OP_LOAD  = 4'b0100;
    localparam OP_STORE = 4'b0101;
    localparam OP_BEQ   = 4'b0110;
    localparam OP_ADDI  = 4'b0111;

    always_comb begin
        // Safe defaults: NOP behaviour
        reg_write  = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        mem_to_reg = 1'b0;
        alu_src    = 1'b0;
        branch     = 1'b0;
        alu_op     = 3'b000;  // ADD by default

        case (opcode)
            OP_ADD: begin
                // rd = rs + rt
                reg_write = 1'b1;
                alu_op    = 3'b000; // ADD
            end

            OP_SUB: begin
                // rd = rs - rt
                reg_write = 1'b1;
                alu_op    = 3'b001; // SUB
            end

            OP_AND: begin
                // rd = rs & rt
                reg_write = 1'b1;
                alu_op    = 3'b010; // AND
            end

            OP_OR: begin
                // rd = rs | rt
                reg_write = 1'b1;
                alu_op    = 3'b011; // OR
            end

            OP_LOAD: begin
                // rd = MEM[rs + imm]
                // ALU computes address = rs + imm
                reg_write  = 1'b1;
                mem_read   = 1'b1;
                mem_to_reg = 1'b1;  // result comes from memory
                alu_src    = 1'b1;  // second operand is immediate
                alu_op     = 3'b000; // ADD (address calculation)
            end

            OP_STORE: begin
                // MEM[rs + imm] = rt
                mem_write = 1'b1;
                alu_src   = 1'b1;  // second operand is immediate
                alu_op    = 3'b000; // ADD (address calculation)
            end

            OP_BEQ: begin
                // branch if rs == rt (use SUB and check zero_flag)
                branch = 1'b1;
                alu_op = 3'b001; // SUB (to detect equality via zero)
            end

            OP_ADDI: begin
                // rd = rs + imm
                reg_write = 1'b1;
                alu_src   = 1'b1;  // second operand is immediate
                alu_op    = 3'b000; // ADD
            end

            default: begin
                // NOP — all signals stay at defaults
            end
        endcase
    end

endmodule
