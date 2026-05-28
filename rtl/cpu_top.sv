// ============================================================
// MODULE: cpu_top.sv
// DESC:   Top-Level 16-bit 5-Stage Pipelined RISC CPU
//
// PIPELINE OVERVIEW:
// ==================
//
//  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐
//  │  IF  │→ │  ID  │→ │  EX  │→ │ MEM  │→ │  WB  │
//  └──────┘  └──────┘  └──────┘  └──────┘  └──────┘
//      ↑         ↑         ↑         ↑         ↑
//    PC+1      Decode    ALU op    Mem R/W   Reg WB
//
// Hazard Handling:
//   - Load-Use stall: HDU freezes PC + IF/ID, inserts NOP in ID/EX
//   - Branch flush: IF/ID flushed one cycle after branch detected in EX
//   - Forwarding: FU short-circuits EX/MEM and MEM/WB back to EX stage
//
// Datapath width: 16-bit
// Registers:      8 x 16-bit (R0 = zero)
// Instruction memory: 256 words
// Data memory:        256 words
// ============================================================

`include "alu.sv"
`include "control_unit.sv"
`include "register_file.sv"
`include "memory_units.sv"
`include "hazard_forwarding.sv"
`include "pipeline_registers.sv"

module cpu_top (
    input  logic clk,
    input  logic rst,

    // Observation ports (for testbench / waveform debug)
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_instr,
    output logic [15:0] dbg_alu_result,
    output logic [2:0]  dbg_wb_rd,
    output logic [15:0] dbg_wb_data,
    output logic        dbg_wb_write,
    output logic        dbg_stall,
    output logic        dbg_branch_taken,
    output logic [1:0]  dbg_forward_a,
    output logic [1:0]  dbg_forward_b
);

    // ==========================================================
    // Internal Wires — organized by pipeline stage
    // ==========================================================

    // ---- IF Stage ----
    logic [15:0] if_pc;
    logic [15:0] if_pc_plus1;
    logic [15:0] if_instr;

    // ---- IF/ID Register Outputs ----
    logic [15:0] ifid_pc_plus1;
    logic [15:0] ifid_instr;

    // ---- ID Stage ----
    logic [3:0]  id_opcode;
    logic [2:0]  id_rs_addr, id_rt_addr, id_rd_addr;
    logic [5:0]  id_imm6;
    logic [15:0] id_imm16;
    logic [15:0] id_rs_data, id_rt_data;

    // ID control signals
    logic        id_reg_write, id_mem_read, id_mem_write;
    logic        id_mem_to_reg, id_alu_src, id_branch;
    logic [2:0]  id_alu_op;

    // ---- ID/EX Register Outputs ----
    logic [15:0] idex_pc_plus1;
    logic [15:0] idex_rs_data, idex_rt_data, idex_imm;
    logic [2:0]  idex_rs_addr, idex_rt_addr, idex_rd_addr;
    logic        idex_reg_write, idex_mem_read, idex_mem_write;
    logic        idex_mem_to_reg, idex_alu_src, idex_branch;
    logic [2:0]  idex_alu_op;

    // ---- EX Stage ----
    logic [15:0] ex_alu_a, ex_alu_b, ex_alu_b_mux;
    logic [15:0] ex_alu_result;
    logic        ex_zero_flag;
    logic [15:0] ex_branch_target;
    logic [1:0]  ex_forward_a, ex_forward_b;

    // WB result (for forwarding from MEM/WB)
    logic [15:0] wb_result;

    // ---- EX/MEM Register Outputs ----
    logic [15:0] exmem_branch_target;
    logic        exmem_zero_flag;
    logic [15:0] exmem_alu_result, exmem_rt_data;
    logic [2:0]  exmem_rd_addr;
    logic        exmem_reg_write, exmem_mem_read, exmem_mem_write;
    logic        exmem_mem_to_reg, exmem_branch;

    // ---- MEM Stage ----
    logic [15:0] mem_read_data;
    logic        mem_branch_taken;

    // ---- MEM/WB Register Outputs ----
    logic [15:0] memwb_mem_data, memwb_alu_result;
    logic [2:0]  memwb_rd_addr;
    logic        memwb_reg_write, memwb_mem_to_reg;

    // ---- WB Stage ----
    // (wb_result defined above for forwarding loop)

    // ---- Hazard Signals ----
    logic        stall_pc, stall_ifid, insert_bubble;
    logic        flush_ifid;

    // ==========================================================
    // STAGE 1: IF — Instruction Fetch
    // ==========================================================

    // PC+1 is the next sequential address (word-addressed)
    assign if_pc_plus1 = if_pc + 16'h0001;

    // Branch detection happens in MEM stage; flush the two
    // instructions that entered the pipeline after the branch
    // We flush IF/ID when branch_taken is confirmed.
    assign flush_ifid = mem_branch_taken;

    // Program Counter
    program_counter u_pc (
        .clk           (clk),
        .rst           (rst),
        .stall         (stall_pc),
        .branch_taken  (mem_branch_taken),
        .branch_target (exmem_branch_target),
        .pc_out        (if_pc)
    );

    // Instruction Memory (ROM)
    instruction_memory u_imem (
        .addr  (if_pc),
        .instr (if_instr)
    );

    // IF/ID Pipeline Register
    ifid_register u_ifid (
        .clk         (clk),
        .rst         (rst),
        .stall       (stall_ifid),
        .flush       (flush_ifid),
        .pc_plus1_in (if_pc_plus1),
        .instr_in    (if_instr),
        .pc_plus1_out(ifid_pc_plus1),
        .instr_out   (ifid_instr)
    );

    // ==========================================================
    // STAGE 2: ID — Instruction Decode
    // ==========================================================

    // Instruction field extraction
    // R-Type: [15:12]=op [11:9]=rs [8:6]=rt [5:3]=rd [2:0]=funct
    // I-Type: [15:12]=op [11:9]=rs [8:6]=rd [5:0]=imm
    assign id_opcode  = ifid_instr[15:12];
    assign id_rs_addr = ifid_instr[11:9];
    assign id_rt_addr = ifid_instr[8:6];  // also used as rd for I-type
    assign id_rd_addr = ifid_instr[5:3];  // R-type rd
    assign id_imm6    = ifid_instr[5:0];  // I-type immediate

    // For I-type instructions, the destination reg is in [8:6]
    // We select rd correctly in the ID/EX register muxing below:
    // (For R-type: rd from [5:3], For I-type: rd from [8:6])
    // We determine this from the control unit's alu_src signal:
    // If alu_src==1 (I-type), rd is in rt_addr field [8:6]

    // Control Unit
    control_unit u_ctrl (
        .opcode     (id_opcode),
        .reg_write  (id_reg_write),
        .mem_read   (id_mem_read),
        .mem_write  (id_mem_write),
        .mem_to_reg (id_mem_to_reg),
        .alu_src    (id_alu_src),
        .branch     (id_branch),
        .alu_op     (id_alu_op)
    );

    // Register File — read rs and rt
    // For WB: write using MEM/WB register values
    register_file u_rf (
        .clk        (clk),
        .rst        (rst),
        .rs_addr    (id_rs_addr),
        .rt_addr    (id_rt_addr),
        .rs_data    (id_rs_data),
        .rt_data    (id_rt_data),
        .rd_addr    (memwb_rd_addr),
        .write_data (wb_result),
        .reg_write  (memwb_reg_write)
    );

    // Sign Extension Unit
    sign_extend u_sext (
        .imm6  (id_imm6),
        .imm16 (id_imm16)
    );

    // Hazard Detection Unit
    hazard_detection_unit u_hdu (
        .idex_mem_read  (idex_mem_read),
        .idex_rd        (idex_rd_addr),
        .ifid_rs        (id_rs_addr),
        .ifid_rt        (id_rt_addr),
        .stall_pc       (stall_pc),
        .stall_ifid     (stall_ifid),
        .insert_bubble  (insert_bubble)
    );

    // ID/EX Pipeline Register
    // NOTE: For I-type (alu_src=1), destination register is in [8:6] (rt_addr)
    //       For R-type (alu_src=0), destination register is in [5:3] (rd_addr)
    //       For STORE (mem_write=1), no destination register needed
    idex_register u_idex (
        .clk          (clk),
        .rst          (rst),
        .flush        (insert_bubble),  // HDU bubble insertion
        .pc_plus1_in  (ifid_pc_plus1),
        .rs_data_in   (id_rs_data),
        .rt_data_in   (id_rt_data),
        .imm_in       (id_imm16),
        .rs_addr_in   (id_rs_addr),
        .rt_addr_in   (id_rt_addr),
        // Select correct rd: I-type uses [8:6], R-type uses [5:3]
        .rd_addr_in   (id_alu_src ? id_rt_addr : id_rd_addr),
        .reg_write_in (id_reg_write),
        .mem_read_in  (id_mem_read),
        .mem_write_in (id_mem_write),
        .mem_to_reg_in(id_mem_to_reg),
        .alu_src_in   (id_alu_src),
        .branch_in    (id_branch),
        .alu_op_in    (id_alu_op),
        .pc_plus1_out (idex_pc_plus1),
        .rs_data_out  (idex_rs_data),
        .rt_data_out  (idex_rt_data),
        .imm_out      (idex_imm),
        .rs_addr_out  (idex_rs_addr),
        .rt_addr_out  (idex_rt_addr),
        .rd_addr_out  (idex_rd_addr),
        .reg_write_out(idex_reg_write),
        .mem_read_out (idex_mem_read),
        .mem_write_out(idex_mem_write),
        .mem_to_reg_out(idex_mem_to_reg),
        .alu_src_out  (idex_alu_src),
        .branch_out   (idex_branch),
        .alu_op_out   (idex_alu_op)
    );

    // ==========================================================
    // STAGE 3: EX — Execute
    // ==========================================================

    // Forwarding Unit — determines whether ALU inputs should
    // come from register file or forwarded pipeline values
    forwarding_unit u_fwd (
        .ex_rs           (idex_rs_addr),
        .ex_rt           (idex_rt_addr),
        .exmem_rd        (exmem_rd_addr),
        .exmem_reg_write (exmem_reg_write),
        .memwb_rd        (memwb_rd_addr),
        .memwb_reg_write (memwb_reg_write),
        .forward_a       (ex_forward_a),
        .forward_b       (ex_forward_b)
    );

    // ALU Input A Mux (forwarding)
    // 2'b00: register file, 2'b01: MEM/WB, 2'b10: EX/MEM
    always_comb begin
        case (ex_forward_a)
            2'b00:   ex_alu_a = idex_rs_data;
            2'b01:   ex_alu_a = wb_result;            // from MEM/WB
            2'b10:   ex_alu_a = exmem_alu_result;    // from EX/MEM
            default: ex_alu_a = idex_rs_data;
        endcase
    end

    // ALU Input B Mux — first select between rt and immediate,
    // then apply forwarding for the register path
    always_comb begin
        case (ex_forward_b)
            2'b00:   ex_alu_b = idex_rt_data;
            2'b01:   ex_alu_b = wb_result;
            2'b10:   ex_alu_b = exmem_alu_result;
            default: ex_alu_b = idex_rt_data;
        endcase
    end

    // ALU Source Mux: choose between forwarded rt or immediate
    assign ex_alu_b_mux = idex_alu_src ? idex_imm : ex_alu_b;

    // ALU
    alu u_alu (
        .a         (ex_alu_a),
        .b         (ex_alu_b_mux),
        .alu_op    (idex_alu_op),
        .result    (ex_alu_result),
        .zero_flag (ex_zero_flag)
    );

    // Branch Target Calculation: PC+1 + sign_ext_imm
    assign ex_branch_target = idex_pc_plus1 + idex_imm;

    // EX/MEM Pipeline Register
    exmem_register u_exmem (
        .clk              (clk),
        .rst              (rst),
        .branch_target_in (ex_branch_target),
        .zero_flag_in     (ex_zero_flag),
        .alu_result_in    (ex_alu_result),
        .rt_data_in       (ex_alu_b),       // un-muxed rt for STORE
        .rd_addr_in       (idex_rd_addr),
        .reg_write_in     (idex_reg_write),
        .mem_read_in      (idex_mem_read),
        .mem_write_in     (idex_mem_write),
        .mem_to_reg_in    (idex_mem_to_reg),
        .branch_in        (idex_branch),
        .branch_target_out(exmem_branch_target),
        .zero_flag_out    (exmem_zero_flag),
        .alu_result_out   (exmem_alu_result),
        .rt_data_out      (exmem_rt_data),
        .rd_addr_out      (exmem_rd_addr),
        .reg_write_out    (exmem_reg_write),
        .mem_read_out     (exmem_mem_read),
        .mem_write_out    (exmem_mem_write),
        .mem_to_reg_out   (exmem_mem_to_reg),
        .branch_out       (exmem_branch)
    );

    // ==========================================================
    // STAGE 4: MEM — Memory Access
    // ==========================================================

    // Branch decision: taken if branch instruction AND zero flag set
    assign mem_branch_taken = exmem_branch && exmem_zero_flag;

    // Data Memory
    data_memory u_dmem (
        .clk        (clk),
        .mem_read   (exmem_mem_read),
        .mem_write  (exmem_mem_write),
        .addr       (exmem_alu_result),   // computed address from ALU
        .write_data (exmem_rt_data),      // data to store
        .read_data  (mem_read_data)
    );

    // MEM/WB Pipeline Register
    memwb_register u_memwb (
        .clk          (clk),
        .rst          (rst),
        .mem_data_in  (mem_read_data),
        .alu_result_in(exmem_alu_result),
        .rd_addr_in   (exmem_rd_addr),
        .reg_write_in (exmem_reg_write),
        .mem_to_reg_in(exmem_mem_to_reg),
        .mem_data_out (memwb_mem_data),
        .alu_result_out(memwb_alu_result),
        .rd_addr_out  (memwb_rd_addr),
        .reg_write_out(memwb_reg_write),
        .mem_to_reg_out(memwb_mem_to_reg)
    );

    // ==========================================================
    // STAGE 5: WB — Write Back
    // ==========================================================

    // Write-back mux: choose between memory data or ALU result
    assign wb_result = memwb_mem_to_reg ? memwb_mem_data : memwb_alu_result;

    // Register file write is handled in the RF instantiation above
    // (shared with ID stage — single write port fed by MEM/WB)

    // ==========================================================
    // DEBUG OBSERVATION OUTPUTS
    // ==========================================================
    assign dbg_pc           = if_pc;
    assign dbg_instr        = ifid_instr;
    assign dbg_alu_result   = ex_alu_result;
    assign dbg_wb_rd        = memwb_rd_addr;
    assign dbg_wb_data      = wb_result;
    assign dbg_wb_write     = memwb_reg_write;
    assign dbg_stall        = stall_pc;
    assign dbg_branch_taken = mem_branch_taken;
    assign dbg_forward_a    = ex_forward_a;
    assign dbg_forward_b    = ex_forward_b;

endmodule
