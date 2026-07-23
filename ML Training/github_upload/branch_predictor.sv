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

        assign predict_taken = (predict_sum >= 0);

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
