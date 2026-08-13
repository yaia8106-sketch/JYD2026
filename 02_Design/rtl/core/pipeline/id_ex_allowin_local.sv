// ============================================================
// Module: id_ex_allowin_local
// Description: Placement-local selector for an ID/EX payload cluster.
// Domain: pipeline boundary.
//
// Multiple instances deliberately keep this low-fanout late selector beside
// each payload register cluster instead of rebuilding one global enable net.
// ============================================================

(* keep_hierarchy = "yes" *)
module id_ex_allowin_local (
    input  logic cache_ready,
    input  logic allow_if_cache_ready,
    input  logic allow_if_cache_wait,
    (* keep = "true" *) output logic allowin
);

    always_comb begin
        allowin = cache_ready ? allow_if_cache_ready
                              : allow_if_cache_wait;
    end

endmodule
