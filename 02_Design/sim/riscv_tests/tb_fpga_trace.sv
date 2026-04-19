`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_fpga_trace
// Description: Simulates the actual FPGA test program and traces
//              key store-related signals to verify FIX-C timing.
// ============================================================

module tb_fpga_trace;

    reg clk = 0;
    reg rst_n = 0;

    always #5 clk = ~clk;  // 100MHz

    // ---- CPU ↔ IROM ----
    wire [31:0] irom_addr;
    wire [31:0] irom_data;

    // ---- CPU ↔ Peripherals ----
    wire [31:0] perip_addr;
    wire [31:0] perip_addr_sum;
    wire [31:0] perip_wr_addr;
    wire [3:0]  perip_wea;
    wire [31:0] perip_wdata;
    wire [31:0] perip_rdata;

    // ---- CPU ----
    cpu_top u_cpu (
        .clk         (clk),
        .rst_n       (rst_n),
        .irom_addr   (irom_addr),
        .irom_data   (irom_data),
        .perip_addr     (perip_addr),
        .perip_addr_sum (perip_addr_sum),
        .perip_wr_addr  (perip_wr_addr),
        .perip_wea      (perip_wea),
        .perip_wdata    (perip_wdata),
        .perip_rdata    (perip_rdata)
    );

    // ---- IROM (1-cycle latency, no output register) ----
    reg [31:0] irom [0:4095];
    reg [31:0] irom_dout;

    initial $readmemh("fpga_irom.hex", irom);

    always @(posedge clk) begin
        irom_dout <= irom[irom_addr[13:2]];
    end
    assign irom_data = irom_dout;

    // ---- DRAM (SDP model: Port A write, Port B read) ----
    reg [31:0] dram [0:65535];
    reg [31:0] dram_dout;

    initial begin
        integer i;
        for (i = 0; i < 65536; i = i + 1) dram[i] = 32'd0;
        $readmemh("fpga_dram.hex", dram);
    end

    // Port B read address (EX stage)
    wire [15:0] dram_rd_word_addr = perip_addr[17:2];
    // Port A write address (MEM stage)
    wire [15:0] dram_wr_word_addr = perip_wr_addr[17:2];

    // Address decode
    wire rd_is_dram = (perip_addr[31:18] == 14'b1000_0000_0001_00);
    wire wr_is_dram = (perip_wr_addr[31:18] == 14'b1000_0000_0001_00);

    wire [3:0] dram_wea = {4{wr_is_dram}} & perip_wea;

    // SDP DRAM model
    always @(posedge clk) begin
        // Port A: write (MEM stage)
        if (dram_wea[0]) dram[dram_wr_word_addr][ 7: 0] <= perip_wdata[ 7: 0];
        if (dram_wea[1]) dram[dram_wr_word_addr][15: 8] <= perip_wdata[15: 8];
        if (dram_wea[2]) dram[dram_wr_word_addr][23:16] <= perip_wdata[23:16];
        if (dram_wea[3]) dram[dram_wr_word_addr][31:24] <= perip_wdata[31:24];

        // Port B: read (EX stage address)
        dram_dout <= dram[dram_rd_word_addr];
    end

    // ---- MMIO model (simplified) ----
    reg [31:0] mem_addr;
    reg        mem_is_dram;
    reg [31:0] led_reg;
    reg [31:0] seg_wdata;

    always @(posedge clk) begin
        mem_addr    <= perip_addr;
        mem_is_dram <= rd_is_dram;
    end

    // MMIO write (MEM stage signals)
    wire mmio_wr = |perip_wea & ~wr_is_dram;
    wire wr_led  = mmio_wr & (perip_wr_addr[6:4] == 3'b100);
    wire wr_seg  = mmio_wr & (perip_wr_addr[6:4] == 3'b010);

    always @(posedge clk) begin
        if (!rst_n) begin
            led_reg   <= 32'd0;
            seg_wdata <= 32'd0;
        end else begin
            if (wr_led) led_reg   <= perip_wdata;
            if (wr_seg) seg_wdata <= perip_wdata;
        end
    end

    // MMIO read
    wire [31:0] mmio_rdata = ({32{mem_addr == 32'h8020_0000}} & 64'd0)    // sw0
                           | ({32{mem_addr == 32'h8020_0004}} & 32'd0)    // sw1
                           | ({32{mem_addr == 32'h8020_0010}} & 32'd0)    // key
                           | ({32{mem_addr == 32'h8020_0020}} & seg_wdata)
                           | ({32{mem_addr == 32'h8020_0050}} & 32'd0);   // cnt

    assign perip_rdata = ({32{mem_is_dram}}  & dram_dout)
                       | ({32{~mem_is_dram}} & mmio_rdata);

    // ---- Reset ----
    initial begin
        #20 rst_n = 1;
    end

    // ---- Store signal tracing ----
    integer cycle_count = 0;

    // Internal signals via hierarchical access
    wire        ex_valid       = u_cpu.ex_valid;
    wire        ex_mem_write   = u_cpu.ex_mem_write_en;
    wire        ex_mem_read    = u_cpu.ex_mem_read_en;
    wire [31:0] ex_pc          = u_cpu.ex_pc;
    wire [3:0]  dram_wea_int   = u_cpu.dram_wea;
    wire        mem_valid      = u_cpu.mem_valid;
    wire [3:0]  mem_store_wea  = u_cpu.mem_store_wea;
    wire [31:0] mem_alu_result = u_cpu.mem_alu_result;
    wire [31:0] mem_pc         = u_cpu.mem_pc;
    wire        sl_hazard      = u_cpu.store_load_hazard;
    wire        ex_ready_go    = u_cpu.ex_ready_go_w;
    wire [31:0] pc             = u_cpu.pc;

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;

        // Print when store or store-load hazard happens
        if (rst_n && |perip_wea) begin
            $display("[%0d] STORE: pc_mem=%h wr_addr=%h wea=%b wdata=%h dram=%b mem_valid=%b",
                     cycle_count, mem_pc, perip_wr_addr, perip_wea, perip_wdata,
                     wr_is_dram, mem_valid);
        end

        if (rst_n && sl_hazard) begin
            $display("[%0d] ** HAZARD ** ex_pc=%h ex_addr=%h mem_pc=%h mem_addr=%h mem_wea=%b",
                     cycle_count, ex_pc, perip_addr, mem_pc, perip_wr_addr, mem_store_wea);
        end

        // Print when load reads from DRAM
        if (rst_n && ex_valid && ex_mem_read && rd_is_dram) begin
            $display("[%0d] LOAD-EX: pc=%h rd_addr=%h sl_hazard=%b",
                     cycle_count, ex_pc, perip_addr, sl_hazard);
        end
    end

    // ---- Result monitoring ----
    // Monitor DRAM[0] (pass count) and DRAM[1] (fail count)
    reg [31:0] last_pass_count = 0;
    reg [31:0] last_fail_count = 0;
    reg [31:0] last_led = 0;

    always @(posedge clk) begin
        if (dram[0] != last_pass_count) begin
            $display("[%0d] PASS_COUNT changed: %0d -> %0d", cycle_count, last_pass_count, dram[0]);
            last_pass_count <= dram[0];
        end
        if (dram[1] != last_fail_count) begin
            $display("[%0d] !! FAIL_COUNT changed: %0d -> %0d !!", cycle_count, last_fail_count, dram[1]);
            last_fail_count <= dram[1];
        end
        if (led_reg != last_led && led_reg != 0) begin
            $display("[%0d] LED = %h (pass pattern=20041808, fail pattern=20004824)",
                     cycle_count, led_reg);
            last_led <= led_reg;
        end
    end

    // ---- Deadloop / timeout detection ----
    reg [31:0] prev_pc = 0;
    integer same_pc_count = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (pc == prev_pc) begin
                same_pc_count <= same_pc_count + 1;
                if (same_pc_count == 100) begin
                    $display("\n[%0d] DEADLOOP detected at PC=%h", cycle_count, pc);
                    $display("  DRAM[0] (pass) = %0d", dram[0]);
                    $display("  DRAM[1] (fail) = %0d", dram[1]);
                    $display("  LED = %h", led_reg);
                    $display("  SEG = %h", seg_wdata);
                    if (led_reg == 32'h20041808) $display("  >>> RESULT: PASS <<<");
                    else if (led_reg == 32'h20004824) $display("  >>> RESULT: FAIL <<<");
                    else $display("  >>> RESULT: UNKNOWN (no LED output) <<<");
                    $finish;
                end
            end else begin
                same_pc_count <= 0;
            end
            prev_pc <= pc;
        end
    end

    // Timeout
    initial begin
        #100_000_000;  // 10M cycles at 100MHz
        $display("\n[TIMEOUT] Simulation did not complete in 10M cycles");
        $display("  PC = %h", pc);
        $display("  DRAM[0] = %0d, DRAM[1] = %0d", dram[0], dram[1]);
        $finish;
    end

endmodule
