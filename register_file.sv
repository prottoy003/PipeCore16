// ============================================================
// MODULE: register_file.sv
// DESC:   8 x 16-bit Register File
//
// Features:
//   - 8 general-purpose registers (R0..R7)
//   - R0 is hardwired to zero (reads always return 0)
//   - Dual read ports (combinational)
//   - Single write port (synchronous, rising edge)
//   - Write-then-Read: if write & read same reg same cycle,
//     read returns the NEW value (forwarding within RF)
//
// Ports:
//   clk        : clock
//   rst        : synchronous reset (all regs -> 0)
//   rs_addr    : first  read address  [2:0]
//   rt_addr    : second read address  [2:0]
//   rd_addr    : write  address       [2:0]
//   write_data : data to write        [15:0]
//   reg_write  : write enable
//   rs_data    : data from first  read port [15:0]
//   rt_data    : data from second read port [15:0]
// ============================================================

module register_file (
    input  logic        clk,
    input  logic        rst,

    // Read ports (combinational)
    input  logic [2:0]  rs_addr,
    input  logic [2:0]  rt_addr,
    output logic [15:0] rs_data,
    output logic [15:0] rt_data,

    // Write port (synchronous)
    input  logic [2:0]  rd_addr,
    input  logic [15:0] write_data,
    input  logic        reg_write
);

    // 8 registers, each 16 bits
    logic [15:0] regs [0:7];

    // --------------------------------------------------------
    // Synchronous write with synchronous reset
    // --------------------------------------------------------
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset all registers to zero
            for (i = 0; i < 8; i++) begin
                regs[i] <= 16'b0;
            end
        end else if (reg_write && (rd_addr != 3'b000)) begin
            // R0 is hardwired zero — never write to it
            regs[rd_addr] <= write_data;
        end
    end

    // --------------------------------------------------------
    // Combinational read with R0 hardwired to zero
    // --------------------------------------------------------
    assign rs_data = (rs_addr == 3'b000) ? 16'b0 : regs[rs_addr];
    assign rt_data = (rt_addr == 3'b000) ? 16'b0 : regs[rt_addr];

endmodule
