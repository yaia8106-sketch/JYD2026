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

    logic slot1_supported;
    logic both_cfi;
    logic raw_rs1_dep;
    logic raw_rs2_dep;
    logic slot1_is_store;
    logic blocking_raw_dep;
    logic slot0_non_lsu_supported;
    logic pair_supported_if_slot0_lsu;
    logic pair_supported_if_slot0_non_lsu;
    logic pair_common_ok;
    (* keep = "true" *) logic pair_ok_if_slot0_lsu;
    (* keep = "true" *) logic pair_ok_if_slot0_non_lsu;

    // Pairing is conservative: only supported instruction classes, no two LSU
    // ops, no two CFIs, and no Slot 0 -> Slot 1 RAW except the explicit
    // ALU-to-store-data bypass below. A multiplier may be the Slot 0 producer,
    // but cannot use that same-cycle ALU-to-store-data bypass.
    always_comb begin
        raw_rs1_dep = slot0_meta.writes_dst
                    && (slot0_meta.dst_addr != 5'd0)
                    && slot1_meta.uses_src0
                    && (slot1_meta.src0_addr == slot0_meta.dst_addr);
        raw_rs2_dep = slot0_meta.writes_dst
                    && (slot0_meta.dst_addr != 5'd0)
                    && slot1_meta.uses_src1
                    && (slot1_meta.src1_addr == slot0_meta.dst_addr);
        raw_dep = raw_rs1_dep | raw_rs2_dep;

        // In the current ISA subset, a store is the only LSU class that uses
        // rs2. Its address (rs1) must remain independent, while its data can
        // consume the Slot 0 ALU result through the EX same-pair bypass.
        slot1_is_store = slot1_meta.is_lsu & slot1_meta.uses_src1;
        // Exact reduction of raw_dep & ~store_data_bypassable: an rs1 RAW
        // always blocks; an rs2-only RAW is allowed only for ALU -> store data.
        blocking_raw_dep = raw_rs1_dep
                         | (raw_rs2_dep
                            & ~(slot0_meta.is_alu_type & slot1_is_store));

        slot0_non_lsu_supported = slot0_meta.is_alu_type
                                | slot0_meta.is_cfi
                                | slot0_meta.is_muldiv;
        slot1_supported =
            slot1_meta.is_alu_type | slot1_meta.is_lsu | slot1_meta.is_cfi;
        both_cfi = slot0_meta.is_cfi & slot1_meta.is_cfi;

        // Cofactor the class policy on Slot 0 LSU. Its late predecode bit now
        // selects between two precomputed one-bit candidates instead of
        // reconverging through supported and both_lsu terms.
        pair_supported_if_slot0_lsu = slot1_supported
                                    & ~slot1_meta.is_lsu
                                    & ~both_cfi;
        pair_supported_if_slot0_non_lsu = slot0_non_lsu_supported
                                        & slot1_supported
                                        & ~both_cfi;
        pair_supported = slot0_meta.is_lsu
                       ? pair_supported_if_slot0_lsu
                       : pair_supported_if_slot0_non_lsu;

        pair_common_ok = slot0_valid
                      && slot1_valid
                      && contiguous // 两条指令的PC连续
                      && !slot0_meta.pred_taken
                      && !slot0_meta.force_single // slot0不强制单发射
                      && !slot1_meta.force_single // slot1不强制单发射
                      && !blocking_raw_dep;
        pair_ok_if_slot0_lsu = pair_common_ok
                             & pair_supported_if_slot0_lsu;
        pair_ok_if_slot0_non_lsu = pair_common_ok
                                 & pair_supported_if_slot0_non_lsu;
        pair_ok = slot0_meta.is_lsu ? pair_ok_if_slot0_lsu
                                    : pair_ok_if_slot0_non_lsu;
    end

endmodule
