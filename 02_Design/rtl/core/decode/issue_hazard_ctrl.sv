// ============================================================
// Module: issue_hazard_ctrl
// Description: ID-stage dependency policy and issue readiness.
// Domain: decode and issue.
//
// Operand data selection belongs to forwarding.sv. This module consumes only
// register metadata and forwarding-priority matches, then decides whether ID
// may advance and which ready MEM loads can be repaired from WB in EX.
// ============================================================

module issue_hazard_ctrl (
    // Slot 0 ID consumer
    input  logic [4:0] id_rs1_addr,
    input  logic [4:0] id_rs2_addr,
    input  logic       id_rs1_used,
    input  logic       id_rs2_used,
    input  logic       id_s0_repair_ok,
    input  logic       id_s0_is_mul,

    // Slot 1 ID consumer
    input  logic       id_s1_valid,
    input  logic [4:0] id_s1_rs1_addr,
    input  logic [4:0] id_s1_rs2_addr,
    input  logic       id_s1_rs1_used,
    input  logic       id_s1_rs2_used,
    input  logic       id_s1_repair_ok,

    // Physically local EX producer metadata
    input  logic       ex_s0_valid,
    input  logic       ex_s0_reg_write,
    input  logic       ex_s0_is_muldiv,
    input  logic       ex_s0_mem_read,
    input  logic       ex_s0_result_repair,
    input  logic [4:0] ex_s0_rd,
    input  logic       ex_s1_valid,
    input  logic       ex_s1_reg_write,
    input  logic       ex_s1_mem_read,
    input  logic       ex_s1_result_repair,
    input  logic [4:0] ex_s1_rd,

    // MEM producer metadata
    input  logic       mem_s0_valid,
    input  logic       mem_s0_reg_write,
    input  logic       mem_s0_is_load,
    input  logic [4:0] mem_s0_rd,
    input  logic       mem_s1_valid,
    input  logic       mem_s1_reg_write,
    input  logic       mem_s1_is_load,
    input  logic [4:0] mem_s1_rd,
    input  logic       mem_load_ready,

    // Younger forwarding matches that suppress an older MEM repair source.
    input  logic       s0_rs1_s1_ex_hit,
    input  logic       s0_rs1_s0_ex_hit,
    input  logic       s0_rs1_s1_mem_hit,
    input  logic       s0_rs2_s1_ex_hit,
    input  logic       s0_rs2_s0_ex_hit,
    input  logic       s0_rs2_s1_mem_hit,
    input  logic       s1_rs1_s1_ex_hit,
    input  logic       s1_rs1_s0_ex_hit,
    input  logic       s1_rs1_s1_mem_hit,
    input  logic       s1_rs2_s1_ex_hit,
    input  logic       s1_rs2_s0_ex_hit,
    input  logic       s1_rs2_s1_mem_hit,

    // Repair tags carried into EX
    output logic       id_rs1_wb_repair,
    output logic       id_rs2_wb_repair,
    output logic       id_rs1_wb_repair_s1,
    output logic       id_rs2_wb_repair_s1,
    output logic       id_s1_rs1_wb_repair,
    output logic       id_s1_rs2_wb_repair,
    output logic       id_s1_rs1_wb_repair_s1,
    output logic       id_s1_rs2_wb_repair_s1,

    // Issue readiness
    output logic       id_ready_go,
    output logic       id_ready_go_if_mem_ready,
    output logic       id_ready_go_if_mem_wait,
    output logic       id_non_load_hazard,

    // Named observation signals retained by forwarding.sv
    output logic       id_s0_uses_ex_load,
    output logic       id_s1_uses_ex_load,
    output logic       id_s0_uses_s1_ex_load,
    output logic       id_s1_uses_s1_ex_load,
    output logic       id_s0_uses_mem_load,
    output logic       id_s1_uses_mem_load,
    output logic       id_s0_uses_s1_mem_load,
    output logic       id_s1_uses_s1_mem_load,
    output logic       load_in_ex,
    output logic       load_in_s1_ex,
    output logic       load_in_mem,
    output logic       load_in_s1_mem,
    output logic       load_use_hazard,
    output logic       repair_use_hazard,
    output logic       muldiv_use_hazard,
    output logic       mul_launch_ex_raw_hazard
);

    // A repair tag is valid only when no younger producer has priority over
    // the candidate MEM load in the forwarding network.
    wire s0_rs1_blocks_s0_mem_repair = s0_rs1_s1_ex_hit
                                     | s0_rs1_s0_ex_hit
                                     | s0_rs1_s1_mem_hit;
    wire s0_rs2_blocks_s0_mem_repair = s0_rs2_s1_ex_hit
                                     | s0_rs2_s0_ex_hit
                                     | s0_rs2_s1_mem_hit;
    wire s1_rs1_blocks_s0_mem_repair = s1_rs1_s1_ex_hit
                                     | s1_rs1_s0_ex_hit
                                     | s1_rs1_s1_mem_hit;
    wire s1_rs2_blocks_s0_mem_repair = s1_rs2_s1_ex_hit
                                     | s1_rs2_s0_ex_hit
                                     | s1_rs2_s1_mem_hit;

    wire s0_rs1_blocks_s1_mem_repair = s0_rs1_s1_ex_hit
                                     | s0_rs1_s0_ex_hit;
    wire s0_rs2_blocks_s1_mem_repair = s0_rs2_s1_ex_hit
                                     | s0_rs2_s0_ex_hit;
    wire s1_rs1_blocks_s1_mem_repair = s1_rs1_s1_ex_hit
                                     | s1_rs1_s0_ex_hit;
    wire s1_rs2_blocks_s1_mem_repair = s1_rs2_s1_ex_hit
                                     | s1_rs2_s0_ex_hit;

    wire load_use_hazard_if_mem_ready;
    wire load_use_hazard_if_mem_wait;

    load_hazard_ctrl u_load_hazard_ctrl (
        .id_rs1_addr                    (id_rs1_addr),
        .id_rs2_addr                    (id_rs2_addr),
        .id_rs1_used                    (id_rs1_used),
        .id_rs2_used                    (id_rs2_used),
        .id_s0_repair_ok                (id_s0_repair_ok),
        .id_s1_valid                    (id_s1_valid),
        .id_s1_rs1_addr                 (id_s1_rs1_addr),
        .id_s1_rs2_addr                 (id_s1_rs2_addr),
        .id_s1_rs1_used                 (id_s1_rs1_used),
        .id_s1_rs2_used                 (id_s1_rs2_used),
        .id_s1_repair_ok                (id_s1_repair_ok),
        .ex_valid                       (ex_s0_valid),
        .ex_mem_read                    (ex_s0_mem_read),
        .ex_rd                          (ex_s0_rd),
        .ex_s1_valid                    (ex_s1_valid),
        .ex_s1_mem_read                 (ex_s1_mem_read),
        .ex_s1_rd                       (ex_s1_rd),
        .mem_valid                      (mem_s0_valid),
        .mem_reg_write                  (mem_s0_reg_write),
        .mem_is_load                    (mem_s0_is_load),
        .mem_rd                         (mem_s0_rd),
        .mem_s1_valid                   (mem_s1_valid),
        .mem_s1_reg_write               (mem_s1_reg_write),
        .mem_s1_is_load                 (mem_s1_is_load),
        .mem_s1_rd                      (mem_s1_rd),
        .mem_load_ready                 (mem_load_ready),
        .s0_rs1_blocks_s0_mem_repair    (s0_rs1_blocks_s0_mem_repair),
        .s0_rs2_blocks_s0_mem_repair    (s0_rs2_blocks_s0_mem_repair),
        .s1_rs1_blocks_s0_mem_repair    (s1_rs1_blocks_s0_mem_repair),
        .s1_rs2_blocks_s0_mem_repair    (s1_rs2_blocks_s0_mem_repair),
        .s0_rs1_blocks_s1_mem_repair    (s0_rs1_blocks_s1_mem_repair),
        .s0_rs2_blocks_s1_mem_repair    (s0_rs2_blocks_s1_mem_repair),
        .s1_rs1_blocks_s1_mem_repair    (s1_rs1_blocks_s1_mem_repair),
        .s1_rs2_blocks_s1_mem_repair    (s1_rs2_blocks_s1_mem_repair),
        .id_rs1_wb_repair               (id_rs1_wb_repair),
        .id_rs2_wb_repair               (id_rs2_wb_repair),
        .id_rs1_wb_repair_s1            (id_rs1_wb_repair_s1),
        .id_rs2_wb_repair_s1            (id_rs2_wb_repair_s1),
        .id_s1_rs1_wb_repair            (id_s1_rs1_wb_repair),
        .id_s1_rs2_wb_repair            (id_s1_rs2_wb_repair),
        .id_s1_rs1_wb_repair_s1         (id_s1_rs1_wb_repair_s1),
        .id_s1_rs2_wb_repair_s1         (id_s1_rs2_wb_repair_s1),
        .id_s0_uses_ex_load             (id_s0_uses_ex_load),
        .id_s1_uses_ex_load             (id_s1_uses_ex_load),
        .id_s0_uses_s1_ex_load          (id_s0_uses_s1_ex_load),
        .id_s1_uses_s1_ex_load          (id_s1_uses_s1_ex_load),
        .id_s0_uses_mem_load            (id_s0_uses_mem_load),
        .id_s1_uses_mem_load            (id_s1_uses_mem_load),
        .id_s0_uses_s1_mem_load         (id_s0_uses_s1_mem_load),
        .id_s1_uses_s1_mem_load         (id_s1_uses_s1_mem_load),
        .load_in_ex                     (load_in_ex),
        .load_in_s1_ex                  (load_in_s1_ex),
        .load_in_mem                    (load_in_mem),
        .load_in_s1_mem                 (load_in_s1_mem),
        .load_use_hazard                (load_use_hazard),
        .load_use_hazard_if_mem_ready   (load_use_hazard_if_mem_ready),
        .load_use_hazard_if_mem_wait    (load_use_hazard_if_mem_wait)
    );

    // A repaired EX result becomes ordinarily forwardable from MEM one cycle
    // later. Hold only a true consumer while that repair is still in EX.
    wire id_s0_uses_s0_ex_repair =
        (id_rs1_used & (ex_s0_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s0_rd == id_rs2_addr));
    wire id_s1_uses_s0_ex_repair = id_s1_valid
        & ((id_s1_rs1_used & (ex_s0_rd == id_s1_rs1_addr))
         | (id_s1_rs2_used & (ex_s0_rd == id_s1_rs2_addr)));
    wire id_s0_uses_s1_ex_repair =
        (id_rs1_used & (ex_s1_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s1_rd == id_rs2_addr));
    wire id_s1_uses_s1_ex_repair = id_s1_valid
        & ((id_s1_rs1_used & (ex_s1_rd == id_s1_rs1_addr))
         | (id_s1_rs2_used & (ex_s1_rd == id_s1_rs2_addr)));

    assign repair_use_hazard =
        (ex_s0_valid & ex_s0_reg_write & ex_s0_result_repair
         & (ex_s0_rd != 5'd0)
         & (id_s0_uses_s0_ex_repair | id_s1_uses_s0_ex_repair))
      | (ex_s1_valid & ex_s1_reg_write & ex_s1_result_repair
         & (ex_s1_rd != 5'd0)
         & (id_s0_uses_s1_ex_repair | id_s1_uses_s1_ex_repair));

    // MUL leaves EX before its registered result is visible. DIV/REM also
    // satisfy this predicate while running, with EX backpressure remaining
    // their primary blocker.
    wire id_s0_uses_ex_muldiv =
        (id_rs1_used & (ex_s0_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s0_rd == id_rs2_addr));
    wire id_s1_uses_ex_muldiv = id_s1_valid
        & ((id_s1_rs1_used & (ex_s0_rd == id_s1_rs1_addr))
         | (id_s1_rs2_used & (ex_s0_rd == id_s1_rs2_addr)));

    assign muldiv_use_hazard = ex_s0_valid & ex_s0_is_muldiv
                             & (ex_s0_rd != 5'd0)
                             & (id_s0_uses_ex_muldiv
                                | id_s1_uses_ex_muldiv);

    // A prestarted Slot-0 MUL samples its DSP inputs as it enters EX. If one
    // of those inputs is still being produced in EX, defer launch by one cycle
    // and use the ordinary MEM forwarding path on the retry.
    wire id_mul_uses_s0_ex_writer =
        (id_rs1_used & (ex_s0_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s0_rd == id_rs2_addr));
    wire id_mul_uses_s1_ex_writer =
        (id_rs1_used & (ex_s1_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s1_rd == id_rs2_addr));

    assign mul_launch_ex_raw_hazard = id_s0_is_mul
        & ((ex_s0_valid & ex_s0_reg_write & (ex_s0_rd != 5'd0)
            & id_mul_uses_s0_ex_writer)
         | (ex_s1_valid & ex_s1_reg_write & (ex_s1_rd != 5'd0)
            & id_mul_uses_s1_ex_writer));

    // EX-load dependencies are independent of MEM/DCache readiness. Keep
    // them in the common late hazard term instead of duplicating their address
    // comparisons through both MEM-readiness cofactors.
    assign id_non_load_hazard = repair_use_hazard | muldiv_use_hazard
                              | mul_launch_ex_raw_hazard
                              | load_in_ex | load_in_s1_ex;
    assign id_ready_go_if_mem_ready = ~load_use_hazard_if_mem_ready;
    assign id_ready_go_if_mem_wait = ~load_use_hazard_if_mem_wait;
    assign id_ready_go = (mem_load_ready ? id_ready_go_if_mem_ready
                                         : id_ready_go_if_mem_wait)
                       & ~id_non_load_hazard;

endmodule
