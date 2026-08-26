// ============================================================
// 中文说明：识别 load-use 相关性，并为可以在 EX 阶段使用的 MEM load 结果生成修复标签。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：检测 load-use 停顿，并为 MEM load 的 WB 修复生成标签。
// forwarding 网络提供更年轻生产者是否阻塞某个 MEM load 修复来源的信息；
// 本模块只负责相关性策略，不选择实际的操作数数据。
// ============================================================

module load_hazard_ctrl (
    // slot0 的 ID 消费者
    input  logic [4:0] id_rs1_addr,
    input  logic [4:0] id_rs2_addr,
    input  logic       id_rs1_used,
    input  logic       id_rs2_used,
    input  logic       id_s0_repair_ok,

    // slot1 的 ID 消费者
    input  logic       id_s1_valid,
    input  logic [4:0] id_s1_rs1_addr,
    input  logic [4:0] id_s1_rs2_addr,
    input  logic       id_s1_rs1_used,
    input  logic       id_s1_rs2_used,
    input  logic       id_s1_repair_ok,

    // EX 阶段的 load 生产者
    input  logic       ex_valid,
    input  logic       ex_mem_read,
    input  logic [4:0] ex_rd,
    input  logic       ex_s1_valid,
    input  logic       ex_s1_mem_read,
    input  logic [4:0] ex_s1_rd,

    // MEM 阶段的 load 生产者
    input  logic       mem_valid,
    input  logic       mem_reg_write,
    input  logic       mem_is_load,
    input  logic [4:0] mem_rd,
    input  logic       mem_s1_valid,
    input  logic       mem_s1_reg_write,
    input  logic       mem_s1_is_load,
    input  logic [4:0] mem_s1_rd,
    input  logic       mem_load_ready,

    // 更年轻的前递来源会压制更老的 MEM-load 修复标签。
    input  logic       s0_rs1_blocks_s0_mem_repair,
    input  logic       s0_rs2_blocks_s0_mem_repair,
    input  logic       s1_rs1_blocks_s0_mem_repair,
    input  logic       s1_rs2_blocks_s0_mem_repair,
    input  logic       s0_rs1_blocks_s1_mem_repair,
    input  logic       s0_rs2_blocks_s1_mem_repair,
    input  logic       s1_rs1_blocks_s1_mem_repair,
    input  logic       s1_rs2_blocks_s1_mem_repair,

    // 传入 EX 的修复标签
    output logic       id_rs1_wb_repair,
    output logic       id_rs2_wb_repair,
    output logic       id_rs1_wb_repair_s1,
    output logic       id_rs2_wb_repair_s1,
    output logic       id_s1_rs1_wb_repair,
    output logic       id_s1_rs2_wb_repair,
    output logic       id_s1_rs1_wb_repair_s1,
    output logic       id_s1_rs2_wb_repair_s1,

    // forwarding 集成外壳保留的具名观察输出。
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
    output logic       load_use_hazard_if_mem_ready,
    output logic       load_use_hazard_if_mem_wait
);

    // 已就绪的 MEM load 会在消费者前进时写入 MEM/WB，消费者在下一周期
    // 的 EX 阶段选择这个已寄存的结果。
    localparam logic ENABLE_MEM_LOAD_WB_REPAIR = 1'b1;

    // MEM load 可能造成阻塞，也可能成为修复来源，取决于数据是否就绪
    // 以及当前消费者是否支持修复。
    wire mem_s0_load_pending = mem_valid & mem_is_load & (mem_rd != 5'd0);
    wire mem_s1_load_pending = mem_s1_valid & mem_s1_is_load
                             & (mem_s1_rd != 5'd0);
    wire mem_s0_load_repair_candidate = mem_s0_load_pending
                                      & mem_reg_write;
    wire mem_s1_load_repair_candidate = mem_s1_load_pending
                                      & mem_s1_reg_write;
    wire id_s0_has_mem_load_repair_path =
        ENABLE_MEM_LOAD_WB_REPAIR & id_s0_repair_ok;
    wire id_s1_has_mem_load_repair_path =
        ENABLE_MEM_LOAD_WB_REPAIR & id_s1_valid & id_s1_repair_ok;

    wire s0_rs1_uses_s0_mem_load = id_rs1_used & (mem_rd == id_rs1_addr);
    wire s0_rs2_uses_s0_mem_load = id_rs2_used & (mem_rd == id_rs2_addr);
    wire s1_rs1_uses_s0_mem_load = id_s1_valid & id_s1_rs1_used
                                 & (mem_rd == id_s1_rs1_addr);
    wire s1_rs2_uses_s0_mem_load = id_s1_valid & id_s1_rs2_used
                                 & (mem_rd == id_s1_rs2_addr);

    wire s0_rs1_uses_s1_mem_load = id_rs1_used & (mem_s1_rd == id_rs1_addr);
    wire s0_rs2_uses_s1_mem_load = id_rs2_used & (mem_s1_rd == id_rs2_addr);
    wire s1_rs1_uses_s1_mem_load = id_s1_valid & id_s1_rs1_used
                                 & (mem_s1_rd == id_s1_rs1_addr);
    wire s1_rs2_uses_s1_mem_load = id_s1_valid & id_s1_rs2_used
                                 & (mem_s1_rd == id_s1_rs2_addr);

    // 每个来源单独保存修复标签，以区分 slot0 MEM 和 slot1 MEM；当两个
    // slot 写同一个 rd 时，EX 仍能保持正常的前递优先级。
    wire id_rs1_wb_repair_s0_candidate = mem_s0_load_repair_candidate
                                       & id_s0_has_mem_load_repair_path
                                       & s0_rs1_uses_s0_mem_load
                                       & ~s0_rs1_blocks_s0_mem_repair;
    wire id_rs2_wb_repair_s0_candidate = mem_s0_load_repair_candidate
                                       & id_s0_has_mem_load_repair_path
                                       & s0_rs2_uses_s0_mem_load
                                       & ~s0_rs2_blocks_s0_mem_repair;
    wire id_s1_rs1_wb_repair_s0_candidate = mem_s0_load_repair_candidate
                                          & id_s1_has_mem_load_repair_path
                                          & s1_rs1_uses_s0_mem_load
                                          & ~s1_rs1_blocks_s0_mem_repair;
    wire id_s1_rs2_wb_repair_s0_candidate = mem_s0_load_repair_candidate
                                          & id_s1_has_mem_load_repair_path
                                          & s1_rs2_uses_s0_mem_load
                                          & ~s1_rs2_blocks_s0_mem_repair;

    wire id_rs1_wb_repair_s1_candidate = mem_s1_load_repair_candidate
                                       & id_s0_has_mem_load_repair_path
                                       & s0_rs1_uses_s1_mem_load
                                       & ~s0_rs1_blocks_s1_mem_repair;
    wire id_rs2_wb_repair_s1_candidate = mem_s1_load_repair_candidate
                                       & id_s0_has_mem_load_repair_path
                                       & s0_rs2_uses_s1_mem_load
                                       & ~s0_rs2_blocks_s1_mem_repair;
    wire id_s1_rs1_wb_repair_s1_candidate = mem_s1_load_repair_candidate
                                          & id_s1_has_mem_load_repair_path
                                          & s1_rs1_uses_s1_mem_load
                                          & ~s1_rs1_blocks_s1_mem_repair;
    wire id_s1_rs2_wb_repair_s1_candidate = mem_s1_load_repair_candidate
                                          & id_s1_has_mem_load_repair_path
                                          & s1_rs2_uses_s1_mem_load
                                          & ~s1_rs2_blocks_s1_mem_repair;

    // 就绪状态故意作为所有修复标签的最后一道门。即使 DCache 还在决定
    // 本周期是否完成 MEM load，上面的相关性/匹配逻辑也可以并行计算候选。
    assign id_rs1_wb_repair = mem_load_ready
                            & (id_rs1_wb_repair_s0_candidate
                               | id_rs1_wb_repair_s1_candidate);
    assign id_rs2_wb_repair = mem_load_ready
                            & (id_rs2_wb_repair_s0_candidate
                               | id_rs2_wb_repair_s1_candidate);
    assign id_rs1_wb_repair_s1 = mem_load_ready
                               & id_rs1_wb_repair_s1_candidate;
    assign id_rs2_wb_repair_s1 = mem_load_ready
                               & id_rs2_wb_repair_s1_candidate;
    assign id_s1_rs1_wb_repair = mem_load_ready
                               & (id_s1_rs1_wb_repair_s0_candidate
                                  | id_s1_rs1_wb_repair_s1_candidate);
    assign id_s1_rs2_wb_repair = mem_load_ready
                               & (id_s1_rs2_wb_repair_s0_candidate
                                  | id_s1_rs2_wb_repair_s1_candidate);
    assign id_s1_rs1_wb_repair_s1 = mem_load_ready
                                  & id_s1_rs1_wb_repair_s1_candidate;
    assign id_s1_rs2_wb_repair_s1 = mem_load_ready
                                  & id_s1_rs2_wb_repair_s1_candidate;

    // ================================================================
    //  Load-use 停顿检测
    // ================================================================
    assign id_s0_uses_ex_load = (id_rs1_used & (ex_rd == id_rs1_addr))
                               | (id_rs2_used & (ex_rd == id_rs2_addr));
    assign id_s1_uses_ex_load = id_s1_valid
                               & ((id_s1_rs1_used & (ex_rd == id_s1_rs1_addr))
                                | (id_s1_rs2_used & (ex_rd == id_s1_rs2_addr)));
    assign load_in_ex = ex_valid & ex_mem_read & (ex_rd != 5'd0)
                      & (id_s0_uses_ex_load | id_s1_uses_ex_load);

    assign id_s0_uses_s1_ex_load =
        (id_rs1_used & (ex_s1_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s1_rd == id_rs2_addr));
    assign id_s1_uses_s1_ex_load = id_s1_valid
                                  & ((id_s1_rs1_used
                                      & (ex_s1_rd == id_s1_rs1_addr))
                                   | (id_s1_rs2_used
                                      & (ex_s1_rd == id_s1_rs2_addr)));
    assign load_in_s1_ex = ex_s1_valid & ex_s1_mem_read & (ex_s1_rd != 5'd0)
                         & (id_s0_uses_s1_ex_load | id_s1_uses_s1_ex_load);

    wire id_s0_uses_s0_mem_load = s0_rs1_uses_s0_mem_load
                                 | s0_rs2_uses_s0_mem_load;
    wire id_s1_uses_s0_mem_load = s1_rs1_uses_s0_mem_load
                                 | s1_rs2_uses_s0_mem_load;
    assign id_s0_uses_mem_load = id_s0_uses_s0_mem_load;
    assign id_s1_uses_mem_load = id_s1_uses_s0_mem_load;
    assign id_s0_uses_s1_mem_load = s0_rs1_uses_s1_mem_load
                                   | s0_rs2_uses_s1_mem_load;
    assign id_s1_uses_s1_mem_load = s1_rs1_uses_s1_mem_load
                                   | s1_rs2_uses_s1_mem_load;

    // 并行计算 MEM 就绪和未就绪两种条件下的结果。load 已就绪时，
    // 只有没有修复路径的消费者需要等待；未就绪时，所有匹配消费者等待。
    // 最后只用一次末端就绪信号选择结果。
    wire load_in_mem_if_ready = mem_s0_load_pending
                              & ((id_s0_uses_s0_mem_load
                                  & ~id_s0_has_mem_load_repair_path)
                                 | (id_s1_uses_s0_mem_load
                                    & ~id_s1_has_mem_load_repair_path));
    wire load_in_s1_mem_if_ready = mem_s1_load_pending
                                 & ((id_s0_uses_s1_mem_load
                                     & ~id_s0_has_mem_load_repair_path)
                                    | (id_s1_uses_s1_mem_load
                                       & ~id_s1_has_mem_load_repair_path));
    wire load_in_mem_if_wait = mem_s0_load_pending
                             & (id_s0_uses_s0_mem_load
                                | id_s1_uses_s0_mem_load);
    wire load_in_s1_mem_if_wait = mem_s1_load_pending
                                & (id_s0_uses_s1_mem_load
                                   | id_s1_uses_s1_mem_load);

    // EX-load 相关性同时属于两种 MEM-ready 条件。这里只保留真正依赖
    // ready 的 MEM hazard；公共 EX 条件由 forwarding 合并到一个末端门控，
    // 避免同一组 ID 地址比较经过两棵 cache-ready 树后再次选择。
    assign load_use_hazard_if_mem_ready = load_in_mem_if_ready
                                        | load_in_s1_mem_if_ready;
    assign load_use_hazard_if_mem_wait = load_in_mem_if_wait
                                       | load_in_s1_mem_if_wait;

    assign load_in_mem = mem_load_ready ? load_in_mem_if_ready
                                        : load_in_mem_if_wait;
    assign load_in_s1_mem = mem_load_ready ? load_in_s1_mem_if_ready
                                           : load_in_s1_mem_if_wait;
    assign load_use_hazard = load_in_ex | load_in_s1_ex
                           | (mem_load_ready
                              ? load_use_hazard_if_mem_ready
                              : load_use_hazard_if_mem_wait);

endmodule
