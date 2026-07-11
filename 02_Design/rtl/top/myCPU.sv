`timescale 1ns / 1ps
// ============================================================
// Module: myCPU
// Description:
//   Contest-facing Core_cpu wrapper.  The external ports exactly match the
//   JYD template, while the processor keeps its private 64-bit IROM, DCache,
//   and byte-write-enabled DRAM behind this boundary.
//
//   The template IROM inputs remain connected for interface compatibility;
//   instruction fetches are served by the private IROM64 instance.  The
//   template perip bus is used only for platform MMIO.  Cacheable DRAM
//   accesses never leave Core_cpu.
// ============================================================

module myCPU (
    input  logic        cpu_rst,
    input  logic        cpu_clk,

    // Interface to the template IROM (kept for contract compatibility).
    output logic [31:0] irom_addr,
    input  logic [31:0] irom_data,

    // Interface to the template DRAM/peripheral bridge.  Core_cpu uses this
    // path only for MMIO because DRAM is private behind the DCache.
    output logic [31:0] perip_addr,
    output logic        perip_wen,
    output logic [ 1:0] perip_mask,
    output logic [31:0] perip_wdata,
    input  logic [31:0] perip_rdata
);

    // ================================================================
    // Reset: asynchronous assertion, synchronous release in cpu_clk.
    // ================================================================
    logic [1:0] cpu_rst_pipe;
    logic       cpu_rst_sync;
    logic       cpu_rst_n;

    always_ff @(posedge cpu_clk or posedge cpu_rst) begin
        if (cpu_rst)
            cpu_rst_pipe <= 2'b11;
        else
            cpu_rst_pipe <= {cpu_rst_pipe[0], 1'b0};
    end

    assign cpu_rst_sync = cpu_rst_pipe[1];
    assign cpu_rst_n    = ~cpu_rst_sync;

    // ================================================================
    // CPU <-> private instruction ROM.
    // ================================================================
    logic [11:0] core_irom_addr;
    logic [63:0] core_irom_data;

    // Keep the official address output meaningful for debug even though the
    // returned 32-bit word is intentionally unused by this implementation.
    assign irom_addr = 32'h8000_0000 | {17'd0, core_irom_addr, 3'b000};

    IROM64 u_irom (
        .clka  (cpu_clk),
        .addra (core_irom_addr),
        .douta (core_irom_data)
    );

    // ================================================================
    // CPU <-> DCache.
    // ================================================================
    logic        cache_req;
    logic        cache_wr;
    logic [31:0] cache_addr;
    logic [ 3:0] cache_wea;
    logic [31:0] cache_wdata;
    logic [ 3:0] cache_load_mask;
    logic [31:0] cache_rdata;
    logic        cache_ready;
    logic        dcache_flush;
    logic        cache_pipeline_stall;

    // ================================================================
    // CPU <-> MMIO adapter.
    // ================================================================
    logic [31:0] mmio_addr;
    logic [31:0] mmio_wr_addr;
    logic [ 3:0] mmio_wea;
    logic [31:0] mmio_wdata;
    logic [31:0] mmio_rdata;
    logic        timer_irq_pending;

    cpu_top u_cpu (
        .clk                  (cpu_clk),
        .rst_n                (cpu_rst_n),
        .irom_addr            (core_irom_addr),
        .irom_data            (core_irom_data),
        .cache_req            (cache_req),
        .cache_wr             (cache_wr),
        .cache_addr           (cache_addr),
        .cache_wea            (cache_wea),
        .cache_wdata          (cache_wdata),
        .cache_load_mask      (cache_load_mask),
        .cache_rdata          (cache_rdata),
        .cache_ready          (cache_ready),
        .cache_flush          (dcache_flush),
        .cache_pipeline_stall (cache_pipeline_stall),
        .mmio_addr            (mmio_addr),
        .mmio_wr_addr         (mmio_wr_addr),
        .mmio_wea             (mmio_wea),
        .mmio_wdata           (mmio_wdata),
        .mmio_rdata           (mmio_rdata),
        .timer_irq_pending    (timer_irq_pending)
    );

    // ================================================================
    // Private DCache and DRAM.
    // ================================================================
    logic        dram_rd_en;
    logic [15:0] dram_rd_addr;
    logic [31:0] dram_rdata;
    logic [15:0] dram_wr_addr;
    logic [ 3:0] dram_wea;
    logic [31:0] dram_wdata;

    dcache #(
        .BACKEND_CANCEL      (1'b1),
        .DIRECT_BRAM         (1'b1),
        .CRITICAL_WORD_FIRST (1'b1)
    ) u_dcache (
        .clk                  (cpu_clk),
        .rst_n                (cpu_rst_n),
        .cpu_req              (cache_req),
        .cpu_wr               (cache_wr),
        .cpu_addr             (cache_addr),
        .cpu_wea              (cache_wea),
        .cpu_wdata            (cache_wdata),
        .cpu_load_mask        (cache_load_mask),
        .cpu_rdata            (cache_rdata),
        .cpu_ready            (cache_ready),
        .pipeline_stall       (cache_pipeline_stall),
        .flush                (dcache_flush),
        .mem_req_valid        (),
        .mem_req_ready        (1'b0),
        .mem_req_write        (),
        .mem_req_addr         (),
        .mem_req_len          (),
        .mem_req_wdata        (),
        .mem_req_wstrb        (),
        .mem_rd_valid         (1'b0),
        .mem_rd_ready         (),
        .mem_rd_data          (32'd0),
        .mem_rd_last          (1'b0),
        .mem_rd_resp          (2'b00),
        .mem_rd_cancel        (),
        .mem_wr_valid         (1'b0),
        .mem_wr_ready         (),
        .mem_wr_resp          (2'b00),
        .bram_rd_en           (dram_rd_en),
        .bram_rd_addr         (dram_rd_addr),
        .bram_rd_data         (dram_rdata),
        .bram_wr_addr         (dram_wr_addr),
        .bram_wea             (dram_wea),
        .bram_wdata           (dram_wdata)
    );

    DRAM4MyOwn u_dram (
        .clka  (cpu_clk),
        .wea   (dram_wea),
        .addra (dram_wr_addr),
        .dina  (dram_wdata),
        .clkb  (cpu_clk),
        .enb   (dram_rd_en),
        .addrb (dram_rd_addr),
        .doutb (dram_rdata)
    );

    contest_mmio_adapter u_mmio_adapter (
        .clk               (cpu_clk),
        .rst               (cpu_rst_sync),
        .read_addr_ex      (mmio_addr),
        .write_addr_mem    (mmio_wr_addr),
        .write_wea_mem     (mmio_wea),
        .write_data_mem    (mmio_wdata),
        .read_data_mem     (mmio_rdata),
        .timer_irq_pending (timer_irq_pending),
        .perip_addr        (perip_addr),
        .perip_wen         (perip_wen),
        .perip_mask        (perip_mask),
        .perip_wdata       (perip_wdata),
        .perip_rdata       (perip_rdata)
    );

endmodule

// ============================================================
// Module: contest_mmio_adapter
// Description:
//   Align the cpu_top EX/MEM split MMIO interface with the template's
//   same-cycle-read/next-edge-write perip interface.  The existing internal
//   machine timer remains private; all platform MMIO is forwarded outside.
// ============================================================
module contest_mmio_adapter (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] read_addr_ex,
    input  logic [31:0] write_addr_mem,
    input  logic [ 3:0] write_wea_mem,
    input  logic [31:0] write_data_mem,
    output logic [31:0] read_data_mem,
    output logic        timer_irq_pending,
    output logic [31:0] perip_addr,
    output logic        perip_wen,
    output logic [ 1:0] perip_mask,
    output logic [31:0] perip_wdata,
    input  logic [31:0] perip_rdata
);

    localparam logic [31:0] MTIME_LO_ADDR    = 32'h8020_0070;
    localparam logic [31:0] MTIME_HI_ADDR    = 32'h8020_0074;
    localparam logic [31:0] MTIMECMP_LO_ADDR = 32'h8020_0078;
    localparam logic [31:0] MTIMECMP_HI_ADDR = 32'h8020_007C;

    logic [31:0] read_addr_mem;
    logic [63:0] mtime;
    logic [63:0] mtimecmp;

    always_ff @(posedge clk) begin
        if (rst)
            read_addr_mem <= 32'd0;
        else
            read_addr_mem <= read_addr_ex;
    end

    wire read_mtime_lo = read_addr_mem == MTIME_LO_ADDR;
    wire read_mtime_hi = read_addr_mem == MTIME_HI_ADDR;
    wire read_mtimecmp_lo = read_addr_mem == MTIMECMP_LO_ADDR;
    wire read_mtimecmp_hi = read_addr_mem == MTIMECMP_HI_ADDR;
    wire read_internal = read_mtime_lo | read_mtime_hi
                       | read_mtimecmp_lo | read_mtimecmp_hi;

    wire write_valid = |write_wea_mem;
    wire write_mtime_lo = write_valid & (write_addr_mem == MTIME_LO_ADDR);
    wire write_mtime_hi = write_valid & (write_addr_mem == MTIME_HI_ADDR);
    wire write_mtimecmp_lo = write_valid & (write_addr_mem == MTIMECMP_LO_ADDR);
    wire write_mtimecmp_hi = write_valid & (write_addr_mem == MTIMECMP_HI_ADDR);
    wire write_internal = write_mtime_lo | write_mtime_hi
                        | write_mtimecmp_lo | write_mtimecmp_hi;

    wire read_platform_space = read_addr_mem[31:8] == 24'h8020_00;
    wire write_platform_space = write_addr_mem[31:8] == 24'h8020_00;

    assign perip_wen   = write_valid & write_platform_space & ~write_internal;
    assign perip_addr  = perip_wen ? write_addr_mem
                                   : ((read_platform_space & ~read_internal)
                                      ? read_addr_mem : 32'd0);
    assign perip_wdata = write_data_mem;

    always_comb begin
        if (!perip_wen)
            perip_mask = 2'b10;
        else if (write_wea_mem == 4'b1111)
            perip_mask = 2'b10;
        else if ((write_wea_mem == 4'b0011) ||
                 (write_wea_mem == 4'b1100))
            perip_mask = 2'b01;
        else
            perip_mask = 2'b00;
    end

    always_comb begin
        if (read_mtime_lo)
            read_data_mem = mtime[31:0];
        else if (read_mtime_hi)
            read_data_mem = mtime[63:32];
        else if (read_mtimecmp_lo)
            read_data_mem = mtimecmp[31:0];
        else if (read_mtimecmp_hi)
            read_data_mem = mtimecmp[63:32];
        else
            read_data_mem = perip_rdata;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            mtime <= mtime + 64'd1;

            if (write_mtime_lo) begin
                if (write_wea_mem[0]) mtime[ 7: 0] <= write_data_mem[ 7: 0];
                if (write_wea_mem[1]) mtime[15: 8] <= write_data_mem[15: 8];
                if (write_wea_mem[2]) mtime[23:16] <= write_data_mem[23:16];
                if (write_wea_mem[3]) mtime[31:24] <= write_data_mem[31:24];
            end
            if (write_mtime_hi) begin
                if (write_wea_mem[0]) mtime[39:32] <= write_data_mem[ 7: 0];
                if (write_wea_mem[1]) mtime[47:40] <= write_data_mem[15: 8];
                if (write_wea_mem[2]) mtime[55:48] <= write_data_mem[23:16];
                if (write_wea_mem[3]) mtime[63:56] <= write_data_mem[31:24];
            end
            if (write_mtimecmp_lo) begin
                if (write_wea_mem[0]) mtimecmp[ 7: 0] <= write_data_mem[ 7: 0];
                if (write_wea_mem[1]) mtimecmp[15: 8] <= write_data_mem[15: 8];
                if (write_wea_mem[2]) mtimecmp[23:16] <= write_data_mem[23:16];
                if (write_wea_mem[3]) mtimecmp[31:24] <= write_data_mem[31:24];
            end
            if (write_mtimecmp_hi) begin
                if (write_wea_mem[0]) mtimecmp[39:32] <= write_data_mem[ 7: 0];
                if (write_wea_mem[1]) mtimecmp[47:40] <= write_data_mem[15: 8];
                if (write_wea_mem[2]) mtimecmp[55:48] <= write_data_mem[23:16];
                if (write_wea_mem[3]) mtimecmp[63:56] <= write_data_mem[31:24];
            end
        end
    end

    assign timer_irq_pending = mtime >= mtimecmp;

endmodule
