`timescale 1ns / 1ps
// ============================================================
// Chiplab contract:
//   file   : mycpu_top.v
//   module : core_top
// ISA/platform contract:
//   LA32R sources are selected only by platform/nscscc/filelist.f.
//   This wrapper never compiles into the JYD RISC-V BRAM build.
// ============================================================

module core_top #(
    parameter TLBNUM = 32
) (
    input  wire         aclk,
    input  wire         aresetn,
    input  wire  [ 7:0] intrpt,

    output wire  [ 3:0] arid,
    output wire  [31:0] araddr,
    output wire  [ 7:0] arlen,
    output wire  [ 2:0] arsize,
    output wire  [ 1:0] arburst,
    output wire  [ 1:0] arlock,
    output wire  [ 3:0] arcache,
    output wire  [ 2:0] arprot,
    output wire         arvalid,
    input  wire         arready,
    input  wire  [ 3:0] rid,
    input  wire  [31:0] rdata,
    input  wire  [ 1:0] rresp,
    input  wire         rlast,
    input  wire         rvalid,
    output wire         rready,

    output wire  [ 3:0] awid,
    output wire  [31:0] awaddr,
    output wire  [ 7:0] awlen,
    output wire  [ 2:0] awsize,
    output wire  [ 1:0] awburst,
    output wire  [ 1:0] awlock,
    output wire  [ 3:0] awcache,
    output wire  [ 2:0] awprot,
    output wire         awvalid,
    input  wire         awready,
    output wire  [ 3:0] wid,
    output wire  [31:0] wdata,
    output wire  [ 3:0] wstrb,
    output wire         wlast,
    output wire         wvalid,
    input  wire         wready,
    input  wire  [ 3:0] bid,
    input  wire  [ 1:0] bresp,
    input  wire         bvalid,
    output wire         bready,

    input  wire         break_point,
    input  wire         infor_flag,
    input  wire  [ 4:0] reg_num,
    output wire         ws_valid,
    output wire  [31:0] rf_rdata,

    output wire  [31:0] debug0_wb_pc,
    output wire  [ 3:0] debug0_wb_rf_wen,
    output wire  [ 4:0] debug0_wb_rf_wnum,
    output wire  [31:0] debug0_wb_rf_wdata,
    output wire  [31:0] debug0_wb_inst
`ifdef CPU_2CMT
    ,
    output wire  [31:0] debug1_wb_pc,
    output wire  [ 3:0] debug1_wb_rf_wen,
    output wire  [ 4:0] debug1_wb_rf_wnum,
    output wire  [31:0] debug1_wb_rf_wdata
`endif
);

    reg  [1:0] reset_pipe;
    wire       core_rst_n;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            reset_pipe <= 2'b00;
        else
            reset_pipe <= {reset_pipe[0], 1'b1};
    end
    assign core_rst_n = reset_pipe[1];

    wire        irom_req_valid;
    wire        irom_req_ready;
    wire [31:0] irom_req_addr;
    wire        irom_resp_valid;
    wire [63:0] irom_resp_data;

    wire        cache_req;
    wire        cache_wr;
    wire [31:0] cache_addr;
    wire [ 3:0] cache_wea;
    wire [31:0] cache_wdata;
    wire [ 3:0] cache_load_mask;
    wire        cache_uncached;
    wire [31:0] cache_rdata;
    wire        cache_ready;
    wire        cache_flush;
    wire        cache_pipeline_stall;

    wire        dmem_req_valid;
    wire        dmem_req_ready;
    wire        dmem_req_write;
    wire [31:0] dmem_req_addr;
    wire [ 7:0] dmem_req_len;
    wire [31:0] dmem_req_wdata;
    wire [ 3:0] dmem_req_wstrb;
    wire        dmem_rd_valid;
    wire        dmem_rd_ready;
    wire [31:0] dmem_rd_data;
    wire        dmem_rd_last;
    wire [ 1:0] dmem_rd_resp;
    wire        dmem_rd_cancel;
    wire        dmem_wr_valid;
    wire        dmem_wr_ready;
    wire [ 1:0] dmem_wr_resp;

    wire        debug0_wb_valid_i;
    wire        debug1_wb_valid_i;
    wire [31:0] debug1_wb_pc_i;
    wire [ 3:0] debug1_wb_rf_wen_i;
    wire [ 4:0] debug1_wb_rf_wnum_i;
    wire [31:0] debug1_wb_rf_wdata_i;
    wire [31:0] debug0_wb_inst_i;
    wire        debug0_wb_exception_i;
    wire        debug0_wb_mem_read_i;
    wire        debug0_wb_mem_write_i;
    wire [ 1:0] debug0_wb_mem_size_i;
    wire        debug0_wb_mem_unsigned_i;
    wire [31:0] debug0_wb_mem_addr_i;
    wire [31:0] debug0_wb_store_data_i;
    wire        debug0_wb_csr_rstat_i;
    wire [31:0] debug0_wb_csr_data_i;
    wire [31:0] debug1_wb_inst_i;
    wire        debug1_wb_mem_read_i;
    wire        debug1_wb_mem_write_i;
    wire [ 1:0] debug1_wb_mem_size_i;
    wire        debug1_wb_mem_unsigned_i;
    wire [31:0] debug1_wb_mem_addr_i;
    wire [31:0] debug1_wb_store_data_i;
    wire [1023:0] debug_gpr_state_i;
    wire [ 863:0] debug_priv_state_i;
    wire        debug_excp_valid_i;
    wire        debug_ertn_i;
    wire [31:0] debug_intr_no_i;
    wire [ 5:0] debug_cause_i;
    wire [31:0] debug_exception_pc_i;
    wire [31:0] debug_exception_inst_i;

    cpu_top #(
        .IROM_VARIABLE_LATENCY(1'b1),
        .RESET_PC            (32'h1C00_0000),
        .CACHE_ADDR_BASE     (32'h1C08_0000),
        .CACHE_ADDR_MASK     (32'hFFF8_0000),
        .AXI_UNCACHED_DATA   (1'b1)
    ) u_cpu (
        .clk                 (aclk),
        .rst_n               (core_rst_n),
        .irom_addr           (),
        .irom_req_valid      (irom_req_valid),
        .irom_req_addr       (irom_req_addr),
        .irom_req_ready      (irom_req_ready),
        .irom_resp_valid     (irom_resp_valid),
        .irom_data           (irom_resp_data),
        .cache_req           (cache_req),
        .cache_wr            (cache_wr),
        .cache_addr          (cache_addr),
        .cache_wea           (cache_wea),
        .cache_wdata         (cache_wdata),
        .cache_load_mask     (cache_load_mask),
        .cache_uncached      (cache_uncached),
        .cache_rdata         (cache_rdata),
        .cache_ready         (cache_ready),
        .cache_flush         (cache_flush),
        .cache_pipeline_stall(cache_pipeline_stall),
        .mmio_addr           (),
        .mmio_wr_addr        (),
        .mmio_wea            (),
        .mmio_wdata          (),
        .mmio_rdata          (32'd0),
        .timer_irq_pending   (|intrpt),
        .debug0_wb_valid     (debug0_wb_valid_i),
        .debug0_wb_pc        (debug0_wb_pc),
        .debug0_wb_rf_wen    (debug0_wb_rf_wen),
        .debug0_wb_rf_wnum   (debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata  (debug0_wb_rf_wdata),
        .debug0_wb_inst      (debug0_wb_inst_i),
        .debug0_wb_exception (debug0_wb_exception_i),
        .debug0_wb_mem_read  (debug0_wb_mem_read_i),
        .debug0_wb_mem_write (debug0_wb_mem_write_i),
        .debug0_wb_mem_size  (debug0_wb_mem_size_i),
        .debug0_wb_mem_unsigned(debug0_wb_mem_unsigned_i),
        .debug0_wb_mem_addr  (debug0_wb_mem_addr_i),
        .debug0_wb_store_data(debug0_wb_store_data_i),
        .debug0_wb_csr_rstat (debug0_wb_csr_rstat_i),
        .debug0_wb_csr_data  (debug0_wb_csr_data_i),
        .debug1_wb_valid     (debug1_wb_valid_i),
        .debug1_wb_pc        (debug1_wb_pc_i),
        .debug1_wb_rf_wen    (debug1_wb_rf_wen_i),
        .debug1_wb_rf_wnum   (debug1_wb_rf_wnum_i),
        .debug1_wb_rf_wdata  (debug1_wb_rf_wdata_i),
        .debug1_wb_inst      (debug1_wb_inst_i),
        .debug1_wb_mem_read  (debug1_wb_mem_read_i),
        .debug1_wb_mem_write (debug1_wb_mem_write_i),
        .debug1_wb_mem_size  (debug1_wb_mem_size_i),
        .debug1_wb_mem_unsigned(debug1_wb_mem_unsigned_i),
        .debug1_wb_mem_addr  (debug1_wb_mem_addr_i),
        .debug1_wb_store_data(debug1_wb_store_data_i),
        .debug_gpr_state     (debug_gpr_state_i),
        .debug_priv_state    (debug_priv_state_i),
        .debug_excp_valid    (debug_excp_valid_i),
        .debug_ertn          (debug_ertn_i),
        .debug_intr_no       (debug_intr_no_i),
        .debug_cause         (debug_cause_i),
        .debug_exception_pc  (debug_exception_pc_i),
        .debug_exception_inst(debug_exception_inst_i)
    );

    dcache #(
        .BACKEND_CANCEL     (1'b0),
        .DIRECT_BRAM        (1'b0),
        .CRITICAL_WORD_FIRST(1'b0),
        .PHYS_ADDR_WIDTH    (32),
        .UNCACHED_ENABLE    (1'b1)
    ) u_dcache (
        .clk                 (aclk),
        .rst_n               (core_rst_n),
        .cpu_req             (cache_req),
        .cpu_wr              (cache_wr),
        .cpu_addr            (cache_addr),
        .cpu_wea             (cache_wea),
        .cpu_wdata           (cache_wdata),
        .cpu_load_mask       (cache_load_mask),
        .cpu_uncached        (cache_uncached),
        .cpu_rdata           (cache_rdata),
        .cpu_ready           (cache_ready),
        .pipeline_stall      (cache_pipeline_stall),
        .flush               (cache_flush),
        .mem_req_valid       (dmem_req_valid),
        .mem_req_ready       (dmem_req_ready),
        .mem_req_write       (dmem_req_write),
        .mem_req_addr        (dmem_req_addr),
        .mem_req_len         (dmem_req_len),
        .mem_req_wdata       (dmem_req_wdata),
        .mem_req_wstrb       (dmem_req_wstrb),
        .mem_rd_valid        (dmem_rd_valid),
        .mem_rd_ready        (dmem_rd_ready),
        .mem_rd_data         (dmem_rd_data),
        .mem_rd_last         (dmem_rd_last),
        .mem_rd_resp         (dmem_rd_resp),
        .mem_rd_cancel       (dmem_rd_cancel),
        .mem_wr_valid        (dmem_wr_valid),
        .mem_wr_ready        (dmem_wr_ready),
        .mem_wr_resp         (dmem_wr_resp),
        .bram_rd_en          (),
        .bram_rd_addr        (),
        .bram_rd_data        (32'd0),
        .bram_wr_addr        (),
        .bram_wea            (),
        .bram_wdata          ()
    );

    nscscc_axi_bridge u_nscscc_axi_bridge (
        .clk            (aclk),
        .rst_n          (core_rst_n),
        .irom_req_valid (irom_req_valid),
        .irom_req_ready (irom_req_ready),
        .irom_req_addr  (irom_req_addr),
        .irom_resp_valid(irom_resp_valid),
        .irom_resp_data (irom_resp_data),
        .dmem_req_valid (dmem_req_valid),
        .dmem_req_ready (dmem_req_ready),
        .dmem_req_write (dmem_req_write),
        .dmem_req_addr  (dmem_req_addr),
        .dmem_req_len   (dmem_req_len),
        .dmem_req_wdata (dmem_req_wdata),
        .dmem_req_wstrb (dmem_req_wstrb),
        .dmem_rd_valid  (dmem_rd_valid),
        .dmem_rd_ready  (dmem_rd_ready),
        .dmem_rd_data   (dmem_rd_data),
        .dmem_rd_last   (dmem_rd_last),
        .dmem_rd_resp   (dmem_rd_resp),
        .dmem_rd_cancel (dmem_rd_cancel),
        .dmem_wr_valid  (dmem_wr_valid),
        .dmem_wr_ready  (dmem_wr_ready),
        .dmem_wr_resp   (dmem_wr_resp),
        .arid           (arid),
        .araddr         (araddr),
        .arlen          (arlen),
        .arsize         (arsize),
        .arburst        (arburst),
        .arlock         (arlock),
        .arcache        (arcache),
        .arprot         (arprot),
        .arvalid        (arvalid),
        .arready        (arready),
        .rid            (rid),
        .rdata          (rdata),
        .rresp          (rresp),
        .rlast          (rlast),
        .rvalid         (rvalid),
        .rready         (rready),
        .awid           (awid),
        .awaddr         (awaddr),
        .awlen          (awlen),
        .awsize         (awsize),
        .awburst        (awburst),
        .awlock         (awlock),
        .awcache        (awcache),
        .awprot         (awprot),
        .awvalid        (awvalid),
        .awready        (awready),
        .wid            (wid),
        .wdata          (wdata),
        .wstrb          (wstrb),
        .wlast          (wlast),
        .wvalid         (wvalid),
        .wready         (wready),
        .bid            (bid),
        .bresp          (bresp),
        .bvalid         (bvalid),
        .bready         (bready)
    );

    assign ws_valid = debug0_wb_valid_i;
    assign rf_rdata = debug_gpr_state_i[{reg_num, 5'b0} +: 32];
    assign debug0_wb_inst = debug0_wb_inst_i;

`ifdef CPU_2CMT
    assign debug1_wb_pc = debug1_wb_pc_i;
    assign debug1_wb_rf_wen = debug1_wb_rf_wen_i;
    assign debug1_wb_rf_wnum = debug1_wb_rf_wnum_i;
    assign debug1_wb_rf_wdata = debug1_wb_rf_wdata_i;
`endif

`ifdef DIFFTEST_EN
    // Difftest is a simulation-only architectural observation boundary.  The
    // core exports ISA-neutral retire metadata; this LoongArch-only wrapper
    // performs the LA load/store mask and CSR-state mapping.
    wire [7:0] diff_ld_mask0 = !debug0_wb_mem_read_i ? 8'd0
        : (debug0_wb_mem_size_i == 2'd0)
            ? (debug0_wb_mem_unsigned_i ? 8'h02 : 8'h01)
        : (debug0_wb_mem_size_i == 2'd1)
            ? (debug0_wb_mem_unsigned_i ? 8'h08 : 8'h04)
        : 8'h10;
    wire [7:0] diff_ld_mask1 = !debug1_wb_mem_read_i ? 8'd0
        : (debug1_wb_mem_size_i == 2'd0)
            ? (debug1_wb_mem_unsigned_i ? 8'h02 : 8'h01)
        : (debug1_wb_mem_size_i == 2'd1)
            ? (debug1_wb_mem_unsigned_i ? 8'h08 : 8'h04)
        : 8'h10;
    wire [7:0] diff_st_mask0 = !debug0_wb_mem_write_i ? 8'd0
        : (debug0_wb_mem_size_i == 2'd0) ? 8'h01
        : (debug0_wb_mem_size_i == 2'd1) ? 8'h02 : 8'h04;
    wire [7:0] diff_st_mask1 = !debug1_wb_mem_write_i ? 8'd0
        : (debug1_wb_mem_size_i == 2'd0) ? 8'h01
        : (debug1_wb_mem_size_i == 2'd1) ? 8'h02 : 8'h04;
    wire [31:0] diff_st_data0 =
        (debug0_wb_mem_size_i == 2'd0)
            ? ({24'd0, debug0_wb_store_data_i[7:0]}
               << {debug0_wb_mem_addr_i[1:0], 3'b000})
        : (debug0_wb_mem_size_i == 2'd1)
            ? ({16'd0, debug0_wb_store_data_i[15:0]}
               << {debug0_wb_mem_addr_i[1], 4'b0000})
        : debug0_wb_store_data_i;
    wire [31:0] diff_st_data1 =
        (debug1_wb_mem_size_i == 2'd0)
            ? ({24'd0, debug1_wb_store_data_i[7:0]}
               << {debug1_wb_mem_addr_i[1:0], 3'b000})
        : (debug1_wb_mem_size_i == 2'd1)
            ? ({16'd0, debug1_wb_store_data_i[15:0]}
               << {debug1_wb_mem_addr_i[1], 4'b0000})
        : debug1_wb_store_data_i;

    function [63:0] diff_zext32;
        input [31:0] value;
        begin
            diff_zext32 = {32'd0, value};
        end
    endfunction

    reg         cmt0_valid;
    reg  [31:0] cmt0_pc;
    reg  [31:0] cmt0_inst;
    reg         cmt0_wen;
    reg  [ 7:0] cmt0_wdest;
    reg  [31:0] cmt0_wdata;
    reg         cmt0_csr_rstat;
    reg  [31:0] cmt0_csr_data;
    reg  [ 7:0] cmt0_ld_valid;
    reg  [ 7:0] cmt0_st_valid;
    reg  [31:0] cmt0_mem_addr;
    reg  [31:0] cmt0_st_data;

    reg         cmt1_valid;
    reg  [31:0] cmt1_pc;
    reg  [31:0] cmt1_inst;
    reg         cmt1_wen;
    reg  [ 7:0] cmt1_wdest;
    reg  [31:0] cmt1_wdata;
    reg  [ 7:0] cmt1_ld_valid;
    reg  [ 7:0] cmt1_st_valid;
    reg  [31:0] cmt1_mem_addr;
    reg  [31:0] cmt1_st_data;

    reg         cmt_excp_valid;
    reg         cmt_ertn;
    reg  [31:0] cmt_intr_no;
    reg  [ 5:0] cmt_cause;
    reg  [31:0] cmt_exception_pc;
    reg  [31:0] cmt_exception_inst;
    reg  [63:0] diff_cycle_count;
    reg  [63:0] diff_instr_count;

    wire cmt0_cnt_low = (cmt0_inst[31:15] == 17'd0)
                       && (cmt0_inst[14:10] == 5'd24)
                       && (cmt0_inst[9:5] == 5'd0);
    wire cmt0_cnt_id = (cmt0_inst[31:15] == 17'd0)
                      && (cmt0_inst[14:10] == 5'd24)
                      && (cmt0_inst[4:0] == 5'd0);
    wire cmt0_cnt_high = (cmt0_inst[31:15] == 17'd0)
                        && (cmt0_inst[14:10] == 5'd25)
                        && (cmt0_inst[9:5] == 5'd0);
    wire cmt0_is_cnt = cmt0_cnt_low | cmt0_cnt_id | cmt0_cnt_high;
    // Chiplab copies this sampled value into NEMU immediately before it
    // executes an RDCNT instruction.  The architectural result supplies the
    // half that was actually observed; the test horizon is below 2^32 clocks.
    wire [63:0] cmt0_timer_value = cmt0_cnt_high
                                 ? {cmt0_wdata, 32'd0}
                                 : {32'd0, cmt0_wdata};

    always @(posedge aclk) begin
        if (!core_rst_n) begin
            cmt0_valid <= 1'b0;
            cmt0_pc <= 32'd0;
            cmt0_inst <= 32'd0;
            cmt0_wen <= 1'b0;
            cmt0_wdest <= 8'd0;
            cmt0_wdata <= 32'd0;
            cmt0_csr_rstat <= 1'b0;
            cmt0_csr_data <= 32'd0;
            cmt0_ld_valid <= 8'd0;
            cmt0_st_valid <= 8'd0;
            cmt0_mem_addr <= 32'd0;
            cmt0_st_data <= 32'd0;
            cmt1_valid <= 1'b0;
            cmt1_pc <= 32'd0;
            cmt1_inst <= 32'd0;
            cmt1_wen <= 1'b0;
            cmt1_wdest <= 8'd0;
            cmt1_wdata <= 32'd0;
            cmt1_ld_valid <= 8'd0;
            cmt1_st_valid <= 8'd0;
            cmt1_mem_addr <= 32'd0;
            cmt1_st_data <= 32'd0;
            cmt_excp_valid <= 1'b0;
            cmt_ertn <= 1'b0;
            cmt_intr_no <= 32'd0;
            cmt_cause <= 6'd0;
            cmt_exception_pc <= 32'd0;
            cmt_exception_inst <= 32'd0;
            diff_cycle_count <= 64'd0;
            diff_instr_count <= 64'd0;
        end else begin
            cmt0_valid <= debug0_wb_valid_i;
            cmt0_pc <= debug0_wb_pc;
            cmt0_inst <= debug0_wb_inst_i;
            cmt0_wen <= |debug0_wb_rf_wen;
            cmt0_wdest <= {3'd0, debug0_wb_rf_wnum};
            cmt0_wdata <= debug0_wb_rf_wdata;
            cmt0_csr_rstat <= debug0_wb_csr_rstat_i;
            cmt0_csr_data <= debug0_wb_csr_data_i;
            cmt0_ld_valid <= diff_ld_mask0;
            cmt0_st_valid <= diff_st_mask0;
            cmt0_mem_addr <= debug0_wb_mem_addr_i;
            cmt0_st_data <= diff_st_data0;

            cmt1_valid <= debug1_wb_valid_i;
            cmt1_pc <= debug1_wb_pc_i;
            cmt1_inst <= debug1_wb_inst_i;
            cmt1_wen <= |debug1_wb_rf_wen_i;
            cmt1_wdest <= {3'd0, debug1_wb_rf_wnum_i};
            cmt1_wdata <= debug1_wb_rf_wdata_i;
            cmt1_ld_valid <= diff_ld_mask1;
            cmt1_st_valid <= diff_st_mask1;
            cmt1_mem_addr <= debug1_wb_mem_addr_i;
            cmt1_st_data <= diff_st_data1;

            cmt_excp_valid <= debug_excp_valid_i;
            cmt_ertn <= debug_ertn_i;
            cmt_intr_no <= debug_intr_no_i;
            cmt_cause <= debug_cause_i;
            cmt_exception_pc <= debug_exception_pc_i;
            cmt_exception_inst <= debug_exception_inst_i;
            diff_cycle_count <= diff_cycle_count + 64'd1;
            diff_instr_count <= diff_instr_count
                              + {63'd0, debug0_wb_valid_i}
                              + {63'd0, debug1_wb_valid_i};
        end
    end

    DifftestInstrCommit u_difftest_commit0 (
        .clock(aclk), .coreid(8'd0), .index(8'd0), .valid(cmt0_valid),
        .pc(diff_zext32(cmt0_pc)), .instr(cmt0_inst), .skip(1'b0),
        .is_TLBFILL(1'b0), .TLBFILL_index(5'd0), .is_CNTinst(cmt0_is_cnt),
        .timer_64_value(cmt0_timer_value), .wen(cmt0_wen), .wdest(cmt0_wdest),
        .wdata(diff_zext32(cmt0_wdata)), .csr_rstat(cmt0_csr_rstat),
        .csr_data(cmt0_csr_data)
    );

    DifftestInstrCommit u_difftest_commit1 (
        .clock(aclk), .coreid(8'd0), .index(8'd1), .valid(cmt1_valid),
        .pc(diff_zext32(cmt1_pc)), .instr(cmt1_inst), .skip(1'b0),
        .is_TLBFILL(1'b0), .TLBFILL_index(5'd0), .is_CNTinst(1'b0),
        .timer_64_value(64'd0), .wen(cmt1_wen), .wdest(cmt1_wdest),
        .wdata(diff_zext32(cmt1_wdata)), .csr_rstat(1'b0),
        .csr_data(32'd0)
    );

    DifftestExcpEvent u_difftest_excp (
        .clock(aclk), .coreid(8'd0), .excp_valid(cmt_excp_valid),
        .eret(cmt_ertn), .intrNo(cmt_intr_no), .cause({26'd0, cmt_cause}),
        .exceptionPC(diff_zext32(cmt_exception_pc)),
        .exceptionInst(cmt_exception_inst)
    );

    DifftestTrapEvent u_difftest_trap (
        .clock(aclk), .coreid(8'd0), .valid(1'b0), .code(3'd0),
        .pc(diff_zext32(cmt0_pc)), .cycleCnt(diff_cycle_count),
        .instrCnt(diff_instr_count)
    );

    DifftestStoreEvent u_difftest_store0 (
        .clock(aclk), .coreid(8'd0), .index(8'd0),
        .valid(cmt0_st_valid), .storePAddr(diff_zext32(cmt0_mem_addr)),
        .storeVAddr(diff_zext32(cmt0_mem_addr)),
        .storeData(diff_zext32(cmt0_st_data))
    );
    DifftestStoreEvent u_difftest_store1 (
        .clock(aclk), .coreid(8'd0), .index(8'd1),
        .valid(cmt1_st_valid), .storePAddr(diff_zext32(cmt1_mem_addr)),
        .storeVAddr(diff_zext32(cmt1_mem_addr)),
        .storeData(diff_zext32(cmt1_st_data))
    );
    DifftestLoadEvent u_difftest_load0 (
        .clock(aclk), .coreid(8'd0), .index(8'd0),
        .valid(cmt0_ld_valid), .paddr(diff_zext32(cmt0_mem_addr)),
        .vaddr(diff_zext32(cmt0_mem_addr))
    );
    DifftestLoadEvent u_difftest_load1 (
        .clock(aclk), .coreid(8'd0), .index(8'd1),
        .valid(cmt1_ld_valid), .paddr(diff_zext32(cmt1_mem_addr)),
        .vaddr(diff_zext32(cmt1_mem_addr))
    );

    DifftestCSRRegState u_difftest_csr (
        .clock(aclk), .coreid(8'd0),
        .crmd(diff_zext32(debug_priv_state_i[ 0*32 +: 32])),
        .prmd(diff_zext32(debug_priv_state_i[ 1*32 +: 32])),
        .euen(diff_zext32(debug_priv_state_i[ 2*32 +: 32])),
        .ecfg(diff_zext32(debug_priv_state_i[ 3*32 +: 32])),
        .estat(diff_zext32(debug_priv_state_i[ 4*32 +: 32])),
        .era(diff_zext32(debug_priv_state_i[ 5*32 +: 32])),
        .badv(diff_zext32(debug_priv_state_i[ 6*32 +: 32])),
        .eentry(diff_zext32(debug_priv_state_i[ 7*32 +: 32])),
        .tlbidx(diff_zext32(debug_priv_state_i[ 8*32 +: 32])),
        .tlbehi(diff_zext32(debug_priv_state_i[ 9*32 +: 32])),
        .tlbelo0(diff_zext32(debug_priv_state_i[10*32 +: 32])),
        .tlbelo1(diff_zext32(debug_priv_state_i[11*32 +: 32])),
        .asid(diff_zext32(debug_priv_state_i[12*32 +: 32])),
        .pgdl(diff_zext32(debug_priv_state_i[13*32 +: 32])),
        .pgdh(diff_zext32(debug_priv_state_i[14*32 +: 32])),
        .save0(diff_zext32(debug_priv_state_i[15*32 +: 32])),
        .save1(diff_zext32(debug_priv_state_i[16*32 +: 32])),
        .save2(diff_zext32(debug_priv_state_i[17*32 +: 32])),
        .save3(diff_zext32(debug_priv_state_i[18*32 +: 32])),
        .tid(diff_zext32(debug_priv_state_i[19*32 +: 32])),
        .tcfg(diff_zext32(debug_priv_state_i[20*32 +: 32])),
        .tval(diff_zext32(debug_priv_state_i[21*32 +: 32])),
        .ticlr(diff_zext32(debug_priv_state_i[22*32 +: 32])),
        .llbctl(diff_zext32(debug_priv_state_i[23*32 +: 32])),
        .tlbrentry(diff_zext32(debug_priv_state_i[24*32 +: 32])),
        .dmw0(diff_zext32(debug_priv_state_i[25*32 +: 32])),
        .dmw1(diff_zext32(debug_priv_state_i[26*32 +: 32]))
    );

    DifftestGRegState u_difftest_gpr (
        .clock(aclk), .coreid(8'd0),
        .gpr_0(diff_zext32(debug_gpr_state_i[ 0*32 +: 32])),
        .gpr_1(diff_zext32(debug_gpr_state_i[ 1*32 +: 32])),
        .gpr_2(diff_zext32(debug_gpr_state_i[ 2*32 +: 32])),
        .gpr_3(diff_zext32(debug_gpr_state_i[ 3*32 +: 32])),
        .gpr_4(diff_zext32(debug_gpr_state_i[ 4*32 +: 32])),
        .gpr_5(diff_zext32(debug_gpr_state_i[ 5*32 +: 32])),
        .gpr_6(diff_zext32(debug_gpr_state_i[ 6*32 +: 32])),
        .gpr_7(diff_zext32(debug_gpr_state_i[ 7*32 +: 32])),
        .gpr_8(diff_zext32(debug_gpr_state_i[ 8*32 +: 32])),
        .gpr_9(diff_zext32(debug_gpr_state_i[ 9*32 +: 32])),
        .gpr_10(diff_zext32(debug_gpr_state_i[10*32 +: 32])),
        .gpr_11(diff_zext32(debug_gpr_state_i[11*32 +: 32])),
        .gpr_12(diff_zext32(debug_gpr_state_i[12*32 +: 32])),
        .gpr_13(diff_zext32(debug_gpr_state_i[13*32 +: 32])),
        .gpr_14(diff_zext32(debug_gpr_state_i[14*32 +: 32])),
        .gpr_15(diff_zext32(debug_gpr_state_i[15*32 +: 32])),
        .gpr_16(diff_zext32(debug_gpr_state_i[16*32 +: 32])),
        .gpr_17(diff_zext32(debug_gpr_state_i[17*32 +: 32])),
        .gpr_18(diff_zext32(debug_gpr_state_i[18*32 +: 32])),
        .gpr_19(diff_zext32(debug_gpr_state_i[19*32 +: 32])),
        .gpr_20(diff_zext32(debug_gpr_state_i[20*32 +: 32])),
        .gpr_21(diff_zext32(debug_gpr_state_i[21*32 +: 32])),
        .gpr_22(diff_zext32(debug_gpr_state_i[22*32 +: 32])),
        .gpr_23(diff_zext32(debug_gpr_state_i[23*32 +: 32])),
        .gpr_24(diff_zext32(debug_gpr_state_i[24*32 +: 32])),
        .gpr_25(diff_zext32(debug_gpr_state_i[25*32 +: 32])),
        .gpr_26(diff_zext32(debug_gpr_state_i[26*32 +: 32])),
        .gpr_27(diff_zext32(debug_gpr_state_i[27*32 +: 32])),
        .gpr_28(diff_zext32(debug_gpr_state_i[28*32 +: 32])),
        .gpr_29(diff_zext32(debug_gpr_state_i[29*32 +: 32])),
        .gpr_30(diff_zext32(debug_gpr_state_i[30*32 +: 32])),
        .gpr_31(diff_zext32(debug_gpr_state_i[31*32 +: 32]))
    );
`endif

    // Keep optional chiplab debug inputs and the compatibility parameter in
    // the exact public contract even though the current core has no scan-read
    // register-file port.
    wire unused_debug_inputs = break_point ^ infor_flag ^ (^reg_num)
                             ^ (TLBNUM == 0) ^ debug1_wb_valid_i
                             ^ debug0_wb_exception_i;

endmodule
