`timescale 1ns / 1ps

`include "physical_mem_paths.vh"

module PhysicalDramBank #(
    parameter string MEM_FILE = "",
    parameter int    BANK_WORDS = 16384,
    parameter int    ADDR_WIDTH = 14
) (
    input  logic        clka,
    input  logic [3:0]  wea,
    input  logic [ADDR_WIDTH-1:0] addra,
    input  logic [31:0] dina,

    input  logic        clkb,
    input  logic        enb,
    input  logic [ADDR_WIDTH-1:0] addrb,
    output logic [31:0] doutb
);

    (* ram_style = "block" *) logic [31:0] mem [0:BANK_WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < BANK_WORDS; i = i + 1)
            mem[i] = 32'd0;
        $readmemh(MEM_FILE, mem);
    end

    always_ff @(posedge clka) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    always_ff @(posedge clkb) begin
        if (enb)
            doutb <= mem[addrb];
    end

endmodule

module DRAM4MyOwn #(
    parameter int BANK_WORDS      = 16384,
    parameter int BANK_ADDR_WIDTH = 14
) (
    input  logic        clka,
    input  logic [3:0]  wea,
    input  logic [15:0] addra,
    input  logic [31:0] dina,

    input  logic        clkb,
    input  logic        enb,
    input  logic [15:0] addrb,
    output logic [31:0] doutb
);

    `include "physical_dram_map.vh"

    wire [5:0] wr_phys_page = pt_dram_page_map(addra[15:10]);
    wire [5:0] rd_phys_page = pt_dram_page_map(addrb[15:10]);
    wire wr_in_range = (wr_phys_page < `PT_DRAM_PHYS_PAGES);
    wire rd_in_range = (rd_phys_page < `PT_DRAM_PHYS_PAGES);
    wire [1:0] wr_bank = wr_phys_page[5:4];
    wire [1:0] rd_bank = rd_phys_page[5:4];
    wire [BANK_ADDR_WIDTH-1:0] wr_index = {wr_phys_page[3:0], addra[9:0]};
    wire [BANK_ADDR_WIDTH-1:0] rd_index = {rd_phys_page[3:0], addrb[9:0]};

    wire [3:0] bank0_wea = (wr_in_range && (wr_bank == 2'd0)) ? wea : 4'd0;
    wire [3:0] bank1_wea = (wr_in_range && (wr_bank == 2'd1)) ? wea : 4'd0;
    wire [3:0] bank2_wea = (wr_in_range && (wr_bank == 2'd2)) ? wea : 4'd0;

    logic [31:0] bank0_dout;
    logic [31:0] bank1_dout;
    logic [31:0] bank2_dout;
    logic [1:0] rd_bank_d1;
    logic rd_in_range_d1;

    PhysicalDramBank #(
        .MEM_FILE(`PT_DRAM_BANK0_MEM),
        .BANK_WORDS(BANK_WORDS),
        .ADDR_WIDTH(BANK_ADDR_WIDTH)
    ) u_bank0 (
        .clka(clka),
        .wea(bank0_wea),
        .addra(wr_index),
        .dina(dina),
        .clkb(clkb),
        .enb(enb),
        .addrb(rd_index),
        .doutb(bank0_dout)
    );

    PhysicalDramBank #(
        .MEM_FILE(`PT_DRAM_BANK1_MEM),
        .BANK_WORDS(BANK_WORDS),
        .ADDR_WIDTH(BANK_ADDR_WIDTH)
    ) u_bank1 (
        .clka(clka),
        .wea(bank1_wea),
        .addra(wr_index),
        .dina(dina),
        .clkb(clkb),
        .enb(enb),
        .addrb(rd_index),
        .doutb(bank1_dout)
    );

    PhysicalDramBank #(
        .MEM_FILE(`PT_DRAM_BANK2_MEM),
        .BANK_WORDS(BANK_WORDS),
        .ADDR_WIDTH(BANK_ADDR_WIDTH)
    ) u_bank2 (
        .clka(clka),
        .wea(bank2_wea),
        .addra(wr_index),
        .dina(dina),
        .clkb(clkb),
        .enb(enb),
        .addrb(rd_index),
        .doutb(bank2_dout)
    );

    always_ff @(posedge clkb) begin
        if (enb) begin
            rd_bank_d1 <= rd_bank;
            rd_in_range_d1 <= rd_in_range;
        end

        if (!rd_in_range_d1) begin
            doutb <= 32'd0;
        end else begin
            case (rd_bank_d1)
                2'd0: doutb <= bank0_dout;
                2'd1: doutb <= bank1_dout;
                2'd2: doutb <= bank2_dout;
                default: doutb <= 32'd0;
            endcase
        end
    end

endmodule
