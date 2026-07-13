// ============================================================
// Module: frontend_pair_policy
// Description: Stateless dual-issue pairing policy.
// Domain: frontend.
// ============================================================

module frontend_pair_policy
    import cpu_defs::*;
(
    /*
    这个contiguous是用来检测两条指令的地址是否连续的，是设计上的败笔，理由如下：
    首先我们在配对时有两次检测：
    一次检测当前指令包的slot0能否和上一个包残留的slot1进行配对，
    一次是检测当前指令包的slot0能否和当前指令包的slot1进行配对。
    在frontend_ftq这个模块中，我们让同包的配对检测中contiguous置1，跨包检测中contiguous的值根据PC来判断，若两个包的PC连续，就允许配对。
    但是这有什么意义？我本来想说这东西有两个功能：
    一个是防止包0的指令预测为跳转时不对包1的指令进行发射。但是显然我们的flush能单独对slot1进行冲刷，所以可以放开限制。
    一个是防止system级重定向的时候包1的指令不知道已经重定向了，从而引发边界情况
    但是对于第二点，首先contiguous这个信号只是延缓了配对，而非不压入fq。
    其次，重定向引发边界情况不应该由配对单元实现，这种设计显然是有问题的
    !不过，我们在改动的时候的确需要考虑如何处理system级的重定向指令
    */
    input  logic                contiguous,
    input  logic                slot0_valid,
    input  logic                slot1_valid,
    input  frontend_pair_meta_t slot0_meta,
    input  frontend_pair_meta_t slot1_meta,

    output logic                raw_dep,
    output logic                pair_supported,
    output logic                pair_ok
);

    logic slot0_supported;
    logic slot1_supported;
    logic both_lsu;
    logic both_cfi;
    logic raw_rs1_dep;
    logic raw_rs2_dep;
    logic slot1_is_store;
    logic store_data_bypassable;
    logic blocking_raw_dep;

    // Pairing is conservative: only supported instruction classes, no two LSU
    // ops, no two CFIs, and no Slot 0 -> Slot 1 RAW except the explicit
    // ALU-to-store-data bypass below.
    always_comb begin
        raw_rs1_dep = slot0_meta.writes_rd
                    && (slot0_meta.rd != 5'd0)
                    && slot1_meta.uses_rs1
                    && (slot1_meta.rs1 == slot0_meta.rd);
        raw_rs2_dep = slot0_meta.writes_rd
                    && (slot0_meta.rd != 5'd0)
                    && slot1_meta.uses_rs2
                    && (slot1_meta.rs2 == slot0_meta.rd);
        raw_dep = raw_rs1_dep | raw_rs2_dep;

        // In the current ISA subset, a store is the only LSU class that uses
        // rs2. Its address (rs1) must remain independent, while its data can
        // consume the Slot 0 ALU result through the EX same-pair bypass.
        slot1_is_store = slot1_meta.is_lsu & slot1_meta.uses_rs2;
        store_data_bypassable = slot0_meta.is_alu_type
                              & slot1_is_store
                              & raw_rs2_dep
                              & ~raw_rs1_dep;
        blocking_raw_dep = raw_dep & ~store_data_bypassable;

        slot0_supported =
            slot0_meta.is_alu_type | slot0_meta.is_lsu | slot0_meta.is_cfi;
        slot1_supported =
            slot1_meta.is_alu_type | slot1_meta.is_lsu | slot1_meta.is_cfi;
        both_lsu = slot0_meta.is_lsu & slot1_meta.is_lsu;
        both_cfi = slot0_meta.is_cfi & slot1_meta.is_cfi;

        pair_supported =
            slot0_supported & slot1_supported & ~both_lsu & ~both_cfi;
        pair_ok =
               slot0_valid
            && slot1_valid
            && contiguous // 两条指令的PC连续
            && !slot0_meta.pred_taken
            && !slot0_meta.force_single // slot0不强制单发射
            && !slot1_meta.force_single // slot1不强制单发射
            && !blocking_raw_dep
            && pair_supported;
    end

endmodule
