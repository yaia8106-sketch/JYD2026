// ============================================================
// Module: dcache_read_result_select
// Description: Placement-local final selector for a DCache read result.
// Domain: data cache response.
//
// Two hierarchy-preserved instances prevent synthesis from merging distant
// response consumers. Only this final mux is duplicated; BRAM lookup, byte
// extraction and sign extension remain shared.
// ============================================================

(* keep_hierarchy = "yes" *)
module dcache_read_result_select (
    input  logic        special_valid,
    input  logic [31:0] formatted_hit,
    input  logic [31:0] formatted_special,
    (* keep = "true" *) output logic [31:0] selected_data
);

    always_comb begin
        if (special_valid)
            selected_data = formatted_special;
        else
            selected_data = formatted_hit;
    end

endmodule
