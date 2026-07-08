// ============================================================
// Module: frontend_abtb_sidecar
// Description: Banked ABTB metadata storage for the fetch queue.
// Domain: frontend.
// The valid-controlled FQ owns entry lifetime; this sidecar only stores and
// retrieves metadata for the corresponding even/odd queue entries.
// ============================================================

module frontend_abtb_sidecar
    import cpu_defs::*;
#(
    parameter int FQ_DEPTH  = 8,
    parameter int FQ_PTR_W  = $clog2(FQ_DEPTH),
    parameter bit WIDE_META = 1'b0
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       redirect_valid,

    input  logic [31:0]                f0_start_pc,
    input  frontend_abtb_meta_t        f0_bank0_meta,
    input  frontend_abtb_meta_t        f0_bank1_meta,
    input  logic [FQ_PTR_W-1:0]        fq_head,
    input  logic [FQ_PTR_W-1:0]        fq_head_p1,
    input  logic [FQ_PTR_W-1:0]        fq_tail,
    input  logic [FQ_PTR_W-1:0]        fq_tail_p1,
    input  logic                       enq0_valid,
    input  logic                       enq1_payload,
    input  logic                       enq1_valid,

    output frontend_abtb_meta_t        f0_meta0,
    output frontend_abtb_meta_t        f0_meta1,
    output frontend_abtb_meta_t        even_read_data,
    output frontend_abtb_meta_t        odd_read_data,
    output frontend_abtb_meta_t        head0_meta,
    output frontend_abtb_meta_t        head1_meta,

    // Compatibility/debug probes retained at the frontend_ftq boundary.
    output logic                       slot1_write_valid,
    output logic [FQ_PTR_W-1:0]        entry1_ptr,
    output frontend_abtb_meta_t        meta1_write_data,
    output logic                       even_write_entry0,
    output logic                       even_write_entry1,
    output logic                       odd_write_entry0,
    output logic                       odd_write_entry1,
    output logic                       even_write,
    output logic                       odd_write,
    output logic [FQ_PTR_W-2:0]        even_read_row,
    output logic [FQ_PTR_W-2:0]        odd_read_row,
    output logic [FQ_PTR_W-2:0]        even_write_row,
    output logic [FQ_PTR_W-2:0]        odd_write_row,
    output frontend_abtb_meta_t        even_write_data,
    output frontend_abtb_meta_t        odd_write_data
);

    // The sidecar stores ABTB metadata in even/odd banks keyed by FQ pointer
    // parity so the main queue does not grow with optional debug fields.
    (* ram_style = "distributed" *)
    logic even_hit [0:(FQ_DEPTH/2)-1];
    (* ram_style = "distributed" *)
    logic even_way [0:(FQ_DEPTH/2)-1];
    (* ram_style = "distributed" *)
    logic odd_hit [0:(FQ_DEPTH/2)-1];
    (* ram_style = "distributed" *)
    logic odd_way [0:(FQ_DEPTH/2)-1];

    frontend_abtb_meta_t even_wide_read;
    frontend_abtb_meta_t odd_wide_read;

    always_comb begin
        // A fetch beginning at block_pc+4 presents physical bank1 first.
        f0_meta0 = f0_start_pc[2] ? f0_bank1_meta : f0_bank0_meta;
        f0_meta1 = f0_bank1_meta;
    end

    // Read rows are selected so head0/head1 metadata follows queue order even
    // when the head pointer starts on the odd bank.
    assign even_read_row = fq_head[0]
                         ? fq_head_p1[FQ_PTR_W-1:1]
                         : fq_head[FQ_PTR_W-1:1];
    assign odd_read_row = fq_head[FQ_PTR_W-1:1];

    always_comb begin
        even_read_data = '0;
        odd_read_data = '0;

        even_read_data.hit = even_hit[even_read_row];
        even_read_data.way = even_way[even_read_row];
        odd_read_data.hit = odd_hit[odd_read_row];
        odd_read_data.way = odd_way[odd_read_row];
        even_read_data.cfi_type = even_wide_read.cfi_type;
        even_read_data.target = even_wide_read.target;
        even_read_data.pred_taken = even_wide_read.pred_taken;
        even_read_data.pred_target = even_wide_read.pred_target;
        odd_read_data.cfi_type = odd_wide_read.cfi_type;
        odd_read_data.target = odd_wide_read.target;
        odd_read_data.pred_taken = odd_wide_read.pred_taken;
        odd_read_data.pred_target = odd_wide_read.pred_target;
    end

`ifdef ABTB_TB_FAULT_DEQUEUE_SELECT
    assign head0_meta = fq_head[0] ? even_read_data : odd_read_data;
    assign head1_meta = fq_head[0] ? odd_read_data : even_read_data;
`else
    assign head0_meta = fq_head[0] ? odd_read_data : even_read_data;
    assign head1_meta = fq_head[0] ? even_read_data : odd_read_data;
`endif

`ifdef ABTB_TB_FAULT_KILLED_SLOT1_WRITE
    assign slot1_write_valid = enq1_payload;
`else
    assign slot1_write_valid = enq1_valid;
`endif

`ifdef ABTB_TB_FAULT_SLOT1_ROW
    assign entry1_ptr =
        fq_tail_p1 ^ {{(FQ_PTR_W-2){1'b0}}, 2'b10};
`else
    assign entry1_ptr = fq_tail_p1;
`endif

    always_comb begin
        meta1_write_data = f0_meta1;
`ifdef ABTB_TB_FAULT_SLOT1_DATA
        meta1_write_data.hit = !f0_meta1.hit;
`endif
    end

    // Entry 0 writes at tail; entry 1 writes at tail+1 if it survived kill.
    assign even_write_entry0 = enq0_valid && !fq_tail[0];
    assign even_write_entry1 = slot1_write_valid && !fq_tail_p1[0];
    assign odd_write_entry0 = enq0_valid && fq_tail[0];
    assign odd_write_entry1 = slot1_write_valid && fq_tail_p1[0];
    assign even_write = even_write_entry0 || even_write_entry1;
    assign odd_write = odd_write_entry0 || odd_write_entry1;
    assign even_write_row = even_write_entry0
                          ? fq_tail[FQ_PTR_W-1:1]
                          : entry1_ptr[FQ_PTR_W-1:1];
    assign odd_write_row = odd_write_entry0
                         ? fq_tail[FQ_PTR_W-1:1]
                         : entry1_ptr[FQ_PTR_W-1:1];
    assign even_write_data = even_write_entry0 ? f0_meta0
                                               : meta1_write_data;
    assign odd_write_data = odd_write_entry0 ? f0_meta0
                                             : meta1_write_data;

    always_ff @(posedge clk) begin
        if (rst_n && !redirect_valid) begin
            if (even_write) begin
                even_hit[even_write_row] <= even_write_data.hit;
                even_way[even_write_row] <= even_write_data.way;
            end
            if (odd_write) begin
                odd_hit[odd_write_row] <= odd_write_data.hit;
                odd_way[odd_write_row] <= odd_write_data.way;
            end
        end
    end

    generate
        if (WIDE_META) begin : g_wide_meta
            (* ram_style = "distributed" *)
            frontend_abtb_meta_t even_dbg [0:(FQ_DEPTH/2)-1];
            (* ram_style = "distributed" *)
            frontend_abtb_meta_t odd_dbg [0:(FQ_DEPTH/2)-1];

            assign even_wide_read = even_dbg[even_read_row];
            assign odd_wide_read = odd_dbg[odd_read_row];

            always_ff @(posedge clk) begin
                if (rst_n && !redirect_valid) begin
                    if (even_write)
                        even_dbg[even_write_row] <= even_write_data;
                    if (odd_write)
                        odd_dbg[odd_write_row] <= odd_write_data;
                end
            end
        end else begin : g_narrow_meta
            assign even_wide_read = '0;
            assign odd_wide_read = '0;
        end
    endgenerate

endmodule
