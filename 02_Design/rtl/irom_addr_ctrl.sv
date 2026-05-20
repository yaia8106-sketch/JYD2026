// ============================================================
// Module: irom_addr_ctrl
// Description: Frontend PC lookahead registers and IROM bank address muxing.
// ============================================================

module irom_addr_ctrl (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        if_allowin,
    input  logic        predict_dual,
    input  logic        if_buf_before_window,

    input  logic        mem_branch_replay,
    input  logic [31:0] mem_branch_target,
    input  logic        ex_fast_redirect,
    input  logic [31:0] ex_fast_redirect_target,
    input  logic        ex_branch_redirect,
    input  logic        ex_branch_registered_to_target,
    input  logic [31:0] ex_branch_target_pre,
    input  logic [31:0] ex_fallthrough_pc,
    input  logic        ex_system_redirect,
    input  logic [31:0] ex_system_target,
    input  logic [31:0] ex_s1_branch_target,
    input  logic        id_bp_redirect_raw,
    input  logic [31:0] id_redirect_target,

    input  logic        bp_taken_for_if,
    input  logic [31:0] bp_target_for_if,
    input  logic [11:0] bp_even_addr,
    input  logic [11:0] bp_odd_addr,
    input  logic        bp_fetch_odd,
    input  logic [11:0] bp_plus4_even_addr,
    input  logic [11:0] bp_plus4_odd_addr,
    input  logic        bp_plus4_fetch_odd,
    input  logic [11:0] bp_plus8_even_addr,
    input  logic [11:0] bp_plus8_odd_addr,
    input  logic        bp_plus8_fetch_odd,
    input  logic [11:0] bp_plus12_even_addr,
    input  logic [11:0] bp_plus12_odd_addr,
    input  logic        bp_plus12_fetch_odd,

    output logic [31:0] pc_plus4,
    output logic [31:0] pc_plus8,
    output logic [31:0] pc_plus12,
    output logic [31:0] irom_addr,
    output logic [11:0] irom_even_addr,
    output logic [11:0] irom_odd_addr,
    output logic        irom_fetch_odd
);

    function automatic [11:0] irom_even_bank_addr(input logic [31:0] addr);
        irom_even_bank_addr = {1'b0, addr[13:3]} + {11'd0, addr[2]};
    endfunction

    function automatic [11:0] irom_odd_bank_addr(input logic [31:0] addr);
        irom_odd_bank_addr = {1'b0, addr[13:3]};
    endfunction

    function automatic logic irom_bank_fetch_odd(input logic [31:0] addr);
        irom_bank_fetch_odd = addr[2];
    endfunction

    function automatic [31:0] irom_pc_from_bank(
        input logic [11:0] even_addr,
        input logic [11:0] odd_addr,
        input logic        fetch_odd
    );
        logic [10:0] word_bank;
        begin
            word_bank = fetch_odd ? odd_addr[10:0] : even_addr[10:0];
            irom_pc_from_bank = 32'h8000_0000 | {18'd0, word_bank, fetch_odd, 2'b00};
        end
    endfunction

    logic [11:0] pc_plus4_even_addr;
    logic [11:0] pc_plus4_odd_addr;
    logic        pc_plus4_fetch_odd;
    logic [11:0] pc_plus8_even_addr;
    logic [11:0] pc_plus8_odd_addr;
    logic        pc_plus8_fetch_odd;
    logic [11:0] pc_plus12_even_addr;
    logic [11:0] pc_plus12_odd_addr;
    logic        pc_plus12_fetch_odd;
    logic [11:0] mem_branch_even_addr_r;
    logic [11:0] mem_branch_odd_addr_r;
    logic        mem_branch_fetch_odd_r;

    wire predict_dual_seq = if_buf_before_window ? 1'b0 : predict_dual;
    wire [31:0] seq_next_pc        = predict_dual_seq ? pc_plus8  : pc_plus4;
    wire [31:0] seq_next_pc_plus4  = predict_dual_seq ? pc_plus12 : pc_plus8;
    wire [31:0] seq_pc_plus16      = pc_plus12 + 32'd4;
    wire [31:0] seq_pc_plus20      = pc_plus12 + 32'd8;
    wire [31:0] seq_next_pc_plus8  = predict_dual_seq ? seq_pc_plus16 : pc_plus12;
    wire [31:0] seq_next_pc_plus12 = predict_dual_seq ? seq_pc_plus20 : seq_pc_plus16;
    wire [11:0] seq_even_addr      = predict_dual_seq ? pc_plus8_even_addr  : pc_plus4_even_addr;
    wire [11:0] seq_odd_addr       = predict_dual_seq ? pc_plus8_odd_addr   : pc_plus4_odd_addr;
    wire        seq_fetch_odd      = predict_dual_seq ? pc_plus8_fetch_odd  : pc_plus4_fetch_odd;

    wire [11:0] id_redirect_even_addr = irom_even_bank_addr(id_redirect_target);
    wire [11:0] id_redirect_odd_addr  = irom_odd_bank_addr(id_redirect_target);
    wire        id_redirect_fetch_odd = id_redirect_target[2];

    wire [11:0] ex_branch_target_even_addr = irom_even_bank_addr(ex_branch_target_pre);
    wire [11:0] ex_branch_target_odd_addr = irom_odd_bank_addr(ex_branch_target_pre);
    wire        ex_branch_target_fetch_odd = ex_branch_target_pre[2];
    wire [11:0] ex_fallthrough_even_addr = irom_even_bank_addr(ex_fallthrough_pc);
    wire [11:0] ex_fallthrough_odd_addr = irom_odd_bank_addr(ex_fallthrough_pc);
    wire        ex_fallthrough_fetch_odd = ex_fallthrough_pc[2];
    wire [11:0] ex_s1_branch_even_addr = irom_even_bank_addr(ex_s1_branch_target);
    wire [11:0] ex_s1_branch_odd_addr = irom_odd_bank_addr(ex_s1_branch_target);
    wire        ex_s1_branch_fetch_odd = ex_s1_branch_target[2];
    wire [11:0] ex_system_even_addr = irom_even_bank_addr(ex_system_target);
    wire [11:0] ex_system_odd_addr = irom_odd_bank_addr(ex_system_target);
    wire        ex_system_fetch_odd = ex_system_target[2];
    wire [11:0] ex_registered_branch_even_addr = ex_branch_registered_to_target ? ex_branch_target_even_addr
                                                                                 : ex_fallthrough_even_addr;
    wire [11:0] ex_registered_branch_odd_addr = ex_branch_registered_to_target ? ex_branch_target_odd_addr
                                                                               : ex_fallthrough_odd_addr;
    wire        ex_registered_branch_fetch_odd = ex_branch_registered_to_target ? ex_branch_target_fetch_odd
                                                                                : ex_fallthrough_fetch_odd;
    wire [11:0] ex_registered_redirect_even_addr = ex_branch_redirect ? ex_registered_branch_even_addr :
                                                   ex_system_redirect ? ex_system_even_addr :
                                                                        ex_s1_branch_even_addr;
    wire [11:0] ex_registered_redirect_odd_addr = ex_branch_redirect ? ex_registered_branch_odd_addr :
                                                  ex_system_redirect ? ex_system_odd_addr :
                                                                       ex_s1_branch_odd_addr;
    wire        ex_registered_redirect_fetch_odd = ex_branch_redirect ? ex_registered_branch_fetch_odd :
                                                   ex_system_redirect ? ex_system_fetch_odd :
                                                                        ex_s1_branch_fetch_odd;

    assign irom_addr = mem_branch_replay  ? mem_branch_target :
                       ex_system_redirect ? ex_system_target :
                       id_bp_redirect_raw ? id_redirect_target :
                       bp_taken_for_if    ? bp_target_for_if :
                                            seq_next_pc;

    assign irom_even_addr = mem_branch_replay  ? mem_branch_even_addr_r :
                            ex_system_redirect ? ex_system_even_addr :
                            id_bp_redirect_raw ? id_redirect_even_addr :
                            bp_taken_for_if    ? bp_even_addr :
                                                 seq_even_addr;

    assign irom_odd_addr = mem_branch_replay  ? mem_branch_odd_addr_r :
                           ex_system_redirect ? ex_system_odd_addr :
                           id_bp_redirect_raw ? id_redirect_odd_addr :
                           bp_taken_for_if    ? bp_odd_addr :
                                                seq_odd_addr;

    assign irom_fetch_odd = mem_branch_replay  ? mem_branch_fetch_odd_r :
                            ex_system_redirect ? ex_system_fetch_odd :
                            id_bp_redirect_raw ? id_redirect_fetch_odd :
                            bp_taken_for_if    ? bp_fetch_odd :
                                                 seq_fetch_odd;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_plus4 <= 32'h8000_0000;
            pc_plus8 <= 32'h8000_0004;
            pc_plus12 <= 32'h8000_0008;
            pc_plus4_even_addr <= 12'd0;
            pc_plus4_odd_addr <= 12'd0;
            pc_plus4_fetch_odd <= 1'b0;
            pc_plus8_even_addr <= 12'd1;
            pc_plus8_odd_addr <= 12'd0;
            pc_plus8_fetch_odd <= 1'b1;
            pc_plus12_even_addr <= 12'd1;
            pc_plus12_odd_addr <= 12'd1;
            pc_plus12_fetch_odd <= 1'b0;
        end else if (mem_branch_replay) begin
            pc_plus4 <= mem_branch_target + 32'd4;
            pc_plus8 <= mem_branch_target + 32'd8;
            pc_plus12 <= mem_branch_target + 32'd12;
            pc_plus4_even_addr <= irom_even_bank_addr(mem_branch_target + 32'd4);
            pc_plus4_odd_addr <= irom_odd_bank_addr(mem_branch_target + 32'd4);
            pc_plus4_fetch_odd <= irom_bank_fetch_odd(mem_branch_target + 32'd4);
            pc_plus8_even_addr <= irom_even_bank_addr(mem_branch_target + 32'd8);
            pc_plus8_odd_addr <= irom_odd_bank_addr(mem_branch_target + 32'd8);
            pc_plus8_fetch_odd <= irom_bank_fetch_odd(mem_branch_target + 32'd8);
            pc_plus12_even_addr <= irom_even_bank_addr(mem_branch_target + 32'd12);
            pc_plus12_odd_addr <= irom_odd_bank_addr(mem_branch_target + 32'd12);
            pc_plus12_fetch_odd <= irom_bank_fetch_odd(mem_branch_target + 32'd12);
        end else if (ex_fast_redirect) begin
            pc_plus4 <= ex_fast_redirect_target + 32'd4;
            pc_plus8 <= ex_fast_redirect_target + 32'd8;
            pc_plus12 <= ex_fast_redirect_target + 32'd12;
            pc_plus4_even_addr <= irom_even_bank_addr(ex_fast_redirect_target + 32'd4);
            pc_plus4_odd_addr <= irom_odd_bank_addr(ex_fast_redirect_target + 32'd4);
            pc_plus4_fetch_odd <= irom_bank_fetch_odd(ex_fast_redirect_target + 32'd4);
            pc_plus8_even_addr <= irom_even_bank_addr(ex_fast_redirect_target + 32'd8);
            pc_plus8_odd_addr <= irom_odd_bank_addr(ex_fast_redirect_target + 32'd8);
            pc_plus8_fetch_odd <= irom_bank_fetch_odd(ex_fast_redirect_target + 32'd8);
            pc_plus12_even_addr <= irom_even_bank_addr(ex_fast_redirect_target + 32'd12);
            pc_plus12_odd_addr <= irom_odd_bank_addr(ex_fast_redirect_target + 32'd12);
            pc_plus12_fetch_odd <= irom_bank_fetch_odd(ex_fast_redirect_target + 32'd12);
        end else if (!if_allowin) begin
            ;
        end else if (id_bp_redirect_raw) begin
            pc_plus4 <= id_redirect_target + 32'd4;
            pc_plus8 <= id_redirect_target + 32'd8;
            pc_plus12 <= id_redirect_target + 32'd12;
            pc_plus4_even_addr <= irom_even_bank_addr(id_redirect_target + 32'd4);
            pc_plus4_odd_addr <= irom_odd_bank_addr(id_redirect_target + 32'd4);
            pc_plus4_fetch_odd <= irom_bank_fetch_odd(id_redirect_target + 32'd4);
            pc_plus8_even_addr <= irom_even_bank_addr(id_redirect_target + 32'd8);
            pc_plus8_odd_addr <= irom_odd_bank_addr(id_redirect_target + 32'd8);
            pc_plus8_fetch_odd <= irom_bank_fetch_odd(id_redirect_target + 32'd8);
            pc_plus12_even_addr <= irom_even_bank_addr(id_redirect_target + 32'd12);
            pc_plus12_odd_addr <= irom_odd_bank_addr(id_redirect_target + 32'd12);
            pc_plus12_fetch_odd <= irom_bank_fetch_odd(id_redirect_target + 32'd12);
        end else if (bp_taken_for_if) begin
            pc_plus4 <= irom_pc_from_bank(bp_plus4_even_addr, bp_plus4_odd_addr, bp_plus4_fetch_odd);
            pc_plus8 <= irom_pc_from_bank(bp_plus8_even_addr, bp_plus8_odd_addr, bp_plus8_fetch_odd);
            pc_plus12 <= irom_pc_from_bank(bp_plus12_even_addr, bp_plus12_odd_addr, bp_plus12_fetch_odd);
            pc_plus4_even_addr <= bp_plus4_even_addr;
            pc_plus4_odd_addr <= bp_plus4_odd_addr;
            pc_plus4_fetch_odd <= bp_plus4_fetch_odd;
            pc_plus8_even_addr <= bp_plus8_even_addr;
            pc_plus8_odd_addr <= bp_plus8_odd_addr;
            pc_plus8_fetch_odd <= bp_plus8_fetch_odd;
            pc_plus12_even_addr <= bp_plus12_even_addr;
            pc_plus12_odd_addr <= bp_plus12_odd_addr;
            pc_plus12_fetch_odd <= bp_plus12_fetch_odd;
        end else begin
            pc_plus4 <= seq_next_pc_plus4;
            pc_plus8 <= seq_next_pc_plus8;
            pc_plus12 <= seq_next_pc_plus12;
            pc_plus4_even_addr <= irom_even_bank_addr(seq_next_pc_plus4);
            pc_plus4_odd_addr <= irom_odd_bank_addr(seq_next_pc_plus4);
            pc_plus4_fetch_odd <= seq_next_pc_plus4[2];
            pc_plus8_even_addr <= irom_even_bank_addr(seq_next_pc_plus8);
            pc_plus8_odd_addr <= irom_odd_bank_addr(seq_next_pc_plus8);
            pc_plus8_fetch_odd <= seq_next_pc_plus8[2];
            pc_plus12_even_addr <= irom_even_bank_addr(seq_next_pc_plus12);
            pc_plus12_odd_addr <= irom_odd_bank_addr(seq_next_pc_plus12);
            pc_plus12_fetch_odd <= seq_next_pc_plus12[2];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_branch_even_addr_r <= 12'd0;
            mem_branch_odd_addr_r <= 12'd0;
            mem_branch_fetch_odd_r <= 1'b0;
        end else begin
            mem_branch_even_addr_r <= ex_registered_redirect_even_addr;
            mem_branch_odd_addr_r <= ex_registered_redirect_odd_addr;
            mem_branch_fetch_odd_r <= ex_registered_redirect_fetch_odd;
        end
    end

endmodule
