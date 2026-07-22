`timescale 1ns/1ps

module tb_loongarch_bl_variable_irom;
    import cpu_defs::*;

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [31:0] NOP = 32'h0340_0000;

    typedef enum logic [1:0] {I_IDLE, I_WAIT, I_RESP} irom_state_t;

    logic clk;
    logic rst_n;
    logic [11:0] irom_addr_unused;
    logic irom_req_valid;
    logic irom_req_ready;
    logic [31:0] irom_req_addr;
    logic irom_resp_valid;
    logic [63:0] irom_data;
    logic [31:0] irom [0:255];
    irom_state_t irom_state;
    logic [31:0] pending_addr;
    logic [7:0] delay_count;
    logic [15:0] lfsr;

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
    integer request_count;
    integer response_count;

    cpu_top #(
        .IROM_VARIABLE_LATENCY(1'b1),
        .RESET_PC(RESET_PC)
    ) u_cpu (
        .clk(clk), .rst_n(rst_n),
        .irom_addr(irom_addr_unused),
        .irom_req_valid(irom_req_valid),
        .irom_req_addr(irom_req_addr),
        .irom_req_ready(irom_req_ready),
        .irom_resp_valid(irom_resp_valid),
        .irom_data(irom_data),
        .cache_req(), .cache_wr(), .cache_addr(), .cache_wea(),
        .cache_wdata(), .cache_load_mask(), .cache_uncached(),
        .cache_rdata(32'd0), .cache_ready(1'b1), .cache_flush(),
        .cache_pipeline_stall(), .mmio_addr(), .mmio_wr_addr(),
        .mmio_wea(), .mmio_wdata(), .mmio_rdata(32'd0),
        .timer_irq_pending(1'b0),
        .debug0_wb_valid(debug0_valid), .debug0_wb_pc(debug0_pc),
        .debug0_wb_rf_wen(debug0_wen), .debug0_wb_rf_wnum(debug0_wnum),
        .debug0_wb_rf_wdata(debug0_wdata), .debug0_wb_inst(),
        .debug0_wb_exception(), .debug0_wb_mem_read(),
        .debug0_wb_mem_write(), .debug0_wb_mem_size(),
        .debug0_wb_mem_unsigned(), .debug0_wb_mem_addr(),
        .debug0_wb_store_data(), .debug0_wb_csr_rstat(),
        .debug0_wb_csr_data(),
        .debug1_wb_valid(debug1_valid), .debug1_wb_pc(debug1_pc),
        .debug1_wb_rf_wen(debug1_wen), .debug1_wb_rf_wnum(debug1_wnum),
        .debug1_wb_rf_wdata(debug1_wdata), .debug1_wb_inst(),
        .debug1_wb_mem_read(), .debug1_wb_mem_write(),
        .debug1_wb_mem_size(), .debug1_wb_mem_unsigned(),
        .debug1_wb_mem_addr(), .debug1_wb_store_data(),
        .debug_gpr_state(), .debug_priv_state(),
        .debug_excp_valid(), .debug_ertn(), .debug_intr_no(),
        .debug_cause(), .debug_exception_pc(), .debug_exception_inst()
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    assign irom_req_ready = (irom_state == I_IDLE) & lfsr[0];

    // Reproducible randomized request back-pressure and response latency.
    // The response remains valid for a full cycle, matching the bridge's
    // response-holding contract while preserving a single outstanding read.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            irom_state <= I_IDLE;
            pending_addr <= 32'd0;
            delay_count <= 8'd0;
            irom_resp_valid <= 1'b0;
            irom_data <= {NOP, NOP};
            lfsr <= 16'h1ace;
            request_count <= 0;
            response_count <= 0;
        end else begin
            lfsr <= {lfsr[14:0],
                     lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            case (irom_state)
                I_IDLE: begin
                    irom_resp_valid <= 1'b0;
                    if (irom_req_valid && irom_req_ready) begin
                        pending_addr <= irom_req_addr;
                        delay_count <= {5'd0, lfsr[3:1]};
                        request_count <= request_count + 1;
                        irom_state <= I_WAIT;
                    end
                end
                I_WAIT: begin
                    if (delay_count != 8'd0)
                        delay_count <= delay_count - 8'd1;
                    else begin
                        irom_data <= {
                            irom[((pending_addr - RESET_PC) >> 2) + 1],
                            irom[((pending_addr - RESET_PC) >> 2)]
                        };
                        irom_resp_valid <= 1'b1;
                        response_count <= response_count + 1;
                        irom_state <= I_RESP;
                    end
                end
                I_RESP: begin
                    irom_resp_valid <= 1'b0;
                    irom_state <= I_IDLE;
                end
                default: irom_state <= I_IDLE;
            endcase
        end
    end

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "[FAIL] %s", message);
    endtask

    initial begin
        bit completed;

        rst_n = 1'b0;
        for (int i = 0; i < 256; i++)
            irom[i] = NOP;

        // Exact first TEST_BL expansion used by the fixed-latency regression.
        irom['h00 >> 2] = 32'h0010_041e;
        irom['h04 >> 2] = 32'h1518_7c50;
        irom['h08 >> 2] = 32'h02bb_ea10;
        irom['h0c >> 2] = 32'h15d6_57b1;
        irom['h10 >> 2] = 32'h0295_f231;
        irom['h14 >> 2] = 32'h1400_000a;
        irom['h18 >> 2] = 32'h1400_000b;
        irom['h1c >> 2] = 32'h5400_1800;
        irom['h20 >> 2] = 32'h0010_0025;
        irom['h24 >> 2] = 32'h1518_7c4a;
        irom['h28 >> 2] = 32'h02bb_e94a;
        irom['h2c >> 2] = 32'h5400_1400;
        irom['h30 >> 2] = 32'h5000_1c00;
        irom['h34 >> 2] = 32'h0010_0024;
        irom['h38 >> 2] = 32'h57ff_ebff;
        irom['h3c >> 2] = 32'h5000_1000;
        irom['h40 >> 2] = 32'h0010_0026;
        irom['h44 >> 2] = 32'h15d6_57ab;
        irom['h48 >> 2] = 32'h0295_f16b;
        irom['h4c >> 2] = 32'h0010_7801;
        irom['h50 >> 2] = 32'h0280_30c6;
        irom['h54 >> 2] = 32'h0280_041f;
        irom['h58 >> 2] = 32'h5000_0000;

        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        completed = 1'b0;
        for (int cycle = 0; cycle < 3000; cycle++) begin
            @(posedge clk);
            if ((debug0_valid && debug0_wen != 4'd0
                 && debug0_wnum == 5'd31 && debug0_wdata == 32'd1)
                || (debug1_valid && debug1_wen != 4'd0
                    && debug1_wnum == 5'd31 && debug1_wdata == 32'd1)) begin
                completed = 1'b1;
                break;
            end
        end

        check(completed, "variable-latency BL sequence timed out");
        repeat (3) @(posedge clk);
        check(u_cpu.u_regfile.regs[4] == RESET_PC + 32'h20,
              "first forward BL link under delayed IROM");
        check(u_cpu.u_regfile.regs[5] == RESET_PC + 32'h3c,
              "backward BL link under delayed IROM");
        check(u_cpu.u_regfile.regs[6] == u_cpu.u_regfile.regs[5],
              "BL link-distance relation under delayed IROM");
        check(response_count <= request_count,
              "IROM returned more packets than accepted requests");
        $display("[PASS] variable-latency Chiplab BL sequence requests=%0d responses=%0d",
                 request_count, response_count);
        $finish;
    end
endmodule
