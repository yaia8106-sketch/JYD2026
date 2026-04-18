// ============================================================
// Module: cpu_top
// Description: RV32I 5-stage pipeline processor top-level
// Rule: WIRING ONLY — no logic, no assign expressions with operators
// IROM/DRAM: 外部例化，通过端口访问
// ============================================================

module cpu_top (
    input  logic        clk,
    input  logic        rst_n,

    // IROM 接口 (IF stage)
    output logic [31:0] irom_addr,       // = next_pc（预取，IF 阶段）
    input  logic [31:0] irom_data,       // 指令（BRAM 1拍 Clk-to-Q，IF 阶段有效）

    // 外设总线 (EX stage → bridge)
    output logic [31:0] perip_addr,      // = alu_result
    output logic [31:0] perip_addr_sum,  // = alu_sum（加法器直出，跳过 ALU output MUX）
    output logic [3:0]  perip_wea,       // = mem_interface store wea
    output logic [31:0] perip_wdata,     // = store_data_shifted
    input  logic [31:0] perip_rdata      // bridge 返回数据（MEM 阶段有效）
);

    // ================================================================
    //  Internal wires
    // ================================================================

    // ---- PC & IF ----
    wire [31:0] pc;
    wire [31:0] next_pc;
    wire        if_valid;

    // ---- IF/ID ----
    wire        id_valid;
    wire        id_allowin;
    wire        id_ready_go;
    wire [31:0] id_pc;
    wire [31:0] id_inst;           // registered instruction from IF/ID

    // ---- IROM ----
    wire [31:0] irom_dout;         // instruction from BRAM output register

    // ---- Decoder outputs ----
    wire [ 3:0] dec_alu_op;
    wire [ 1:0] dec_alu_src1_sel;
    wire        dec_alu_src2_sel;
    wire        dec_reg_write_en;
    wire [ 1:0] dec_wb_sel;
    wire        dec_mem_read_en;
    wire        dec_mem_write_en;
    wire [ 1:0] dec_mem_size;
    wire        dec_mem_unsigned;
    wire        dec_is_branch;
    wire [ 2:0] dec_branch_cond;
    wire        dec_is_jal;
    wire        dec_is_jalr;
    wire [ 2:0] dec_imm_type;

    // ---- Immediate ----
    wire [31:0] id_imm;

    // ---- Regfile ----
    wire [31:0] rf_rs1_data;
    wire [31:0] rf_rs2_data;

    // ---- Forwarding ----
    wire [31:0] fwd_rs1_data;
    wire [31:0] fwd_rs2_data;

    // ---- ALU src MUX (in ID stage) ----
    wire [31:0] id_alu_src1;
    wire [31:0] id_alu_src2;

    // ---- ID/EX ----
    wire        ex_valid;
    wire        ex_allowin;
    wire [31:0] ex_pc;
    wire [31:0] ex_alu_src1, ex_alu_src2;   // pre-selected in ID
    wire [31:0] ex_rs1_data, ex_rs2_data;   // raw, for branch/store
    wire [ 4:0] ex_rd, ex_rs1_addr, ex_rs2_addr;
    wire [ 3:0] ex_alu_op;
    wire        ex_reg_write_en;
    wire [ 1:0] ex_wb_sel;
    wire        ex_mem_read_en;
    wire        ex_mem_write_en;
    wire [ 1:0] ex_mem_size;
    wire        ex_mem_unsigned;
    wire        ex_is_branch;
    wire [ 2:0] ex_branch_cond;
    wire        ex_is_jal;
    wire        ex_is_jalr;

    // ---- ALU ----
    wire [31:0] alu_result;
    wire [31:0] alu_sum;               // ALU 加法器直出（跳过 output MUX）

    // ---- Branch ----
    wire        branch_flush;
    wire [31:0] branch_target;


    // ---- Store interface (EX stage) ----
    wire [31:0] store_data_shifted;

    // ---- DRAM ----
    wire [ 3:0] dram_wea;
    wire [31:0] dram_dout;             // = perip_rdata (from bridge, MEM stage)

    // ---- EX/MEM ----
    wire        mem_valid;
    wire        mem_allowin;
    wire [31:0] mem_alu_result;
    wire [31:0] mem_pc;
    wire [ 4:0] mem_rd;
    wire        mem_reg_write_en;
    wire [ 1:0] mem_wb_sel;
    wire        mem_mem_read_en;
    wire [ 1:0] mem_mem_size;
    wire        mem_mem_unsigned;

    // ---- MEM/WB ----
    wire        wb_valid;
    wire        wb_allowin;
    wire [31:0] wb_alu_result;
    wire [31:0] wb_pc;
    wire [ 4:0] wb_rd;
    wire        wb_reg_write_en;
    wire [ 1:0] wb_wb_sel;
    wire        wb_is_load;
    wire [ 1:0] wb_mem_size;
    wire        wb_mem_unsigned;
    wire [ 1:0] wb_addr_low;
    wire [31:0] wb_dram_dout;   // registered BRAM output (1-cycle BRAM, captured in MEM/WB)

    // ---- WB ----
    wire [31:0] wb_load_data;
    wire [31:0] wb_write_data;

    // ---- Handshake constants ----
    wire if_ready_go_w  = 1'b1;     // BRAM latency absorbed by pipeline
    wire ex_ready_go_w  = 1'b1;     // No multi-cycle ops (yet)
    wire mem_ready_go_w = 1'b1;     // BRAM latency absorbed by pipeline

    // ---- Flush ----
    wire id_flush = branch_flush;
    wire ex_flush = branch_flush;

    // ---- Register addresses from instruction (ID stage, from IF/ID reg) ----
    wire [4:0] id_rs1_addr = id_inst[19:15];
    wire [4:0] id_rs2_addr = id_inst[24:20];
    wire [4:0] id_rd_addr  = id_inst[11:7];

    // ---- Port assignments ----
    assign perip_addr     = alu_result;         // bridge 地址 (EX stage)
    assign perip_addr_sum = alu_sum;             // bridge 地址判断用（跳过 MUX）
    assign perip_wea      = dram_wea;            // bridge 写使能 (EX stage)
    assign perip_wdata    = store_data_shifted;  // bridge 写数据 (EX stage)
    assign dram_dout   = perip_rdata;       // bridge 读数据 (MEM stage)

    // ================================================================
    //  Module instantiations
    // ================================================================

    // ==================== Pre-IF ====================

    wire [31:0] next_pc;
    wire        if_allowin_w = id_allowin;   // for irom_addr mux

    next_pc_mux u_next_pc_mux (
        .pc       (pc),
        .next_pc  (next_pc)
    );

    assign irom_addr = branch_flush  ? branch_target :   // 分支：预取目标
                       !if_allowin_w ? pc :               // 停顿：保持当前地址
                                       next_pc;           // 正常：预取下一条

    pc_reg u_pc_reg (
        .clk           (clk),
        .rst_n         (rst_n),
        .if_allowin    (id_allowin),    // simplified: if_valid=1, if_ready_go=1
        .if_valid      (if_valid),
        .branch_flush  (branch_flush),
        .branch_target (branch_target),
        .next_pc       (irom_addr),
        .pc            (pc)
    );

    // ==================== IROM: 外部例化，通过 irom_addr/irom_data 端口 ====================

    // ==================== IF/ID ====================

    if_id_reg u_if_id_reg (
        .clk          (clk),
        .rst_n        (rst_n),
        .if_valid     (if_valid),
        .if_ready_go  (if_ready_go_w),
        .id_allowin   (id_allowin),
        .id_valid     (id_valid),
        .id_ready_go  (id_ready_go),
        .ex_allowin   (ex_allowin),
        .id_flush     (id_flush),
        .if_pc        (pc),
        .if_inst      (irom_data),       // BRAM output captured in IF stage
        .id_pc        (id_pc),
        .id_inst      (id_inst)          // registered instruction for ID
    );

    decoder u_decoder (
        .inst           (id_inst),            // from IF/ID register
        .alu_op         (dec_alu_op),
        .alu_src1_sel   (dec_alu_src1_sel),
        .alu_src2_sel   (dec_alu_src2_sel),
        .reg_write_en   (dec_reg_write_en),
        .wb_sel         (dec_wb_sel),
        .mem_read_en    (dec_mem_read_en),
        .mem_write_en   (dec_mem_write_en),
        .mem_size       (dec_mem_size),
        .mem_unsigned   (dec_mem_unsigned),
        .is_branch      (dec_is_branch),
        .branch_cond    (dec_branch_cond),
        .is_jal         (dec_is_jal),
        .is_jalr        (dec_is_jalr),
        .imm_type       (dec_imm_type)
    );



    imm_gen u_imm_gen (
        .inst     (id_inst),                   // from IF/ID register
        .imm_type (dec_imm_type),
        .imm      (id_imm)
    );

    regfile u_regfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (id_rs1_addr),
        .rs2_addr (id_rs2_addr),
        .rs1_data (rf_rs1_data),
        .rs2_data (rf_rs2_data),
        .rd_addr  (wb_rd),
        .rd_data  (wb_write_data),
        .rd_wen   (wb_reg_write_en),
        .rd_valid (wb_valid)
    );

    forwarding u_forwarding (
        .id_rs1_addr    (id_rs1_addr),
        .id_rs2_addr    (id_rs2_addr),
        .rf_rs1_data    (rf_rs1_data),
        .rf_rs2_data    (rf_rs2_data),
        .ex_valid       (ex_valid),
        .ex_reg_write   (ex_reg_write_en),
        .ex_mem_read    (ex_mem_read_en),
        .ex_rd          (ex_rd),
        .ex_alu_result  (alu_result),
        .mem_valid      (mem_valid),
        .mem_reg_write  (mem_reg_write_en),
        .mem_is_load    (mem_mem_read_en),
        .mem_rd         (mem_rd),
        .mem_alu_result (mem_alu_result),
        .wb_valid       (wb_valid),
        .wb_reg_write   (wb_reg_write_en),
        .wb_rd          (wb_rd),
        .wb_write_data  (wb_write_data),
        .id_rs1_data    (fwd_rs1_data),
        .id_rs2_data    (fwd_rs2_data),
        .id_ready_go    (id_ready_go)
    );

    // ALU operand selection (in ID stage to reduce EX critical path)
    alu_src_mux u_alu_src_mux (
        .rs1_data      (fwd_rs1_data),
        .rs2_data      (fwd_rs2_data),
        .pc            (id_pc),
        .imm           (id_imm),
        .alu_src1_sel  (dec_alu_src1_sel),
        .alu_src2_sel  (dec_alu_src2_sel),
        .alu_src1      (id_alu_src1),
        .alu_src2      (id_alu_src2)
    );

    // ==================== ID/EX ====================

    id_ex_reg u_id_ex_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .id_valid         (id_valid),
        .id_ready_go      (id_ready_go),
        .ex_allowin       (ex_allowin),
        .ex_valid         (ex_valid),
        .ex_ready_go      (ex_ready_go_w),
        .mem_allowin      (mem_allowin),
        .ex_flush         (ex_flush),
        .id_pc            (id_pc),
        .id_alu_src1      (id_alu_src1),
        .id_alu_src2      (id_alu_src2),
        .id_rs1_data      (fwd_rs1_data),
        .id_rs2_data      (fwd_rs2_data),
        .id_rd            (id_rd_addr),
        .id_rs1_addr      (id_rs1_addr),
        .id_rs2_addr      (id_rs2_addr),
        .id_alu_op        (dec_alu_op),
        .id_reg_write_en  (dec_reg_write_en),
        .id_wb_sel        (dec_wb_sel),
        .id_mem_read_en   (dec_mem_read_en),
        .id_mem_write_en  (dec_mem_write_en),
        .id_mem_size      (dec_mem_size),
        .id_mem_unsigned  (dec_mem_unsigned),
        .id_is_branch     (dec_is_branch),
        .id_branch_cond   (dec_branch_cond),
        .id_is_jal        (dec_is_jal),
        .id_is_jalr       (dec_is_jalr),
        .ex_pc            (ex_pc),
        .ex_alu_src1      (ex_alu_src1),
        .ex_alu_src2      (ex_alu_src2),
        .ex_rs1_data      (ex_rs1_data),
        .ex_rs2_data      (ex_rs2_data),
        .ex_rd            (ex_rd),
        .ex_rs1_addr      (ex_rs1_addr),
        .ex_rs2_addr      (ex_rs2_addr),
        .ex_alu_op        (ex_alu_op),
        .ex_reg_write_en  (ex_reg_write_en),
        .ex_wb_sel        (ex_wb_sel),
        .ex_mem_read_en   (ex_mem_read_en),
        .ex_mem_write_en  (ex_mem_write_en),
        .ex_mem_size      (ex_mem_size),
        .ex_mem_unsigned  (ex_mem_unsigned),
        .ex_is_branch     (ex_is_branch),
        .ex_branch_cond   (ex_branch_cond),
        .ex_is_jal        (ex_is_jal),
        .ex_is_jalr       (ex_is_jalr)
    );

    // ==================== EX stage ====================
    // ALU operands come directly from ID/EX_reg (pre-selected in ID)

    alu u_alu (
        .alu_op     (ex_alu_op),
        .alu_src1   (ex_alu_src1),
        .alu_src2   (ex_alu_src2),
        .alu_result (alu_result),
        .alu_sum    (alu_sum)
    );

    branch_unit u_branch_unit (
        .rs1_data      (ex_rs1_data),
        .rs2_data      (ex_rs2_data),
        .alu_result    (alu_result),
        .is_branch     (ex_is_branch),
        .branch_cond   (ex_branch_cond),
        .is_jal        (ex_is_jal),
        .is_jalr       (ex_is_jalr),
        .ex_valid      (ex_valid),
        .branch_flush  (branch_flush),
        .branch_target (branch_target)
    );

    // Store interface (EX stage → DRAM)
    mem_interface u_mem_interface (
        // Store side (EX stage)
        .store_valid     (ex_valid),
        .store_en        (ex_mem_write_en),
        .store_addr_low  (alu_result[1:0]),
        .store_mem_size  (ex_mem_size),
        .store_data_in   (ex_rs2_data),
        .store_wea       (dram_wea),
        .store_data_out  (store_data_shifted),
        // Load side (WB stage)
        .load_addr_low   (wb_addr_low),
        .load_mem_size   (wb_mem_size),
        .load_unsigned   (wb_mem_unsigned),
        .load_dram_dout  (wb_dram_dout),    // from MEM/WB register (1-cycle BRAM)
        .load_data_out   (wb_load_data)
    );

    // ==================== DRAM: 外部例化，通过 perip 端口 ====================

    // ==================== EX/MEM ====================

    ex_mem_reg u_ex_mem_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .ex_valid         (ex_valid),
        .ex_ready_go      (ex_ready_go_w),
        .mem_allowin      (mem_allowin),
        .mem_valid        (mem_valid),
        .mem_ready_go     (mem_ready_go_w),
        .wb_allowin       (wb_allowin),
        .ex_alu_result    (alu_result),
        .ex_pc            (ex_pc),
        .ex_rd            (ex_rd),
        .ex_reg_write_en  (ex_reg_write_en),
        .ex_wb_sel        (ex_wb_sel),
        .ex_mem_read_en   (ex_mem_read_en),
        .ex_mem_size      (ex_mem_size),
        .ex_mem_unsigned  (ex_mem_unsigned),
        .mem_alu_result   (mem_alu_result),
        .mem_pc           (mem_pc),
        .mem_rd           (mem_rd),
        .mem_reg_write_en (mem_reg_write_en),
        .mem_wb_sel       (mem_wb_sel),
        .mem_mem_read_en  (mem_mem_read_en),
        .mem_mem_size     (mem_mem_size),
        .mem_mem_unsigned (mem_mem_unsigned)
    );

    // ==================== MEM/WB ====================

    mem_wb_reg u_mem_wb_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .mem_valid        (mem_valid),
        .mem_ready_go     (mem_ready_go_w),
        .wb_allowin       (wb_allowin),
        .wb_valid         (wb_valid),
        .mem_alu_result   (mem_alu_result),
        .mem_pc           (mem_pc),
        .mem_rd           (mem_rd),
        .mem_reg_write_en (mem_reg_write_en),
        .mem_wb_sel       (mem_wb_sel),
        .mem_mem_read_en  (mem_mem_read_en),
        .mem_mem_size     (mem_mem_size),
        .mem_mem_unsigned (mem_mem_unsigned),
        .mem_addr_low     (mem_alu_result[1:0]),
        .wb_alu_result    (wb_alu_result),
        .wb_pc            (wb_pc),
        .wb_rd            (wb_rd),
        .wb_reg_write_en  (wb_reg_write_en),
        .wb_wb_sel        (wb_wb_sel),
        .wb_is_load       (wb_is_load),
        .wb_mem_size      (wb_mem_size),
        .wb_mem_unsigned  (wb_mem_unsigned),
        .wb_addr_low      (wb_addr_low),
        .mem_dram_dout    (dram_dout),      // BRAM output (MEM stage, 1-cycle latency)
        .wb_dram_dout     (wb_dram_dout)    // registered for WB stage
    );

    // ==================== WB stage ====================

    wb_mux u_wb_mux (
        .wb_alu_result (wb_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc         (wb_pc),
        .wb_sel        (wb_wb_sel),
        .wb_write_data (wb_write_data)
    );

endmodule
