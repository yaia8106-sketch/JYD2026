`timescale 1ns / 1ps
// ============================================================
// Module: student_top
// Description: 顶层连线，集成 cpu_top + IROM + DCache + memory backend + DRAM + mmio_bridge
//
// 层次结构:
//   top.sv (模板，不可修改)
//     └── student_top (本文件)
//           ├── cpu_top         (自研 RV32I 五级流水线)
//           ├── IROM            (BRAM ROM, 无 output register, 1 拍)
//           ├── dcache          (2KB 2-way WT+WNA data cache)
//           │     └── dcache_bram_backend
//           │           └── DRAM (BRAM RAM, SDP, 65536×32)
//           └── mmio_bridge     (LED/SEG/SW/KEY/CNT)
//
// 复位约定:
//   top.sv 传入 w_clk_rst = ~pll_locked (高有效)
//   student_top 内部对 CPU 时钟域做 async assert / sync release
//   cpu_top 需要 rst_n (低有效) → 使用同步释放后的反相信号
//   mmio_bridge 需要 rst (高有效) → 使用同步释放后的高有效信号
// ============================================================

module student_top #(
    parameter P_SW_CNT  = 64,
    parameter P_LED_CNT = 32,
    parameter P_SEG_CNT = 40,
    parameter P_KEY_CNT = 8
) (
    input                            w_cpu_clk,
    input                            w_clk_50Mhz,
    input                            w_clk_rst,      // 高有效复位
    input  [P_KEY_CNT - 1:0]         virtual_key,
    input  [P_SW_CNT  - 1:0]         virtual_sw,

    output [P_LED_CNT - 1:0]         virtual_led,
    output [P_SEG_CNT - 1:0]         virtual_seg
);

    // ================================================================
    //  内部连线
    // ================================================================

    // CPU ↔ IROM
    logic [63:0] irom_data;
    logic [11:0] irom_addr;

    // CPU ↔ DCache
    logic        cache_req;
    logic        cache_wr;
    logic [31:0] cache_addr;
    logic [ 3:0] cache_wea;
    logic [31:0] cache_wdata;
    logic [31:0] cache_rdata;
    logic        cache_ready;

    // CPU ↔ MMIO bridge
    logic [31:0] mmio_addr;
    logic [31:0] mmio_wr_addr;
    logic [ 3:0] mmio_wea;
    logic [31:0] mmio_wdata;
    logic [31:0] mmio_rdata;
    logic        timer_irq_pending;

    // DCache ↔ memory backend
    logic        dmem_req_valid;
    logic        dmem_req_ready;
    logic        dmem_req_write;
    logic [31:0] dmem_req_addr;
    logic [ 7:0] dmem_req_len;
    logic [31:0] dmem_req_wdata;
    logic [ 3:0] dmem_req_wstrb;
    logic        dmem_rd_valid;
    logic        dmem_rd_ready;
    logic [31:0] dmem_rd_data;
    logic        dmem_rd_last;
    logic [ 1:0] dmem_rd_resp;
    logic        dmem_rd_cancel;
    logic        dmem_wr_valid;
    logic        dmem_wr_ready;
    logic [ 1:0] dmem_wr_resp;

    // BRAM backend ↔ DRAM BRAM
    logic [15:0] dram_rd_addr;
    logic [31:0] dram_rdata;
    logic [15:0] dram_wr_addr;
    logic [ 3:0] dram_wea;
    logic [31:0] dram_wdata;

    // DCache flush — driven by cpu_top's cache_flush output
    logic dcache_flush;

    // DCache pipeline sync — driven by cpu_top's ~mem_allowin
    logic cache_pipeline_stall;

    // ================================================================
    //  Reset synchronizer
    //  w_clk_rst comes from PLL locked in the contest top. Keep assertion
    //  asynchronous, but release reset on w_cpu_clk to avoid board-only
    //  startup hazards in CPU/DCache/BRAM control paths.
    // ================================================================
    logic [1:0] cpu_rst_pipe;
    logic       cpu_rst;
    logic       cpu_rst_n;

    always_ff @(posedge w_cpu_clk or posedge w_clk_rst) begin
        if (w_clk_rst)
            cpu_rst_pipe <= 2'b11;
        else
            cpu_rst_pipe <= {cpu_rst_pipe[0], 1'b0};
    end

    assign cpu_rst   = cpu_rst_pipe[1];
    assign cpu_rst_n = ~cpu_rst;

    // ================================================================
    //  CPU Core
    // ================================================================
    cpu_top u_cpu (
        .clk         (w_cpu_clk),
        .rst_n       (cpu_rst_n),

        // IROM 接口 (IF stage)
        .irom_addr      (irom_addr),
        .irom_data   (irom_data),

        // DCache 接口
        .cache_req   (cache_req),
        .cache_wr    (cache_wr),
        .cache_addr  (cache_addr),
        .cache_wea   (cache_wea),
        .cache_wdata (cache_wdata),
        .cache_rdata (cache_rdata),
        .cache_ready (cache_ready),
        .cache_flush (dcache_flush),
        .cache_pipeline_stall (cache_pipeline_stall),

        // MMIO 接口
        .mmio_addr    (mmio_addr),
        .mmio_wr_addr (mmio_wr_addr),
        .mmio_wea     (mmio_wea),
        .mmio_wdata   (mmio_wdata),
        .mmio_rdata   (mmio_rdata),
        .timer_irq_pending (timer_irq_pending)
    );

    // ================================================================
    //  IROM fetch block
    //  One 64-bit ROM entry stores two sequential 32-bit instructions:
    //    irom_data[31:0]  = inst at block_pc
    //    irom_data[63:32] = inst at block_pc + 4
    // ================================================================
    IROM64 u_irom (
        .clka  (w_cpu_clk),
        .addra (irom_addr),
        .douta (irom_data)
    );

    // ================================================================
    //  DCache (2KB, 2-way, WT+WNA, 16B line)
    // ================================================================
    dcache #(
        .BACKEND_CANCEL (1'b1)
    ) u_dcache (
        .clk         (w_cpu_clk),
        .rst_n       (cpu_rst_n),

        // CPU interface
        .cpu_req     (cache_req),
        .cpu_wr      (cache_wr),
        .cpu_addr    (cache_addr),
        .cpu_wea     (cache_wea),
        .cpu_wdata   (cache_wdata),
        .cpu_rdata   (cache_rdata),
        .cpu_ready   (cache_ready),

        // Pipeline synchronization
        .pipeline_stall (cache_pipeline_stall),

        // Flush
        .flush       (dcache_flush),

        // Memory backend interface
        .mem_req_valid (dmem_req_valid),
        .mem_req_ready (dmem_req_ready),
        .mem_req_write (dmem_req_write),
        .mem_req_addr  (dmem_req_addr),
        .mem_req_len   (dmem_req_len),
        .mem_req_wdata (dmem_req_wdata),
        .mem_req_wstrb (dmem_req_wstrb),
        .mem_rd_valid  (dmem_rd_valid),
        .mem_rd_ready  (dmem_rd_ready),
        .mem_rd_data   (dmem_rd_data),
        .mem_rd_last   (dmem_rd_last),
        .mem_rd_resp   (dmem_rd_resp),
        .mem_rd_cancel (dmem_rd_cancel),
        .mem_wr_valid  (dmem_wr_valid),
        .mem_wr_ready  (dmem_wr_ready),
        .mem_wr_resp   (dmem_wr_resp)
    );

    dcache_bram_backend u_dcache_bram_backend (
        .clk           (w_cpu_clk),
        .rst_n         (cpu_rst_n),
        .mem_req_valid (dmem_req_valid),
        .mem_req_ready (dmem_req_ready),
        .mem_req_write (dmem_req_write),
        .mem_req_addr  (dmem_req_addr),
        .mem_req_len   (dmem_req_len),
        .mem_req_wdata (dmem_req_wdata),
        .mem_req_wstrb (dmem_req_wstrb),
        .mem_rd_valid  (dmem_rd_valid),
        .mem_rd_ready  (dmem_rd_ready),
        .mem_rd_data   (dmem_rd_data),
        .mem_rd_last   (dmem_rd_last),
        .mem_rd_resp   (dmem_rd_resp),
        .mem_rd_cancel (dmem_rd_cancel),
        .mem_wr_valid  (dmem_wr_valid),
        .mem_wr_ready  (dmem_wr_ready),
        .mem_wr_resp   (dmem_wr_resp),
        .dram_rd_addr  (dram_rd_addr),
        .dram_rdata    (dram_rdata),
        .dram_wr_addr  (dram_wr_addr),
        .dram_wea      (dram_wea),
        .dram_wdata    (dram_wdata)
    );

    // ================================================================
    //  DRAM (Block Memory Generator RAM, SDP)
    //  配置: 32bit, 65536 depth (256KB), 4-bit WEA, no extra output register (1-cycle read latency)
    //  Port A = 写端口 (from DCache store buffer drain)
    //  Port B = 读端口 (from DCache refill FSM)
    // ================================================================
    DRAM4MyOwn u_dram (
        // 写端口 (Port A)
        .clka  (w_cpu_clk),
        .wea   (dram_wea),
        .addra (dram_wr_addr),
        .dina  (dram_wdata),

        // 读端口 (Port B)
        .clkb  (w_cpu_clk),
        .enb   (1'b1),
        .addrb (dram_rd_addr),
        .doutb (dram_rdata)
    );

    // ================================================================
    //  MMIO Bridge (LED/SEG/SW/KEY/CNT)
    // ================================================================
    mmio_bridge u_mmio (
        .clk     (w_cpu_clk),
        .cnt_clk (w_clk_50Mhz),
        .rst     (cpu_rst),

        // CPU MMIO bus
        .addr     (mmio_addr),
        .wr_addr  (mmio_wr_addr),
        .wea      (mmio_wea),
        .wdata    (mmio_wdata),
        .rdata    (mmio_rdata),
        .timer_irq_pending (timer_irq_pending),

        // 平台 I/O
        .sw      (virtual_sw),
        .key     (virtual_key),
        .led     (virtual_led),
        .seg     (virtual_seg)
    );

endmodule
