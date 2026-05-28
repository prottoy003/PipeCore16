// ============================================================
// MODULE: hazard_detection_unit.sv
// DESC:   Detects load-use data hazards and generates stall
//
// PROBLEM: Load-Use Hazard
// ========================
// When a LOAD is followed immediately by an instruction that
// uses the loaded register, the data is not available in time
// even with forwarding (because memory is read in MEM stage,
// but the next instruction needs the value in EX stage, which
// occurs BEFORE MEM completes).
//
// EXAMPLE:
//   Cycle:   1    2    3    4    5
//   LOAD:   IF   ID   EX  MEM   WB    <- data available after MEM
//   ADD:         IF   ID   EX   MEM   <- needs data during EX (cycle 4)
//                                        but LOAD data isn't ready yet!
//
// SOLUTION: Insert a BUBBLE (NOP) between them:
//   Cycle:   1    2    3    4    5    6
//   LOAD:   IF   ID   EX  MEM   WB
//   NOP:         IF   ID   EX  MEM  WB   <- inserted stall bubble
//   ADD:              IF   ID   EX  MEM  WB
//
// HOW TO STALL:
//   1. Freeze PC (don't advance)
//   2. Freeze IF/ID register (keep fetching same instruction)
//   3. Insert NOP into ID/EX register (flush the pipeline stage)
//
// DETECTION CONDITIONS:
//   - The instruction in ID/EX is a LOAD (mem_read == 1)
//   - The destination register of LOAD matches either source
//     register of the instruction currently in ID stage
// ============================================================

module hazard_detection_unit (
    // From ID/EX pipeline register
    input  logic       idex_mem_read,  // Is the EX-stage instruction a LOAD?
    input  logic [2:0] idex_rd,        // Destination register of LOAD

    // From the instruction currently being decoded (IF/ID)
    input  logic [2:0] ifid_rs,        // Source register 1 of upcoming instr
    input  logic [2:0] ifid_rt,        // Source register 2 of upcoming instr

    // Stall outputs
    output logic       stall_pc,       // 1 = freeze program counter
    output logic       stall_ifid,     // 1 = freeze IF/ID register
    output logic       insert_bubble   // 1 = replace ID/EX with NOP bubble
);

    // Load-Use Hazard Condition:
    // If the EX-stage is a LOAD AND its destination matches either
    // source of the next instruction, we must stall for 1 cycle.
    wire load_use_hazard = idex_mem_read &&
                           ((idex_rd == ifid_rs) ||
                            (idex_rd == ifid_rt));

    // Drive stall signals
    assign stall_pc     = load_use_hazard;
    assign stall_ifid   = load_use_hazard;
    assign insert_bubble = load_use_hazard;

endmodule


// ============================================================
// MODULE: forwarding_unit.sv
// DESC:   Data Forwarding Unit — eliminates RAW hazards by
//         routing results directly to ALU inputs.
//
// WHY FORWARDING?
// ===============
// Without forwarding, a Read-After-Write (RAW) hazard causes
// the pipeline to stall until the result is written back.
// With forwarding, we "short-circuit" the datapath: the result
// is sent directly from where it's produced to where it's needed.
//
// TWO FORWARDING PATHS:
// =====================
//
// 1. EX/MEM -> EX (Forward A or B from EX/MEM)
//    Source:  ALU result sitting in EX/MEM pipeline register
//    Dest:    ALU input of instruction currently in EX stage
//    Occurs:  2 instructions after the producer (1 cycle gap)
//
//    Example:
//      ADD R1, ...    <- produces R1 (now in EX/MEM)
//      NOP            <- in MEM
//      SUB R2, R1,..  <- needs R1 NOW in EX -> forward from EX/MEM
//
//    Actually, the more common case:
//      ADD R1, R2, R3  <- EX stage (produces R1)
//      SUB R4, R1, R5  <- one cycle later, also in EX -> forward!
//
// 2. MEM/WB -> EX (Forward A or B from MEM/WB)
//    Source:  Result sitting in MEM/WB pipeline register
//    Dest:    ALU input of instruction currently in EX stage
//    Occurs:  When there's a 2-cycle gap between producer & consumer
//
// FORWARDING MUX SELECT ENCODING:
//   2'b00 -> No forwarding: use register file output
//   2'b01 -> Forward from MEM/WB stage
//   2'b10 -> Forward from EX/MEM stage (takes priority)
//
// PRIORITY: EX/MEM forwarding takes priority over MEM/WB
// because EX/MEM has the MORE RECENT value.
// ============================================================

module forwarding_unit (
    // Current instruction in EX stage (source registers)
    input  logic [2:0] ex_rs,           // rs of instruction in EX
    input  logic [2:0] ex_rt,           // rt of instruction in EX

    // EX/MEM pipeline register info
    input  logic [2:0] exmem_rd,        // Destination reg of EX/MEM instr
    input  logic       exmem_reg_write, // Does EX/MEM instr write a reg?

    // MEM/WB pipeline register info
    input  logic [2:0] memwb_rd,        // Destination reg of MEM/WB instr
    input  logic       memwb_reg_write, // Does MEM/WB instr write a reg?

    // Forwarding mux selects
    output logic [1:0] forward_a,       // Controls ALU input A mux
    output logic [1:0] forward_b        // Controls ALU input B mux
);

    // --------------------------------------------------------
    // Forward A logic (for rs operand of EX-stage instruction)
    // --------------------------------------------------------
    always_comb begin
        forward_a = 2'b00;  // Default: no forwarding

        // Priority 1: Forward from EX/MEM (most recent value)
        // Condition: EX/MEM stage writes a register AND
        //            the destination matches rs AND
        //            destination is not R0 (hardwired zero)
        if (exmem_reg_write &&
            (exmem_rd != 3'b000) &&
            (exmem_rd == ex_rs)) begin
            forward_a = 2'b10;  // Forward from EX/MEM ALU result

        // Priority 2: Forward from MEM/WB
        end else if (memwb_reg_write &&
                     (memwb_rd != 3'b000) &&
                     (memwb_rd == ex_rs)) begin
            forward_a = 2'b01;  // Forward from MEM/WB result
        end
    end

    // --------------------------------------------------------
    // Forward B logic (for rt operand of EX-stage instruction)
    // --------------------------------------------------------
    always_comb begin
        forward_b = 2'b00;  // Default: no forwarding

        if (exmem_reg_write &&
            (exmem_rd != 3'b000) &&
            (exmem_rd == ex_rt)) begin
            forward_b = 2'b10;  // Forward from EX/MEM ALU result

        end else if (memwb_reg_write &&
                     (memwb_rd != 3'b000) &&
                     (memwb_rd == ex_rt)) begin
            forward_b = 2'b01;  // Forward from MEM/WB result
        end
    end

endmodule
