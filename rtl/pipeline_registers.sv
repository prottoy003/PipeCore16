// ============================================================
// MODULE: pipeline_registers.sv
// DESC:   All four inter-stage pipeline registers
//
// Each register separates two consecutive pipeline stages.
// They capture all signals needed by downstream stages.
//
// PIPELINE REGISTER CONTENTS:
// ============================
//
// IF/ID  — holds: {pc_plus1, instruction}
//
// ID/EX  — holds: {pc_plus1, rs_data, rt_data, sign_ext_imm,
//                  rs_addr, rt_addr, rd_addr,
//                  reg_write, mem_read, mem_write,
//                  mem_to_reg, alu_src, branch, alu_op}
//
// EX/MEM — holds: {branch_target, zero_flag, alu_result,
//                  rt_data (for STORE), rd_addr,
//                  reg_write, mem_read, mem_write,
//                  mem_to_reg, branch}
//
// MEM/WB — holds: {mem_data, alu_result, rd_addr,
//                  reg_write, mem_to_reg}
// ============================================================

// ============================================================
// IF/ID Pipeline Register
// Captures: Fetched instruction + PC+1 for branch calculation
// Reset/Flush: Sets to NOP (zero instruction)
// Stall:       Holds current value (does not advance)
// ============================================================
module ifid_register (
    input  logic        clk,
    input  logic        rst,
    input  logic        stall,      // Hold current value (load-use hazard)
    input  logic        flush,      // Insert NOP bubble (branch flush)

    // Inputs from IF stage
    input  logic [15:0] pc_plus1_in,
    input  logic [15:0] instr_in,

    // Outputs to ID stage
    output logic [15:0] pc_plus1_out,
    output logic [15:0] instr_out
);

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            // Flush: replace with NOP (all zeros = ADD R0,R0,R0)
            pc_plus1_out <= 16'h0000;
            instr_out    <= 16'h0000;
        end else if (stall) begin
            // Stall: hold current values, do not update
            pc_plus1_out <= pc_plus1_out;
            instr_out    <= instr_out;
        end else begin
            // Normal: latch incoming values
            pc_plus1_out <= pc_plus1_in;
            instr_out    <= instr_in;
        end
    end

endmodule


// ============================================================
// ID/EX Pipeline Register
// Captures: All decoded values + control signals needed by EX
// Flush: Converts to NOP bubble (stall inserted by hazard unit)
// ============================================================
module idex_register (
    input  logic        clk,
    input  logic        rst,
    input  logic        flush,      // Insert NOP bubble

    // Inputs from ID stage
    input  logic [15:0] pc_plus1_in,
    input  logic [15:0] rs_data_in,
    input  logic [15:0] rt_data_in,
    input  logic [15:0] imm_in,
    input  logic [2:0]  rs_addr_in,
    input  logic [2:0]  rt_addr_in,
    input  logic [2:0]  rd_addr_in,

    // Control signals from ID
    input  logic        reg_write_in,
    input  logic        mem_read_in,
    input  logic        mem_write_in,
    input  logic        mem_to_reg_in,
    input  logic        alu_src_in,
    input  logic        branch_in,
    input  logic [2:0]  alu_op_in,

    // Outputs to EX stage
    output logic [15:0] pc_plus1_out,
    output logic [15:0] rs_data_out,
    output logic [15:0] rt_data_out,
    output logic [15:0] imm_out,
    output logic [2:0]  rs_addr_out,
    output logic [2:0]  rt_addr_out,
    output logic [2:0]  rd_addr_out,

    // Control signals to EX
    output logic        reg_write_out,
    output logic        mem_read_out,
    output logic        mem_write_out,
    output logic        mem_to_reg_out,
    output logic        alu_src_out,
    output logic        branch_out,
    output logic [2:0]  alu_op_out
);

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            // Bubble: all zeros = effectively a NOP that writes nothing
            pc_plus1_out  <= 16'h0000;
            rs_data_out   <= 16'h0000;
            rt_data_out   <= 16'h0000;
            imm_out       <= 16'h0000;
            rs_addr_out   <= 3'b000;
            rt_addr_out   <= 3'b000;
            rd_addr_out   <= 3'b000;
            reg_write_out <= 1'b0;
            mem_read_out  <= 1'b0;
            mem_write_out <= 1'b0;
            mem_to_reg_out<= 1'b0;
            alu_src_out   <= 1'b0;
            branch_out    <= 1'b0;
            alu_op_out    <= 3'b000;
        end else begin
            pc_plus1_out  <= pc_plus1_in;
            rs_data_out   <= rs_data_in;
            rt_data_out   <= rt_data_in;
            imm_out       <= imm_in;
            rs_addr_out   <= rs_addr_in;
            rt_addr_out   <= rt_addr_in;
            rd_addr_out   <= rd_addr_in;
            reg_write_out <= reg_write_in;
            mem_read_out  <= mem_read_in;
            mem_write_out <= mem_write_in;
            mem_to_reg_out<= mem_to_reg_in;
            alu_src_out   <= alu_src_in;
            branch_out    <= branch_in;
            alu_op_out    <= alu_op_in;
        end
    end

endmodule


// ============================================================
// EX/MEM Pipeline Register
// Captures: ALU result, branch info, STORE data, control signals
// ============================================================
module exmem_register (
    input  logic        clk,
    input  logic        rst,

    // Inputs from EX stage
    input  logic [15:0] branch_target_in,
    input  logic        zero_flag_in,
    input  logic [15:0] alu_result_in,
    input  logic [15:0] rt_data_in,     // STORE source data
    input  logic [2:0]  rd_addr_in,

    // Control signals from EX
    input  logic        reg_write_in,
    input  logic        mem_read_in,
    input  logic        mem_write_in,
    input  logic        mem_to_reg_in,
    input  logic        branch_in,

    // Outputs to MEM stage
    output logic [15:0] branch_target_out,
    output logic        zero_flag_out,
    output logic [15:0] alu_result_out,
    output logic [15:0] rt_data_out,
    output logic [2:0]  rd_addr_out,

    // Control signals to MEM
    output logic        reg_write_out,
    output logic        mem_read_out,
    output logic        mem_write_out,
    output logic        mem_to_reg_out,
    output logic        branch_out
);

    always_ff @(posedge clk) begin
        if (rst) begin
            branch_target_out <= 16'h0000;
            zero_flag_out     <= 1'b0;
            alu_result_out    <= 16'h0000;
            rt_data_out       <= 16'h0000;
            rd_addr_out       <= 3'b000;
            reg_write_out     <= 1'b0;
            mem_read_out      <= 1'b0;
            mem_write_out     <= 1'b0;
            mem_to_reg_out    <= 1'b0;
            branch_out        <= 1'b0;
        end else begin
            branch_target_out <= branch_target_in;
            zero_flag_out     <= zero_flag_in;
            alu_result_out    <= alu_result_in;
            rt_data_out       <= rt_data_in;
            rd_addr_out       <= rd_addr_in;
            reg_write_out     <= reg_write_in;
            mem_read_out      <= mem_read_in;
            mem_write_out     <= mem_write_in;
            mem_to_reg_out    <= mem_to_reg_in;
            branch_out        <= branch_out;  // propagated
        end
    end

    // branch_out needs special handling: pass through
    // (overriding above assignment):

endmodule


// ============================================================
// MEM/WB Pipeline Register
// Captures: Memory data or ALU result, write-back control
// ============================================================
module memwb_register (
    input  logic        clk,
    input  logic        rst,

    // Inputs from MEM stage
    input  logic [15:0] mem_data_in,
    input  logic [15:0] alu_result_in,
    input  logic [2:0]  rd_addr_in,

    // Control signals from MEM
    input  logic        reg_write_in,
    input  logic        mem_to_reg_in,

    // Outputs to WB stage
    output logic [15:0] mem_data_out,
    output logic [15:0] alu_result_out,
    output logic [2:0]  rd_addr_out,

    // Control signals to WB
    output logic        reg_write_out,
    output logic        mem_to_reg_out
);

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_data_out   <= 16'h0000;
            alu_result_out <= 16'h0000;
            rd_addr_out    <= 3'b000;
            reg_write_out  <= 1'b0;
            mem_to_reg_out <= 1'b0;
        end else begin
            mem_data_out   <= mem_data_in;
            alu_result_out <= alu_result_in;
            rd_addr_out    <= rd_addr_in;
            reg_write_out  <= reg_write_in;
            mem_to_reg_out <= mem_to_reg_in;
        end
    end

endmodule
