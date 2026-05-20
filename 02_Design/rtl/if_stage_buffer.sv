// ============================================================
// Module: if_stage_buffer
// Description: IF hold register, single-instruction buffer, and BP snapshots.
// ============================================================

module if_stage_buffer (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        if_valid,
    input  logic        if_ready_go,
    input  logic        id_allowin,
    input  logic        id_flush,
    input  logic        frontend_branch_flush,
    input  logic        id_bp_redirect_raw,
    input  logic        can_dual_issue,
    input  logic        inst_buf_valid_next,

    input  logic [31:0] pc,
    input  logic [31:0] pc_plus4,
    input  logic [31:0] irom_inst0,
    input  logic [31:0] irom_inst1,

    input  logic        bp_taken,
    input  logic [31:0] bp_target,
    input  logic [ 7:0] bp_ghr_snap,
    input  logic        bp_btb_hit,
    input  logic [ 1:0] bp_btb_type,
    input  logic [ 1:0] bp_btb_bht,
    input  logic [ 1:0] bp_pht_cnt,
    input  logic [ 1:0] bp_sel_cnt,
    input  logic [11:0] bp_target_even_addr,
    input  logic [11:0] bp_target_odd_addr,
    input  logic        bp_target_fetch_odd,
    input  logic [11:0] bp_target_plus4_even_addr,
    input  logic [11:0] bp_target_plus4_odd_addr,
    input  logic        bp_target_plus4_fetch_odd,
    input  logic [11:0] bp_target_plus8_even_addr,
    input  logic [11:0] bp_target_plus8_odd_addr,
    input  logic        bp_target_plus8_fetch_odd,
    input  logic [11:0] bp_target_plus12_even_addr,
    input  logic [11:0] bp_target_plus12_odd_addr,
    input  logic        bp_target_plus12_fetch_odd,

    input  logic        la_bp_taken,
    input  logic [31:0] la_bp_target,
    input  logic [ 7:0] la_bp_ghr_snap,
    input  logic        la_bp_btb_hit,
    input  logic [ 1:0] la_bp_btb_type,
    input  logic [ 1:0] la_bp_btb_bht,
    input  logic [ 1:0] la_bp_pht_cnt,
    input  logic [ 1:0] la_bp_sel_cnt,
    input  logic [11:0] la_bp_even_addr,
    input  logic [11:0] la_bp_odd_addr,
    input  logic        la_bp_fetch_odd,

    input  logic        buf_bp_taken,
    input  logic [31:0] buf_bp_target,
    input  logic [ 7:0] buf_bp_ghr_snap,
    input  logic        buf_bp_btb_hit,
    input  logic [ 1:0] buf_bp_btb_type,
    input  logic [ 1:0] buf_bp_btb_bht,
    input  logic [ 1:0] buf_bp_pht_cnt,
    input  logic [ 1:0] buf_bp_sel_cnt,
    input  logic [11:0] buf_bp_even_addr,
    input  logic [11:0] buf_bp_odd_addr,
    input  logic        buf_bp_fetch_odd,

    output logic [31:0] inst_buf,
    output logic [31:0] inst_buf_pc,
    output logic        inst_buf_valid,
    output logic        if_skip_inst0,
    output logic        if_buf_before_window,
    output logic        irom_held_valid,
    output logic        predict_dual,

    output logic [31:0] if_inst0_out,
    output logic [31:0] if_inst1_out,
    output logic [31:0] if_pc_out,
    output logic        if_bp_taken_out,
    output logic [31:0] if_bp_target_out,
    output logic [ 7:0] if_bp_ghr_snap_out,
    output logic        if_bp_btb_hit_out,
    output logic [ 1:0] if_bp_btb_type_out,
    output logic [ 1:0] if_bp_btb_bht_out,
    output logic [ 1:0] if_bp_pht_cnt_out,
    output logic [ 1:0] if_bp_sel_cnt_out,
    output logic        if_skip_out,
    output logic        if_s1_valid,
    output logic        if_sequential_fetch,
    output logic [31:0] buf_bp_pc,

    output logic        bp_taken_for_if,
    output logic [31:0] bp_target_for_if,
    output logic [11:0] bp_even_addr,
    output logic [11:0] bp_odd_addr,
    output logic        bp_fetch_odd,
    output logic [11:0] bp_plus4_even_addr,
    output logic [11:0] bp_plus4_odd_addr,
    output logic        bp_plus4_fetch_odd,
    output logic [11:0] bp_plus8_even_addr,
    output logic [11:0] bp_plus8_odd_addr,
    output logic        bp_plus8_fetch_odd,
    output logic [11:0] bp_plus12_even_addr,
    output logic [11:0] bp_plus12_odd_addr,
    output logic        bp_plus12_fetch_odd
);

    logic        inst_buf_before_window;
    logic        skip_inst0_valid;
    logic        inst_buf_bp_taken;
    logic [31:0] inst_buf_bp_target;
    logic [ 7:0] inst_buf_bp_ghr_snap;
    logic        inst_buf_bp_btb_hit;
    logic [ 1:0] inst_buf_bp_btb_type;
    logic [ 1:0] inst_buf_bp_btb_bht;
    logic [ 1:0] inst_buf_bp_pht_cnt;
    logic [ 1:0] inst_buf_bp_sel_cnt;
    logic [11:0] inst_buf_bp_even_addr;
    logic [11:0] inst_buf_bp_odd_addr;
    logic        inst_buf_bp_fetch_odd;
    logic        skip_bp_taken_r;
    logic [31:0] skip_bp_target_r;
    logic [ 7:0] skip_bp_ghr_snap_r;
    logic        skip_bp_btb_hit_r;
    logic [ 1:0] skip_bp_btb_type_r;
    logic [ 1:0] skip_bp_btb_bht_r;
    logic [ 1:0] skip_bp_pht_cnt_r;
    logic [ 1:0] skip_bp_sel_cnt_r;
    logic [11:0] skip_bp_even_addr_r;
    logic [11:0] skip_bp_odd_addr_r;
    logic        skip_bp_fetch_odd_r;
    logic [31:0] irom_inst0_held;
    logic [31:0] irom_inst1_held;
    logic [31:0] irom_pc_held;
    logic        irom_bp_taken_held;
    logic [31:0] irom_bp_target_held;
    logic [11:0] irom_bp_even_addr_held;
    logic [11:0] irom_bp_odd_addr_held;
    logic        irom_bp_fetch_odd_held;
    logic [ 7:0] irom_bp_ghr_snap_held;
    logic        irom_bp_btb_hit_held;
    logic [ 1:0] irom_bp_btb_type_held;
    logic [ 1:0] irom_bp_btb_bht_held;
    logic [ 1:0] irom_bp_pht_cnt_held;
    logic [ 1:0] irom_bp_sel_cnt_held;
    logic        irom_skip_held;

    assign if_skip_inst0 = skip_inst0_valid;
    assign if_buf_before_window = inst_buf_valid & inst_buf_before_window;

    wire [31:0] if_pc_live = if_skip_inst0 ? pc_plus4 :
                              inst_buf_valid ? inst_buf_pc : pc;
    wire [31:0] if_inst0_live = if_skip_inst0 ? irom_inst1 :
                                 inst_buf_valid ? inst_buf : irom_inst0;
    wire [31:0] if_inst1_live = if_buf_before_window ? irom_inst0 : irom_inst1;

    wire        bp_live_taken    = if_skip_inst0 ? skip_bp_taken_r :
                                    if_buf_before_window ? inst_buf_bp_taken : bp_taken;
    wire [31:0] bp_live_target   = if_skip_inst0 ? skip_bp_target_r :
                                    if_buf_before_window ? inst_buf_bp_target : bp_target;
    wire [ 7:0] bp_live_ghr_snap = if_skip_inst0 ? skip_bp_ghr_snap_r :
                                    if_buf_before_window ? inst_buf_bp_ghr_snap : bp_ghr_snap;
    wire        bp_live_btb_hit  = if_skip_inst0 ? skip_bp_btb_hit_r :
                                    if_buf_before_window ? inst_buf_bp_btb_hit : bp_btb_hit;
    wire [ 1:0] bp_live_btb_type = if_skip_inst0 ? skip_bp_btb_type_r :
                                    if_buf_before_window ? inst_buf_bp_btb_type : bp_btb_type;
    wire [ 1:0] bp_live_btb_bht  = if_skip_inst0 ? skip_bp_btb_bht_r :
                                    if_buf_before_window ? inst_buf_bp_btb_bht : bp_btb_bht;
    wire [ 1:0] bp_live_pht_cnt  = if_skip_inst0 ? skip_bp_pht_cnt_r :
                                    if_buf_before_window ? inst_buf_bp_pht_cnt : bp_pht_cnt;
    wire [ 1:0] bp_live_sel_cnt  = if_skip_inst0 ? skip_bp_sel_cnt_r :
                                    if_buf_before_window ? inst_buf_bp_sel_cnt : bp_sel_cnt;
    wire [11:0] bp_live_even_addr = if_skip_inst0 ? skip_bp_even_addr_r :
                                     if_buf_before_window ? inst_buf_bp_even_addr : bp_target_even_addr;
    wire [11:0] bp_live_odd_addr  = if_skip_inst0 ? skip_bp_odd_addr_r :
                                     if_buf_before_window ? inst_buf_bp_odd_addr : bp_target_odd_addr;
    wire        bp_live_fetch_odd = if_skip_inst0 ? skip_bp_fetch_odd_r :
                                     if_buf_before_window ? inst_buf_bp_fetch_odd : bp_target_fetch_odd;

    assign bp_taken_for_if  = irom_held_valid ? irom_bp_taken_held  : bp_live_taken;
    assign bp_target_for_if = irom_held_valid ? irom_bp_target_held : bp_live_target;
    assign bp_even_addr     = irom_held_valid ? irom_bp_even_addr_held : bp_live_even_addr;
    assign bp_odd_addr      = irom_held_valid ? irom_bp_odd_addr_held  : bp_live_odd_addr;
    assign bp_fetch_odd     = irom_held_valid ? irom_bp_fetch_odd_held : bp_live_fetch_odd;

    wire [11:0] bp_live_plus4_even_addr = if_skip_inst0 ? (skip_bp_odd_addr_r + 12'd1) :
                                           if_buf_before_window ? (inst_buf_bp_odd_addr + 12'd1) :
                                                                  bp_target_plus4_even_addr;
    wire [11:0] bp_live_plus4_odd_addr  = if_skip_inst0 ? skip_bp_even_addr_r :
                                           if_buf_before_window ? inst_buf_bp_even_addr :
                                                                  bp_target_plus4_odd_addr;
    wire        bp_live_plus4_fetch_odd = if_skip_inst0 ? ~skip_bp_fetch_odd_r :
                                           if_buf_before_window ? ~inst_buf_bp_fetch_odd :
                                                                  bp_target_plus4_fetch_odd;
    wire [11:0] bp_live_plus8_even_addr = if_skip_inst0 ? (skip_bp_even_addr_r + 12'd1) :
                                           if_buf_before_window ? (inst_buf_bp_even_addr + 12'd1) :
                                                                  bp_target_plus8_even_addr;
    wire [11:0] bp_live_plus8_odd_addr  = if_skip_inst0 ? (skip_bp_odd_addr_r + 12'd1) :
                                           if_buf_before_window ? (inst_buf_bp_odd_addr + 12'd1) :
                                                                  bp_target_plus8_odd_addr;
    wire        bp_live_plus8_fetch_odd = if_skip_inst0 ? skip_bp_fetch_odd_r :
                                           if_buf_before_window ? inst_buf_bp_fetch_odd :
                                                                  bp_target_plus8_fetch_odd;
    wire [11:0] bp_live_plus12_even_addr = if_skip_inst0 ? (skip_bp_odd_addr_r + 12'd2) :
                                            if_buf_before_window ? (inst_buf_bp_odd_addr + 12'd2) :
                                                                   bp_target_plus12_even_addr;
    wire [11:0] bp_live_plus12_odd_addr  = if_skip_inst0 ? (skip_bp_even_addr_r + 12'd1) :
                                            if_buf_before_window ? (inst_buf_bp_even_addr + 12'd1) :
                                                                   bp_target_plus12_odd_addr;
    wire        bp_live_plus12_fetch_odd = if_skip_inst0 ? ~skip_bp_fetch_odd_r :
                                            if_buf_before_window ? ~inst_buf_bp_fetch_odd :
                                                                   bp_target_plus12_fetch_odd;

    assign bp_plus4_even_addr  = irom_held_valid ? (irom_bp_odd_addr_held + 12'd1) : bp_live_plus4_even_addr;
    assign bp_plus4_odd_addr   = irom_held_valid ? irom_bp_even_addr_held : bp_live_plus4_odd_addr;
    assign bp_plus4_fetch_odd  = irom_held_valid ? ~irom_bp_fetch_odd_held : bp_live_plus4_fetch_odd;
    assign bp_plus8_even_addr  = irom_held_valid ? (irom_bp_even_addr_held + 12'd1) : bp_live_plus8_even_addr;
    assign bp_plus8_odd_addr   = irom_held_valid ? (irom_bp_odd_addr_held + 12'd1) : bp_live_plus8_odd_addr;
    assign bp_plus8_fetch_odd  = irom_held_valid ? irom_bp_fetch_odd_held : bp_live_plus8_fetch_odd;
    assign bp_plus12_even_addr = irom_held_valid ? (irom_bp_odd_addr_held + 12'd2) : bp_live_plus12_even_addr;
    assign bp_plus12_odd_addr  = irom_held_valid ? (irom_bp_even_addr_held + 12'd1) : bp_live_plus12_odd_addr;
    assign bp_plus12_fetch_odd = irom_held_valid ? ~irom_bp_fetch_odd_held : bp_live_plus12_fetch_odd;

    assign if_inst0_out = irom_held_valid ? irom_inst0_held : if_inst0_live;
    assign if_inst1_out = irom_held_valid ? irom_inst1_held : if_inst1_live;
    assign if_pc_out    = irom_held_valid ? irom_pc_held    : if_pc_live;
    assign if_bp_taken_out    = irom_held_valid ? irom_bp_taken_held    : bp_live_taken;
    assign if_bp_target_out   = irom_held_valid ? irom_bp_target_held   : bp_live_target;
    assign if_bp_ghr_snap_out = irom_held_valid ? irom_bp_ghr_snap_held : bp_live_ghr_snap;
    assign if_bp_btb_hit_out  = irom_held_valid ? irom_bp_btb_hit_held  : bp_live_btb_hit;
    assign if_bp_btb_type_out = irom_held_valid ? irom_bp_btb_type_held : bp_live_btb_type;
    assign if_bp_btb_bht_out  = irom_held_valid ? irom_bp_btb_bht_held  : bp_live_btb_bht;
    assign if_bp_pht_cnt_out  = irom_held_valid ? irom_bp_pht_cnt_held  : bp_live_pht_cnt;
    assign if_bp_sel_cnt_out  = irom_held_valid ? irom_bp_sel_cnt_held  : bp_live_sel_cnt;
    assign if_skip_out        = irom_held_valid ? irom_skip_held        : if_skip_inst0;
    assign buf_bp_pc = if_pc_out + 32'd4;
    assign if_s1_valid = can_dual_issue;
    assign if_sequential_fetch = ~frontend_branch_flush & ~id_bp_redirect_raw & ~if_bp_taken_out;

    wire if_accept = if_valid & if_ready_go & id_allowin;
    wire will_skip_inst0 = 1'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irom_held_valid <= 1'b0;
        else if (id_flush | id_allowin)
            irom_held_valid <= 1'b0;
        else if (!irom_held_valid)
            irom_held_valid <= 1'b1;
    end

    (* keep = "true", max_fanout = 32 *) wire hold_capture_inst = !irom_held_valid & !id_allowin & !id_flush;
    (* keep = "true", max_fanout = 32 *) wire hold_capture_bp0  = !irom_held_valid & !id_allowin & !id_flush;
    (* keep = "true", max_fanout = 32 *) wire hold_capture_bp1  = !irom_held_valid & !id_allowin & !id_flush;

    always_ff @(posedge clk) begin
        if (hold_capture_inst) begin
            irom_inst0_held <= if_inst0_live;
            irom_inst1_held <= if_inst1_live;
            irom_pc_held <= if_pc_live;
            irom_skip_held <= if_skip_inst0;
        end
    end

    always_ff @(posedge clk) begin
        if (hold_capture_bp0) begin
            irom_bp_taken_held <= bp_live_taken;
            irom_bp_target_held <= bp_live_target;
            irom_bp_even_addr_held <= bp_live_even_addr;
            irom_bp_odd_addr_held <= bp_live_odd_addr;
            irom_bp_fetch_odd_held <= bp_live_fetch_odd;
        end
    end

    always_ff @(posedge clk) begin
        if (hold_capture_bp1) begin
            irom_bp_ghr_snap_held <= bp_live_ghr_snap;
            irom_bp_btb_hit_held <= bp_live_btb_hit;
            irom_bp_btb_type_held <= bp_live_btb_type;
            irom_bp_btb_bht_held <= bp_live_btb_bht;
            irom_bp_pht_cnt_held <= bp_live_pht_cnt;
            irom_bp_sel_cnt_held <= bp_live_sel_cnt;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            predict_dual <= 1'b0;
        else if (if_accept & !if_skip_out)
            predict_dual <= 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            skip_inst0_valid <= 1'b0;
        else
            skip_inst0_valid <= will_skip_inst0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skip_bp_taken_r <= 1'b0;
            skip_bp_target_r <= 32'd0;
            skip_bp_ghr_snap_r <= 8'd0;
            skip_bp_btb_hit_r <= 1'b0;
            skip_bp_btb_type_r <= 2'd0;
            skip_bp_btb_bht_r <= 2'd0;
            skip_bp_pht_cnt_r <= 2'd0;
            skip_bp_sel_cnt_r <= 2'd0;
            skip_bp_even_addr_r <= 12'd0;
            skip_bp_odd_addr_r <= 12'd0;
            skip_bp_fetch_odd_r <= 1'b0;
        end else begin
            skip_bp_taken_r <= la_bp_taken;
            skip_bp_target_r <= la_bp_target;
            skip_bp_ghr_snap_r <= la_bp_ghr_snap;
            skip_bp_btb_hit_r <= la_bp_btb_hit;
            skip_bp_btb_type_r <= la_bp_btb_type;
            skip_bp_btb_bht_r <= la_bp_btb_bht;
            skip_bp_pht_cnt_r <= la_bp_pht_cnt;
            skip_bp_sel_cnt_r <= la_bp_sel_cnt;
            skip_bp_even_addr_r <= la_bp_even_addr;
            skip_bp_odd_addr_r <= la_bp_odd_addr;
            skip_bp_fetch_odd_r <= la_bp_fetch_odd;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inst_buf_valid         <= 1'b0;
            inst_buf               <= 32'd0;
            inst_buf_pc            <= 32'd0;
            inst_buf_before_window <= 1'b0;
            inst_buf_bp_taken      <= 1'b0;
            inst_buf_bp_target     <= 32'd0;
            inst_buf_bp_ghr_snap   <= 8'd0;
            inst_buf_bp_btb_hit    <= 1'b0;
            inst_buf_bp_btb_type   <= 2'd0;
            inst_buf_bp_btb_bht    <= 2'd0;
            inst_buf_bp_pht_cnt    <= 2'd0;
            inst_buf_bp_sel_cnt    <= 2'd0;
            inst_buf_bp_even_addr  <= 12'd0;
            inst_buf_bp_odd_addr   <= 12'd0;
            inst_buf_bp_fetch_odd  <= 1'b0;
        end else if (id_flush | if_bp_taken_out | id_bp_redirect_raw) begin
            inst_buf_valid <= 1'b0;
            inst_buf_before_window <= 1'b0;
            inst_buf_bp_taken <= 1'b0;
        end else if (if_accept) begin
            inst_buf_valid         <= inst_buf_valid_next;
            inst_buf               <= if_inst1_out;
            inst_buf_pc            <= if_pc_out + 32'd4;
            inst_buf_before_window <= inst_buf_valid_next & (predict_dual | if_buf_before_window);
            inst_buf_bp_taken      <= buf_bp_taken;
            inst_buf_bp_target     <= buf_bp_target;
            inst_buf_bp_ghr_snap   <= buf_bp_ghr_snap;
            inst_buf_bp_btb_hit    <= buf_bp_btb_hit;
            inst_buf_bp_btb_type   <= buf_bp_btb_type;
            inst_buf_bp_btb_bht    <= buf_bp_btb_bht;
            inst_buf_bp_pht_cnt    <= buf_bp_pht_cnt;
            inst_buf_bp_sel_cnt    <= buf_bp_sel_cnt;
            inst_buf_bp_even_addr  <= buf_bp_even_addr;
            inst_buf_bp_odd_addr   <= buf_bp_odd_addr;
            inst_buf_bp_fetch_odd  <= buf_bp_fetch_odd;
        end
    end

endmodule
