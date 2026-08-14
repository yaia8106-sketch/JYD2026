// ============================================================
// 中文说明：根据操作数相关性、流水线状态和访存结果是否可修复，决定 ID 阶段是否允许发射。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：负责 ID 阶段的相关性策略和发射就绪判断。
// 操作数数据选择由 forwarding.sv 完成；本模块只使用寄存器元数据和
// 前递优先级匹配结果，决定 ID 能否前进，以及哪些已就绪的 MEM load
// 可以在 EX 使用 WB 修复值。
// ============================================================

module issue_hazard_ctrl (
    // slot0 的 ID 消费者
    input  logic [4:0] id_rs1_addr,
    input  logic [4:0] id_rs2_addr,
    input  logic       id_rs1_used,
    input  logic       id_rs2_used,
    input  logic       id_s0_repair_ok,
    input  logic       id_s0_is_mul,

    // slot1 的 ID 消费者
    input  logic       id_s1_valid,
    input  logic [4:0] id_s1_rs1_addr,
    input  logic [4:0] id_s1_rs2_addr,
    input  logic       id_s1_rs1_used,
    input  logic       id_s1_rs2_used,
    input  logic       id_s1_repair_ok,

    // 物理局部的 EX 生产者元数据
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

    // MEM 生产者元数据
    input  logic       mem_s0_valid,
    input  logic       mem_s0_reg_write,
    input  logic       mem_s0_is_load,
    input  logic [4:0] mem_s0_rd,
    input  logic       mem_s1_valid,
    input  logic       mem_s1_reg_write,
    input  logic       mem_s1_is_load,
    input  logic [4:0] mem_s1_rd,
    input  logic       mem_load_ready,

    // 更年轻的前递匹配会压制更老的 MEM 修复来源。
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

    // 传入 EX 的修复标签
    output logic       id_rs1_wb_repair,
    output logic       id_rs2_wb_repair,
    output logic       id_rs1_wb_repair_s1,
    output logic       id_rs2_wb_repair_s1,
    output logic       id_s1_rs1_wb_repair,
    output logic       id_s1_rs2_wb_repair,
    output logic       id_s1_rs1_wb_repair_s1,
    output logic       id_s1_rs2_wb_repair_s1,

    // 发射就绪状态
    output logic       id_ready_go,
    output logic       id_ready_go_if_mem_ready,
    output logic       id_ready_go_if_mem_wait,
    output logic       id_non_load_hazard,

    // forwarding.sv 保留的具名观察信号
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

    // 只有当前递网络中没有更年轻生产者压过候选 MEM load 时，修复标签
    // 才有效。
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

    // 修复后的 EX 结果在下一周期从 MEM 变成普通前递来源。只有真正的
    // 消费者需要在修复结果仍处于 EX 时等待。
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

    // MUL 在寄存结果可见前就离开 EX。DIV/REM 运行期间也满足这个条件，
    // 但它们的主要阻塞来源仍然是 EX 反压。
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

    // 已预启动的 slot0 MUL 在进入 EX 时采样 DSP 输入。如果某个输入仍由
    // EX 中的生产者产生，就把启动延后一拍，重试时使用普通 MEM 前递。
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

    // EX-load 相关性与 MEM/DCache 是否就绪无关。把它放在公共的末端
    // hazard 条件中，不要把地址比较复制到两个 MEM-ready 分支中。
    assign id_non_load_hazard = repair_use_hazard | muldiv_use_hazard
                              | mul_launch_ex_raw_hazard
                              | load_in_ex | load_in_s1_ex;
    assign id_ready_go_if_mem_ready = ~load_use_hazard_if_mem_ready;
    assign id_ready_go_if_mem_wait = ~load_use_hazard_if_mem_wait;
    assign id_ready_go = (mem_load_ready ? id_ready_go_if_mem_ready
                                         : id_ready_go_if_mem_wait)
                       & ~id_non_load_hazard;

endmodule
