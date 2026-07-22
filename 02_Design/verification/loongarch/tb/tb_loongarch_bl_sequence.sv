`timescale 1ns/1ps

module tb_loongarch_bl_sequence;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [31:0] NOP = 32'h0340_0000;

    logic clk;
    logic rst_n;
    logic [11:0] irom_addr;
    logic [63:0] irom_data;
    logic [31:0] irom [0:255];

    logic debug0_valid;
    logic [31:0] debug0_pc;
    logic [3:0] debug0_wen;
    logic [4:0] debug0_wnum;
    logic [31:0] debug0_wdata;
    logic debug1_valid;
    logic [31:0] debug1_pc;
    logic [3:0] debug1_wen;
    logic [4:0] debug1_wnum;
    logic [31:0] debug1_wdata;

    cpu_top #(.RESET_PC(RESET_PC)) u_cpu (
        .clk(clk),
        .rst_n(rst_n),
        .irom_addr(irom_addr),
        .irom_req_valid(),
        .irom_req_addr(),
        .irom_req_ready(1'b0),
        .irom_resp_valid(1'b0),
        .irom_data(irom_data),
        .cache_req(),
        .cache_wr(),
        .cache_addr(),
        .cache_wea(),
        .cache_wdata(),
        .cache_load_mask(),
        .cache_uncached(),
        .cache_rdata(32'd0),
        .cache_ready(1'b1),
        .cache_flush(),
        .cache_pipeline_stall(),
        .mmio_addr(),
        .mmio_wr_addr(),
        .mmio_wea(),
        .mmio_wdata(),
        .mmio_rdata(32'd0),
        .timer_irq_pending(1'b0),
        .debug0_wb_valid(debug0_valid),
        .debug0_wb_pc(debug0_pc),
        .debug0_wb_rf_wen(debug0_wen),
        .debug0_wb_rf_wnum(debug0_wnum),
        .debug0_wb_rf_wdata(debug0_wdata),
        .debug1_wb_valid(debug1_valid),
        .debug1_wb_pc(debug1_pc),
        .debug1_wb_rf_wen(debug1_wen),
        .debug1_wb_rf_wnum(debug1_wnum),
        .debug1_wb_rf_wdata(debug1_wdata),
        .debug0_wb_inst(),
        .debug0_wb_exception(),
        .debug0_wb_mem_read(),
        .debug0_wb_mem_write(),
        .debug0_wb_mem_size(),
        .debug0_wb_mem_unsigned(),
        .debug0_wb_mem_addr(),
        .debug0_wb_store_data(),
        .debug0_wb_csr_rstat(),
        .debug0_wb_csr_data(),
        .debug1_wb_inst(),
        .debug1_wb_mem_read(),
        .debug1_wb_mem_write(),
        .debug1_wb_mem_size(),
        .debug1_wb_mem_unsigned(),
        .debug1_wb_mem_addr(),
        .debug1_wb_store_data(),
        .debug_gpr_state(),
        .debug_priv_state(),
        .debug_excp_valid(),
        .debug_ertn(),
        .debug_intr_no(),
        .debug_cause(),
        .debug_exception_pc(),
        .debug_exception_inst()
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk) begin
        if (!rst_n)
            irom_data <= {NOP, NOP};
        else
            irom_data <= {irom[{irom_addr, 1'b1}],
                          irom[{irom_addr, 1'b0}]};
    end

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "[FAIL] %s", message);
    endtask

    initial begin
        bit completed;

        rst_n = 1'b0;
        irom_data = {NOP, NOP};
        for (int i = 0; i < 256; i++)
            irom[i] = NOP;

        // First TEST_BL expansion from the Chiplab functional suite, rebased
        // without changing any intra-sequence alignment or branch distance.
        irom['h00 >> 2] = 32'h0010_041e; // add.w r30,r0,r1
        irom['h04 >> 2] = 32'h1518_7c50;
        irom['h08 >> 2] = 32'h02bb_ea10;
        irom['h0c >> 2] = 32'h15d6_57b1;
        irom['h10 >> 2] = 32'h0295_f231;
        irom['h14 >> 2] = 32'h1400_000a;
        irom['h18 >> 2] = 32'h1400_000b;
        irom['h1c >> 2] = 32'h5400_1800; // slot1 BL +24
        irom['h20 >> 2] = 32'h0010_0025; // r5 = link of backward BL
        irom['h24 >> 2] = 32'h1518_7c4a;
        irom['h28 >> 2] = 32'h02bb_e94a;
        irom['h2c >> 2] = 32'h5400_1400; // slot1 BL +20
        irom['h30 >> 2] = 32'h5000_1c00;
        irom['h34 >> 2] = 32'h0010_0024; // r4 = first link
        irom['h38 >> 2] = 32'h57ff_ebff; // BL -24
        irom['h3c >> 2] = 32'h5000_1000;
        irom['h40 >> 2] = 32'h0010_0026; // r6 = second forward link
        irom['h44 >> 2] = 32'h15d6_57ab;
        irom['h48 >> 2] = 32'h0295_f16b;
        irom['h4c >> 2] = 32'h0010_7801;
        irom['h50 >> 2] = 32'h0280_30c6; // addi.w r6,r6,12
        irom['h54 >> 2] = 32'h0280_041f; // completion marker r31=1
        irom['h58 >> 2] = 32'h5000_0000;

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        completed = 1'b0;
        for (int cycle = 0; cycle < 400; cycle++) begin
            @(posedge clk);
            if ((debug0_valid && debug0_wen != 4'd0
                 && debug0_wnum == 5'd31 && debug0_wdata == 32'd1)
                || (debug1_valid && debug1_wen != 4'd0
                    && debug1_wnum == 5'd31 && debug1_wdata == 32'd1)) begin
                completed = 1'b1;
                break;
            end
        end

        check(completed, "BL sequence timed out");
        repeat (3) @(posedge clk);
        check(u_cpu.u_regfile.regs[4] == RESET_PC + 32'h20,
              "first forward BL link");
        check(u_cpu.u_regfile.regs[5] == RESET_PC + 32'h3c,
              "backward BL link");
        check(u_cpu.u_regfile.regs[6] == u_cpu.u_regfile.regs[5],
              "forward/backward BL link-distance relation");
        $display("[PASS] Chiplab BL sequence regression");
        $finish;
    end
endmodule
