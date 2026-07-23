// ============================================================
// MODULE: cpu_tb.sv
// DESC:   Self-Checking Testbench for 16-bit Pipelined RISC CPU
//
// What this testbench does:
//   1. Generates a 10ns-period clock
//   2. Applies synchronous reset for 3 cycles
//   3. Runs the sample program for 60 clock cycles
//   4. Monitors and prints all pipeline activity
//   5. Checks final register values against expected results
//   6. Dumps VCD waveform for GTKWave analysis
//
// Expected Register State after program completion:
//   R0 = 0    (hardwired zero, never changes)
//   R1 = 4    (ADDI 5, then ADDI -1)
//   R2 = 10   (ADDI 10)
//   R3 = 3    (ADDI 3)
//   R4 = 42   (final ADDI 42 after branch taken)
//   R5 = 15   (loaded 12, added 3 = 15)
//   R6 = 10   (loaded from MEM[1] = 10)
//   R7 = 12   (loaded from MEM[0] = 12)
//
// Expected Data Memory:
//   MEM[0] = 12 (stored R5=12 by STORE)
//   MEM[1] = 10 (stored R2=10 by STORE)
// ============================================================

`timescale 1ns/1ps

// Design included via compile command

module cpu_tb;

    // --------------------------------------------------------
    // Clock and Reset Generation
    // --------------------------------------------------------
    logic clk;
    logic rst;
    logic [1:0] predictor_sel;
    initial predictor_sel = 2'd0; // 0=none 1=2-bit SAT 2=Perceptron

    // 10 ns period (100 MHz)
    initial clk = 0;
    always #5 clk = ~clk;

    // --------------------------------------------------------
    // DUT Instantiation
    // --------------------------------------------------------
    logic [15:0] dbg_pc;
    logic [15:0] dbg_instr;
    logic [15:0] dbg_alu_result;
    logic [2:0]  dbg_wb_rd;
    logic [15:0] dbg_wb_data;
    logic        dbg_wb_write;
    logic        dbg_stall;
    logic        dbg_branch_taken;
    logic [1:0]  dbg_forward_a;
    logic [1:0]  dbg_forward_b;
    logic        dbg_predict_taken;
    logic        dbg_mispredict;
    logic [15:0] dbg_ghr;

    cpu_top dut (
        .clk            (clk),
        .rst            (rst),
        .predictor_sel  (predictor_sel),
        .dbg_pc         (dbg_pc),
        .dbg_instr      (dbg_instr),
        .dbg_alu_result (dbg_alu_result),
        .dbg_wb_rd      (dbg_wb_rd),
        .dbg_wb_data    (dbg_wb_data),
        .dbg_wb_write   (dbg_wb_write),
        .dbg_stall      (dbg_stall),
        .dbg_branch_taken(dbg_branch_taken),
        .dbg_forward_a  (dbg_forward_a),
        .dbg_forward_b  (dbg_forward_b),
        .dbg_predict_taken(dbg_predict_taken),
        .dbg_mispredict (dbg_mispredict),
        .dbg_ghr        (dbg_ghr)
    );

    // --------------------------------------------------------
    // VCD Waveform Dump (EDA Playground / GTKWave compatible)
    // --------------------------------------------------------
    initial begin
        $dumpfile("cpu_wave.vcd");
        $dumpvars(0, cpu_tb);  // Dump all signals in this scope
    end

    // --------------------------------------------------------
    // Cycle Counter
    // --------------------------------------------------------
    integer cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) cycle_count <= cycle_count + 1;

    // --------------------------------------------------------
    // Pipeline Activity Monitor
    // Prints one line per clock cycle showing key signals
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (!rst) begin
            $display("------------------------------------------------------------");
            $display("Cycle %0d | PC=%0d | Instr=0x%04h | ALU=%0d",
                      cycle_count, dbg_pc, dbg_instr, dbg_alu_result);

            // Register write events
            if (dbg_wb_write && dbg_wb_rd != 3'b000) begin
                $display("  [WB]   R%0d <= %0d (0x%04h)",
                          dbg_wb_rd, dbg_wb_data, dbg_wb_data);
            end

            // Stall event
            if (dbg_stall) begin
                $display("  [STALL] Load-Use hazard detected — inserting bubble");
            end

            // Branch taken event
            if (dbg_branch_taken) begin
                $display("  [BRANCH TAKEN] Flushing pipeline, jumping to new PC");
            end

            // Forwarding events
            if (dbg_forward_a != 2'b00) begin
                $display("  [FWD-A] Forwarding to ALU input A: path=%b", dbg_forward_a);
            end
            if (dbg_forward_b != 2'b00) begin
                $display("  [FWD-B] Forwarding to ALU input B: path=%b", dbg_forward_b);
            end
        end
    end

    // --------------------------------------------------------
    // Baseline Performance Metric Counters
    // --------------------------------------------------------
    integer total_cycles;
    integer instr_retired;
    integer branch_count;
    integer branch_flushes;
    integer stall_cycles;
    integer flush_cycles;
    logic   branch_taken_prev;

    initial begin
        total_cycles      = 0; instr_retired = 0;
        branch_count      = 0; branch_flushes = 0;
        stall_cycles      = 0; flush_cycles = 0;
        branch_taken_prev = 0;
    end

    always @(posedge clk) begin
        if (rst) begin
            total_cycles      <= 0; instr_retired     <= 0;
            branch_count      <= 0; branch_flushes    <= 0;
            stall_cycles      <= 0; flush_cycles      <= 0;
            branch_taken_prev <= 0;
        end else begin
            total_cycles <= total_cycles + 1;
            if ((dut.memwb_reg_write && dut.memwb_rd != 3'b000) ||
                 dut.exmem_mem_write)
                instr_retired <= instr_retired + 1;
            if (dut.exmem_branch)
                branch_count <= branch_count + 1;
            branch_taken_prev <= dut.branch_taken;
            if (dut.branch_taken && !branch_taken_prev) begin
                branch_flushes <= branch_flushes + 1;
                flush_cycles   <= flush_cycles + 1;
            end
            if (dut.stall_pc)
                stall_cycles <= stall_cycles + 1;
        end
    end

    // --------------------------------------------------------
    // Branch Trace Logger
    //
    // Emits one CSV line every time a branch resolves in MEM.
    // Format:  BRANCH_TRACE,<pc>,<ghr_binary>,<taken>,<predicted>,<mispredict>
    //
    // Python parser looks for lines starting with "BRANCH_TRACE,"
    // Everything else in the log is safely ignored.
    //
    // Fields:
    //   pc         — PC of the branch instruction (decimal)
    //   ghr        — 4-bit global history at time of fetch (binary string)
    //   taken      — actual outcome: 1=taken, 0=not-taken
    //   predicted  — what the active predictor predicted (0 if no predictor)
    //   mispredict — 1 if prediction was wrong
    // --------------------------------------------------------
    always @(posedge clk) begin
        if (!rst && dut.exmem_branch) begin
            $display("BRANCH_TRACE,%0d,%b,%0d,%0d,%0d",
                dut.exmem_pc,           // branch PC (piped from IF)
                dut.dbg_ghr[3:0],       // GHR at time of fetch (4 bits)
                dut.branch_taken,       // actual outcome
                dbg_predict_taken,      // predictor's guess
                dbg_mispredict          // misprediction flag
            );
        end
    end

    // --------------------------------------------------------
    // Main Test Sequence
    // --------------------------------------------------------
    integer i;

    initial begin
        $display("============================================================");
        $display(" 16-bit 5-Stage Pipelined RISC CPU — Simulation Start");
        $display(" Predictor: %s",
            predictor_sel==2'd0 ? "NONE (baseline)" :
            predictor_sel==2'd1 ? "2-BIT SAT" : "PERCEPTRON");
        $display("============================================================");

        // ---- Apply Reset ----
        rst = 1;
        repeat (3) @(posedge clk);
        #1;
        rst = 0;

        $display("[INFO] Reset released at cycle %0d — program starting", cycle_count);
        $display("TRACE_START");   // marker for Python parser

        // ---- Run simulation — 600 cycles covers all benchmarks ----
        // ── Run until program completes ──────────────────────
        // Stop when PC stays above 20 for 10 consecutive cycles.
        // Programs end in a NOP sled or HALT (BEQ self-loop) past PC=20.
        begin : completion_wait
            integer idle; integer wdog;
            idle = 0; wdog = 0;
            while (idle < 10 && wdog < 5000) begin
                @(posedge clk);
                wdog = wdog + 1;
                if (dbg_pc > 25)
                    idle = idle + 1;
                else
                    idle = 0;
            end
            // Drain pipeline after completion
            repeat(10) @(posedge clk);
        end

        $display("TRACE_END");     // marker for Python parser

        // ---- Final state ----
        $display("\n============================================================");
        $display(" SIMULATION COMPLETE");
        $display("============================================================\n");

        print_registers();
        print_memory();
        check_results();
        print_metrics();

        $display("\n============================================================");
        $display(" END OF SIMULATION");
        $display("============================================================");
        $finish;
    end

    // --------------------------------------------------------
    // Task: Print All Register Values
    // --------------------------------------------------------
    task print_registers;
        integer r;
        $display("--- Register File Contents ---");
        for (r = 0; r < 8; r++) begin
            $display("  R%0d = %0d (0x%04h)", r,
                      dut.u_rf.regs[r],
                      dut.u_rf.regs[r]);
        end
        $display("");
    endtask

    // --------------------------------------------------------
    // Task: Print Data Memory (first 8 locations)
    // --------------------------------------------------------
    task print_memory;
        integer m;
        $display("--- Data Memory (first 8 words) ---");
        for (m = 0; m < 8; m++) begin
            $display("  MEM[%0d] = %0d (0x%04h)", m,
                      dut.u_dmem.mem[m],
                      dut.u_dmem.mem[m]);
        end
        $display("");
    endtask

    // --------------------------------------------------------
    // Task: Self-Checking Assertions
    // --------------------------------------------------------
    integer pass_count;
    integer fail_count;

    task check_results;
        pass_count = 0;
        fail_count = 0;

        $display("--- Self-Check Results ---");

        // R0 must always be zero
        check_reg(0, 16'd0,  "R0 hardwired zero");

        // ADDI R1, R0, 5  then ADDI R1, R1, -1 -> R1 = 4
        check_reg(1, 16'd4,  "R1 = ADDI(5) + ADDI(-1)");

        // ADDI R2, R0, 10
        check_reg(2, 16'd10, "R2 = ADDI(10)");

        // ADDI R3, R0, 3
        check_reg(3, 16'd3,  "R3 = ADDI(3)");

        // ADDI R4, R0, 42 (after branch taken to instr 17)
        check_reg(4, 16'd42, "R4 = ADDI(42) after branch");

        // ADD R5 = LOAD(12) + R3(3) = 15
        check_reg(5, 16'd15, "R5 = load(12) + 3 = 15");

        // LOAD R6 from MEM[1] = 10
        check_reg(6, 16'd10, "R6 = MEM[1] = 10");

        // LOAD R7 from MEM[0] = 12
        check_reg(7, 16'd12, "R7 = MEM[0] = 12");

        // Memory checks
        check_mem(0, 16'd12, "MEM[0] = 12 (STORE R5)");
        check_mem(1, 16'd10, "MEM[1] = 10 (STORE R2)");

        // Summary
        $display("\n--- Test Summary: %0d PASSED, %0d FAILED ---",
                  pass_count, fail_count);
        if (fail_count == 0)
            $display("[PASS] All checks passed! CPU is functionally correct.");
        else
            $display("[FAIL] %0d check(s) failed. Review waveform for debug.", fail_count);
    endtask

    // Helper: Check a register value
    task check_reg;
        input integer  reg_num;
        input [15:0]   expected;
        input string   description;
        logic [15:0]   actual;
        actual = (reg_num == 0) ? 16'd0 : dut.u_rf.regs[reg_num];
        if (actual === expected) begin
            $display("  [PASS] %s: R%0d = %0d", description, reg_num, actual);
            pass_count++;
        end else begin
            $display("  [FAIL] %s: R%0d = %0d (expected %0d)",
                      description, reg_num, actual, expected);
            fail_count++;
        end
    endtask

    // Helper: Check a data memory word
    task check_mem;
        input integer  addr;
        input [15:0]   expected;
        input string   description;
        logic [15:0]   actual;
        actual = dut.u_dmem.mem[addr];
        if (actual === expected) begin
            $display("  [PASS] %s: MEM[%0d] = %0d", description, addr, actual);
            pass_count++;
        end else begin
            $display("  [FAIL] %s: MEM[%0d] = %0d (expected %0d)",
                      description, addr, actual, expected);
            fail_count++;
        end
    endtask

    // --------------------------------------------------------
    // Task: Performance Metrics Report
    // --------------------------------------------------------
    task print_metrics;
        $display("\n--- Baseline Performance Metrics ---");
        $display("  %-34s : %0d",  "Total Active Cycles",      total_cycles);
        $display("  %-34s : %0d",  "Instructions Retired",     instr_retired);
        $display("  %-34s : %0d",  "Load-Use Stall Cycles",    stall_cycles);
        $display("  %-34s : %0d",  "Branch Instructions",      branch_count);
        $display("  %-34s : %0d",  "Branches Taken (Flushes)", branch_flushes);
        $display("  %-34s : %0d",  "Flush Penalty Cycles",     flush_cycles);
        $display("  --------------------------------------------------");
        if (instr_retired > 0) begin
            $display("  %-34s : %.4f",
                "IPC", real'(instr_retired) / real'(total_cycles));
            $display("  %-34s : %.4f",
                "CPI", real'(total_cycles) / real'(instr_retired));
            $display("  %-34s : %.2f%%",
                "Pipeline Efficiency",
                100.0 * real'(instr_retired) / real'(total_cycles));
        end
        if (branch_count > 0) begin
            $display("  %-34s : %.2f%%",
                "Branch Misprediction Rate",
                100.0 * real'(branch_flushes) / real'(branch_count));
            $display("  %-34s : %.4f cycles",
                "Avg Penalty Per Branch",
                real'(flush_cycles) / real'(branch_count));
        end
        $display("");
    endtask

    // --------------------------------------------------------
    // Timeout Watchdog
    // --------------------------------------------------------
    initial begin
        #60000;  // 6000 cycles — enough for all benchmarks
        $display("[TIMEOUT] Simulation exceeded time limit — stopping.");
        $finish;
    end

endmodule
