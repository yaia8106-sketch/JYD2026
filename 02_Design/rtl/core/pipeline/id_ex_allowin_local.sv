// ============================================================
// 中文说明：为 ID/EX 的局部寄存器簇生成局部时钟使能，减少远距离高扇出控制线。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：为一个 ID/EX payload 寄存器簇生成局部的 allowin 选择。
// 多个实例分别靠近自己控制的寄存器簇，保持末端选择信号低扇出，
// 不重新构造一根跨越全局的使能线。
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
