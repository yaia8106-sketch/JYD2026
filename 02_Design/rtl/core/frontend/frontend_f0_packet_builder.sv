// ============================================================
// Module: frontend_f0_packet_builder
// Description: Align one IROM block and build up to two FQ entries.
// Domain: frontend.
// ============================================================

module frontend_f0_packet_builder
    import cpu_defs::*;
(
    input  logic                       accept_base,
    input  logic [31:0]                start_pc,
    input  logic [ 1:0]                base_mask,
    input  logic [63:0]                irom_data,

    input  logic                       steer_taken,
    input  logic                       steer_source_abtb,
    input  logic                       steer_bank,
    input  logic [ 1:0]                steer_cfi_type,
    input  logic [31:0]                steer_target,
    input  frontend_f0_bank_meta_t     bank0_meta,
    input  frontend_f0_bank_meta_t     bank1_meta,

    output logic                       enq0_payload,
    output logic                       enq1_payload,
    output logic                       enq0_valid,
    output logic                       enq1_valid,
    output logic                       kill_after_slot0,
    output frontend_fq_entry_t         entry0,
    output frontend_fq_entry_t         entry1,
    output frontend_pair_meta_t        pair_meta0,
    output frontend_pair_meta_t        pair_meta1
);

    wire [31:0] slot0_inst = start_pc[2] ? irom_data[63:32]
                                          : irom_data[31:0];
    wire [31:0] slot1_inst = start_pc[2] ? 32'h0000_0013
                                          : irom_data[63:32];
    wire [31:0] slot0_pc = start_pc;
    wire [31:0] slot1_pc = start_pc + 32'd4;
    frontend_predecode_t slot0_dec;
    frontend_predecode_t slot1_dec;
    logic slot0_system_redirect;
    logic slot0_branch_owned;
    logic slot1_branch_owned;
    logic slot0_pred_taken;
    logic [31:0] slot0_pred_target;
    logic slot0_pred_source_abtb;
    logic slot1_pred_taken;
    logic [31:0] slot1_pred_target;
    logic slot1_pred_source_abtb;
    logic [7:0] slot0_pht_index;
    logic [1:0] slot0_pht_counter;

    frontend_predecode u_predecode_slot0 (
        .inst    (slot0_inst),
        .decoded (slot0_dec)
    );

    frontend_predecode u_predecode_slot1 (
        .inst    (slot1_inst),
        .decoded (slot1_dec)
    );

    function automatic frontend_fq_entry_t make_entry(
        input logic                  valid,
        input logic [31:0]           pc,
        input logic [31:0]           inst,
        input frontend_predecode_t   decoded,
        input logic                  force_single,
        input logic                  pred_taken,
        input logic [31:0]           pred_target,
        input logic                  pred_source_abtb,
        input logic                  branch_owned,
        input logic [1:0]            final_cfi_type,
        input logic [7:0]            pht_index,
        input logic [1:0]            pht_counter
    );
        begin
            make_entry = '0;
            make_entry.valid = valid;
            make_entry.pc = pc;
            make_entry.inst = inst;
            make_entry.pred_taken = pred_taken;
            make_entry.pred_target = pred_target;
            make_entry.pred_source_abtb = pred_source_abtb;
            make_entry.stage1_branch_owned = branch_owned;
            make_entry.pred_cfi_type = branch_owned
                                     ? ABTB_TYPE_BRANCH
                                     : pred_taken
                                     ? final_cfi_type
                                     : 2'd0;
            make_entry.stage1_pht_index = pht_index;
            make_entry.stage1_pht_counter = pht_counter;
            make_entry.is_branch = decoded.is_branch;
            make_entry.is_jal = decoded.is_jal;
            make_entry.is_jalr = decoded.is_jalr;
            make_entry.is_system = decoded.is_system;
            make_entry.is_fence = decoded.is_fence;
            make_entry.is_illegal = decoded.is_illegal;
            make_entry.is_muldiv = decoded.is_muldiv;
            make_entry.is_load = decoded.is_load;
            make_entry.is_store = decoded.is_store;
            make_entry.is_alu_type = decoded.is_alu_type;
            make_entry.writes_rd = decoded.writes_rd;
            make_entry.uses_rs1 = decoded.uses_rs1;
            make_entry.uses_rs2 = decoded.uses_rs2;
            make_entry.is_jump = decoded.is_jump;
            make_entry.is_control = decoded.is_control;
            make_entry.is_lsu = decoded.is_lsu;
            make_entry.force_single = force_single;
        end
    endfunction

    function automatic frontend_pair_meta_t make_pair_meta(
        input logic [31:0]         inst,
        input frontend_predecode_t decoded,
        input logic                pred_taken,
        input logic                force_single
    );
        begin
            make_pair_meta = '0;
            make_pair_meta.pred_taken = pred_taken;
            make_pair_meta.force_single = force_single;
            make_pair_meta.is_alu_type = decoded.is_alu_type;
            make_pair_meta.is_lsu = decoded.is_lsu;
            make_pair_meta.is_cfi = decoded.is_cfi;
            make_pair_meta.writes_rd = decoded.writes_rd;
            make_pair_meta.uses_rs1 = decoded.uses_rs1;
            make_pair_meta.uses_rs2 = decoded.uses_rs2;
            make_pair_meta.rd = inst[11:7];
            make_pair_meta.rs1 = inst[19:15];
            make_pair_meta.rs2 = inst[24:20];
        end
    endfunction

    always_comb begin
        slot0_system_redirect =
            slot0_dec.is_system && (slot0_inst[14:12] == 3'b000);
        slot0_branch_owned =
            slot0_dec.is_branch
            && (start_pc[2] ? bank1_meta.branch_owned
                            : bank0_meta.branch_owned);
        slot1_branch_owned =
            slot1_dec.is_branch && !start_pc[2] && bank1_meta.branch_owned;

        slot0_pred_taken = steer_taken && (steer_bank == start_pc[2]);
        slot0_pred_target =
            slot0_pred_taken ? steer_target : (slot0_pc + 32'd4);
        slot0_pred_source_abtb = slot0_pred_taken && steer_source_abtb;
        slot1_pred_taken = steer_taken && !start_pc[2] && steer_bank;
        slot1_pred_target = slot1_pred_taken ? steer_target : 32'd0;
        slot1_pred_source_abtb = slot1_pred_taken && steer_source_abtb;

        if (start_pc[2]) begin
            slot0_pht_index = bank1_meta.pht_index;
            slot0_pht_counter = bank1_meta.pht_counter;
        end else begin
            slot0_pht_index = bank0_meta.pht_index;
            slot0_pht_counter = bank0_meta.pht_counter;
        end

        kill_after_slot0 =
            slot0_dec.is_jal
            || slot0_dec.is_jalr
            || slot0_system_redirect
            || slot0_pred_taken;
        enq0_payload = accept_base && base_mask[0];
        enq1_payload = accept_base && base_mask[1];
        enq0_valid = enq0_payload;
        enq1_valid = enq1_payload && !kill_after_slot0;

        entry0 = make_entry(
            enq0_valid,
            slot0_pc,
            slot0_inst,
            slot0_dec,
            slot0_dec.force_single_slot0,
            slot0_pred_taken,
            slot0_pred_target,
            slot0_pred_source_abtb,
            slot0_branch_owned,
            steer_cfi_type,
            slot0_pht_index,
            slot0_pht_counter
        );
        entry1 = make_entry(
            enq1_valid,
            slot1_pc,
            slot1_inst,
            slot1_dec,
            slot1_dec.force_single_slot1,
            slot1_pred_taken,
            slot1_pred_target,
            slot1_pred_source_abtb,
            slot1_branch_owned,
            steer_cfi_type,
            bank1_meta.pht_index,
            bank1_meta.pht_counter
        );

        pair_meta0 = make_pair_meta(
            slot0_inst,
            slot0_dec,
            slot0_pred_taken,
            slot0_dec.force_single_slot0
        );
        pair_meta1 = make_pair_meta(
            slot1_inst,
            slot1_dec,
            slot1_pred_taken,
            slot1_dec.force_single_slot1
        );
    end

endmodule
