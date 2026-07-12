// ============================================================
// Module: frontend_pair_policy
// Description: 判断两条指令是否有配对资格(用于同包及跨包指令的配对处理)
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
    一个是防止system级重定向的时候包1的指令不知道已经重定向了，从而引发边界情况(对此我们怎么解决？强制system指令来的时候拉高中断，清空流水线再处理吗？)
    但是对于第二点，首先contiguous这个信号只是延缓了配对，而非不压入fq。
    其次，重定向引发边界情况不应该由配对单元实现，这种设计显然是有问题的
    !不过，我们在改动的时候的确需要考虑如何处理system级的重定向指令
    */
    // 对于同包指令，contiguous置1；对于跨包指令，contiguous = fq_tail_has_prev && (fq_tail_next_pc == f0_slot0_pc)
    input  logic                contiguous,
    // valid = = accept_base && base_mask[0/1]
    // accept_base= f0_valid_r && f0_epoch_match && !ex_redirect_valid
    input  logic                slot0_valid,
    input  logic                slot1_valid,
    // meta用于判断RAW以及指令类型
    input  frontend_pair_meta_t slot0_meta,
    input  frontend_pair_meta_t slot1_meta,

    output logic                raw_dep, // raw dependency detection
    output logic                pair_supported,
    output logic                pair_ok // 最终的配对许可信号
);

    logic slot0_supported;
    logic slot1_supported;
    logic both_lsu;
    logic both_cfi;

    // Pairing is conservative: only supported instruction classes, no RAW from
    // Slot 0 to Slot 1, no two LSU ops, and no two CFIs in one pair.
    always_comb begin
        raw_dep =
            slot0_meta.writes_rd
            && (slot0_meta.rd != 5'd0)
            && ((slot1_meta.uses_rs1
                 && (slot1_meta.rs1 == slot0_meta.rd))
                || (slot1_meta.uses_rs2
                    && (slot1_meta.rs2 == slot0_meta.rd)));

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
            && !raw_dep
            && pair_supported;
    end

endmodule
