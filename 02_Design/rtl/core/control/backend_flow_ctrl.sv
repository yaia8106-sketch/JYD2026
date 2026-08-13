// ============================================================
// Module: backend_flow_ctrl
// Description:
//   Owns the combinational ready/allow/fire contract from ID through WB.
//   Cache readiness is evaluated as two parallel candidates so the late
//   DCache-ready bit selects one-bit results instead of traversing the full
//   hazard and MulDiv control cone.
//
// Contract:
//   - no architectural or pipeline state is stored here;
//   - flush, serialization and interrupt priority match the original flow;
//   - duplicated allow outputs intentionally serve separate physical users.
// ============================================================

module backend_flow_ctrl (
    input  logic clk,
    input  logic rst_n,

    input  logic cache_ready,
    input  logic wb_allowin,

    input  logic id_valid,
    input  logic id_issue_is_muldiv,
    input  logic id_issue_serializing,
    input  logic id_decoded_serializing,
    input  logic id_ready_go_raw,
    input  logic id_ready_go_raw_if_mem_ready,
    input  logic id_ready_go_raw_if_mem_wait,
    input  logic id_non_load_hazard,
    input  logic id_flush,

    input  logic ex_valid,
    input  logic ex_slot1_valid,
    input  logic ex_is_muldiv,
    input  logic ex_is_divrem,
    input  logic ex_priv_wait_older,
    input  logic mmio_store_load_hazard,

    input  logic mem_valid,
    input  logic mem_slot1_valid,
    input  logic mem_is_mul,
    input  logic mem_branch_flush,

    input  logic wb_valid,
    input  logic wb_slot1_valid,

    input  logic muldiv_busy,
    input  logic muldiv_done,
    input  logic muldiv_consume,
    input  logic serializing_inflight,
    input  logic timer_irq_request,
    input  logic timer_irq_hold,

    output logic ex_muldiv_ready,
    output logic ex_priv_ready,
    output logic ex_priv_commit_ready,
    output logic ex_ready_go,
    output logic mem_ready_go,

    (* keep = "true" *) output logic mem_allowin_lsu,
    (* keep = "true" *) output logic mem_allowin_control,
    (* keep = "true" *) output logic mem_allowin_pipe,

    output logic timer_irq_block,
    output logic id_serializing_ready,
    output logic id_barrier_ready,
    output logic id_muldiv_unit_ready,
    output logic id_ready_go,
    (* keep = "true" *) output logic ex_allowin_if_cache_ready,
    (* keep = "true" *) output logic ex_allowin_if_cache_wait,
    output logic ex_allowin,
    output logic ex_allowin_timing_copy,
    output logic id_allowin,
    (* keep = "true" *) output logic id_allowin_pipe,
    (* keep = "true" *) output logic id_allowin_frontend,
    output logic id_to_ex_fire
);

    logic ex_priv_older_pending;
    logic mem_can_advance;
    logic mem_mul_owner_releases;
    logic muldiv_done_releases_if_cache_ready;
    logic muldiv_done_releases_if_cache_wait;
    logic id_muldiv_done_ready_if_cache_ready;
    logic id_muldiv_done_ready_if_cache_wait;
    logic backend_older_empty;
    logic id_base_ready_if_cache_ready;
    logic id_base_ready_if_cache_wait;
    logic id_muldiv_owner_ready_if_cache_wait;

    (* keep = "true" *) logic id_ready_no_common_if_cache_ready;
    (* keep = "true" *) logic id_ready_no_common_if_cache_wait;
    (* keep = "true" *) logic id_progress_if_cache_ready;
    (* keep = "true" *) logic id_progress_if_cache_wait;

    logic id_ready_no_common;
    logic id_progress_no_common;

    assign ex_muldiv_ready = mem_branch_flush
                           | ~ex_valid
                           | ~ex_is_muldiv
                           | ~ex_is_divrem
                           | muldiv_done;

    assign ex_priv_older_pending = mem_valid | wb_valid
                                 | mem_slot1_valid | wb_slot1_valid;
    assign ex_priv_commit_ready = ~ex_priv_older_pending;
    assign ex_priv_ready = ~ex_priv_wait_older | ~ex_priv_older_pending;
    assign ex_ready_go = ~mmio_store_load_hazard
                       & ex_muldiv_ready
                       & ex_priv_ready;

    // DCache owns MEM completion. Keep three identical copies because their
    // consumers occupy the LSU, control and wide pipeline-register clusters.
    assign mem_ready_go = cache_ready;
    assign mem_can_advance = ~mem_valid | mem_ready_go;
    assign mem_allowin_lsu = ~mem_valid
                           | (mem_ready_go & wb_allowin);
    assign mem_allowin_control = ~mem_valid
                               | (mem_ready_go & wb_allowin);
    assign mem_allowin_pipe = ~mem_valid
                            | (mem_ready_go & wb_allowin);

    assign mem_mul_owner_releases = ~mem_valid | ~mem_is_mul
                                  | mem_ready_go;
    assign id_muldiv_unit_ready = ~id_issue_is_muldiv | ~muldiv_busy;

    // A completed MulDiv owner may be replaced on the same edge that its
    // aligned EX/MEM token advances. Build both cache-ready cases in parallel.
    assign muldiv_done_releases_if_cache_ready =
        (mem_valid & mem_is_mul)
        | (ex_valid & ex_is_muldiv & ex_is_divrem & ~mem_branch_flush);
    assign muldiv_done_releases_if_cache_wait =
        ex_valid & ex_is_muldiv & ex_is_divrem
        & ~mem_valid & ~mem_branch_flush;

    assign id_muldiv_done_ready_if_cache_ready =
        ~id_issue_is_muldiv | ~muldiv_done
        | muldiv_done_releases_if_cache_ready;
    assign id_muldiv_done_ready_if_cache_wait =
        ~id_issue_is_muldiv | ~muldiv_done
        | muldiv_done_releases_if_cache_wait;

    assign backend_older_empty = ~ex_valid & ~mem_valid & ~wb_valid
                               & ~ex_slot1_valid
                               & ~mem_slot1_valid
                               & ~wb_slot1_valid;
    assign id_serializing_ready = ~id_issue_serializing
                                | backend_older_empty;
    assign id_barrier_ready = ~serializing_inflight;
    assign timer_irq_block = timer_irq_request | timer_irq_hold;

    assign id_base_ready_if_cache_ready =
        id_ready_go_raw_if_mem_ready
        & ~timer_irq_block
        & id_serializing_ready
        & id_barrier_ready;
    assign id_base_ready_if_cache_wait =
        id_ready_go_raw_if_mem_wait
        & ~timer_irq_block
        & id_serializing_ready
        & id_barrier_ready;
    assign id_muldiv_owner_ready_if_cache_wait =
        ~id_issue_is_muldiv | ~mem_valid | ~mem_is_mul;

    assign id_ready_no_common_if_cache_ready =
        id_base_ready_if_cache_ready
        & id_muldiv_unit_ready
        & id_muldiv_done_ready_if_cache_ready;
    assign id_ready_no_common_if_cache_wait =
        id_base_ready_if_cache_wait
        & id_muldiv_unit_ready
        & id_muldiv_owner_ready_if_cache_wait
        & id_muldiv_done_ready_if_cache_wait;

    // WB is always ready today. When the cache is waiting, EX may advance only
    // into an empty MEM stage; the two equations stay explicit for placement.
    assign ex_allowin_if_cache_ready = ~ex_valid | ex_ready_go;
    assign ex_allowin_if_cache_wait = ~ex_valid
                                    | (ex_ready_go & ~mem_valid);

    assign id_progress_if_cache_ready =
        id_ready_no_common_if_cache_ready & ex_allowin_if_cache_ready;
    assign id_progress_if_cache_wait =
        id_ready_no_common_if_cache_wait & ex_allowin_if_cache_wait;

    assign id_ready_no_common = cache_ready
                              ? id_ready_no_common_if_cache_ready
                              : id_ready_no_common_if_cache_wait;
    assign id_progress_no_common = cache_ready
                                 ? id_progress_if_cache_ready
                                 : id_progress_if_cache_wait;

    assign id_ready_go = id_ready_no_common & ~id_non_load_hazard;
    assign ex_allowin = cache_ready
                      ? ex_allowin_if_cache_ready
                      : ex_allowin_if_cache_wait;

    // This local selector remains separate from the architectural EX allow net
    // so the narrow ID/EX timing mirrors have a placement-local copy.
    id_ex_allowin_local u_ex_allowin_ex_local (
        .cache_ready         (cache_ready),
        .allow_if_cache_ready(ex_allowin_if_cache_ready),
        .allow_if_cache_wait (ex_allowin_if_cache_wait),
        .allowin             (ex_allowin_timing_copy)
    );

    assign id_allowin = ~id_valid
                      | (id_progress_no_common & ~id_non_load_hazard);
    assign id_allowin_pipe = ~id_valid
                           | (id_progress_no_common & ~id_non_load_hazard);
    assign id_allowin_frontend = ~id_valid
                               | (id_progress_no_common
                                  & ~id_non_load_hazard);

    assign id_to_ex_fire = id_valid
                         & id_progress_no_common
                         & ~id_non_load_hazard
                         & ~id_flush;

`ifndef SYNTHESIS
    logic id_serializing_ready_reference;
    logic id_ready_go_reference;
    logic ex_allowin_reference;
    logic id_allowin_reference;
    logic id_to_ex_fire_reference;

    assign id_serializing_ready_reference = ~id_decoded_serializing
                                          | backend_older_empty;
    assign id_ready_go_reference = id_ready_go_raw
                                 & ~timer_irq_block
                                 & id_serializing_ready_reference
                                 & id_barrier_ready
                                 & id_muldiv_unit_ready
                                 & (~id_issue_is_muldiv | ~muldiv_done
                                    | muldiv_consume)
                                 & (~id_issue_is_muldiv
                                    | mem_mul_owner_releases);
    assign ex_allowin_reference = ~ex_valid
                                | (ex_ready_go & mem_can_advance);
    assign id_allowin_reference = ~id_valid
                                | (id_ready_go_reference
                                   & ex_allowin_reference);
    assign id_to_ex_fire_reference = id_valid
                                   & id_ready_go_reference
                                   & ex_allowin_reference
                                   & ~id_flush;

    always_ff @(posedge clk) begin
        if (rst_n && id_valid && (id_ready_go !== id_ready_go_reference))
            $fatal(1, "Timing-factored id_ready_go changed pipeline handshake");
        if (rst_n && (ex_allowin !== ex_allowin_reference))
            $fatal(1, "Timing-factored ex_allowin changed pipeline handshake");
        if (rst_n && (ex_allowin_timing_copy !== ex_allowin))
            $fatal(1, "EX allowin functional-cluster copies diverged");
        if (rst_n && (id_allowin !== id_allowin_reference))
            $fatal(1, "Timing-factored id_allowin changed pipeline handshake");
        if (rst_n
                  && ((id_allowin_pipe !== id_allowin)
                      || (id_allowin_frontend !== id_allowin)))
            $fatal(1, "ID allowin physical-cluster copies diverged");
        if (rst_n && (id_to_ex_fire !== id_to_ex_fire_reference))
            $fatal(1, "Timing-factored ID-to-EX fire changed pipeline handshake");
    end
`endif

endmodule
