// Simulation-only fixed-latency replacement for Chiplab's
// soc_axi_delay_rand. It is selected only by run_rtl_perf_profile.py and does
// not enter the submitted RTL, Vivado project, or official Tcl flow.
//
// An accepted AR records its issue cycle. The first R beat of that transaction
// is held until +perf_read_latency cycles have elapsed; remaining burst beats
// then flow without artificial gaps. Up to four accepted read transactions
// retain independent issue times, matching the competition wrapper's four
// outstanding delay slots. B responses use the analogous
// +perf_write_latency delay from AW acceptance.

module soc_axi_delay_rand #(
    parameter BUS_WIDTH = 32,
    parameter DATA_WIDTH = 64,
    parameter CPU_WIDTH = 32
) (
    input  wire                      enable_delay,
    input  wire [22:0]               random_seed,

    output wire [BUS_WIDTH-1:0]      s_araddr,
    output wire [1:0]                s_arburst,
    output wire [3:0]                s_arcache,
    output wire [3:0]                s_arid,
    output wire [3:0]                s_arlen,
    output wire [1:0]                s_arlock,
    output wire [2:0]                s_arprot,
    input  wire                      s_arready,
    output wire [2:0]                s_arsize,
    output wire                      s_arvalid,
    output wire [BUS_WIDTH-1:0]      s_awaddr,
    output wire [1:0]                s_awburst,
    output wire [3:0]                s_awcache,
    output wire [3:0]                s_awid,
    output wire [3:0]                s_awlen,
    output wire [1:0]                s_awlock,
    output wire [2:0]                s_awprot,
    input  wire                      s_awready,
    output wire [2:0]                s_awsize,
    output wire                      s_awvalid,
    input  wire [3:0]                s_bid,
    output wire                      s_bready,
    input  wire [1:0]                s_bresp,
    input  wire                      s_bvalid,
    input  wire                      aclk,
    input  wire                      aresetn,
    input  wire [DATA_WIDTH-1:0]     s_rdata,
    input  wire [3:0]                s_rid,
    input  wire                      s_rlast,
    output wire                      s_rready,
    input  wire [1:0]                s_rresp,
    input  wire                      s_rvalid,
    output wire [DATA_WIDTH-1:0]     s_wdata,
    output wire [3:0]                s_wid,
    output wire                      s_wlast,
    input  wire                      s_wready,
    output wire [DATA_WIDTH/8-1:0]   s_wstrb,
    output wire                      s_wvalid,

    input  wire [BUS_WIDTH-1:0]      m_araddr,
    input  wire [1:0]                m_arburst,
    input  wire [3:0]                m_arcache,
    input  wire [3:0]                m_arid,
    input  wire [3:0]                m_arlen,
    input  wire [1:0]                m_arlock,
    input  wire [2:0]                m_arprot,
    output wire                      m_arready,
    input  wire [2:0]                m_arsize,
    input  wire                      m_arvalid,
    input  wire [BUS_WIDTH-1:0]      m_awaddr,
    input  wire [1:0]                m_awburst,
    input  wire [3:0]                m_awcache,
    input  wire [3:0]                m_awid,
    input  wire [3:0]                m_awlen,
    input  wire [1:0]                m_awlock,
    input  wire [2:0]                m_awprot,
    output wire                      m_awready,
    input  wire [2:0]                m_awsize,
    input  wire                      m_awvalid,
    output wire [3:0]                m_bid,
    input  wire                      m_bready,
    output wire [1:0]                m_bresp,
    output wire                      m_bvalid,
    output wire [DATA_WIDTH-1:0]     m_rdata,
    output wire [3:0]                m_rid,
    output wire                      m_rlast,
    input  wire                      m_rready,
    output wire [1:0]                m_rresp,
    output wire                      m_rvalid,
    input  wire [DATA_WIDTH-1:0]     m_wdata,
    input  wire [3:0]                m_wid,
    input  wire                      m_wlast,
    output wire                      m_wready,
    input  wire [DATA_WIDTH/8-1:0]   m_wstrb,
    input  wire                      m_wvalid
);

    integer fixed_read_latency;
    integer fixed_write_latency;
    initial begin
        if (!$value$plusargs("perf_read_latency=%d", fixed_read_latency))
            fixed_read_latency = 0;
        if (!$value$plusargs("perf_write_latency=%d", fixed_write_latency))
            fixed_write_latency = 0;
    end

    reg [63:0] cycle_q;
    reg [63:0] read_issue_cycle_q [0:3];
    reg [63:0] write_issue_cycle_q [0:3];
    reg [1:0] read_head_q;
    reg [1:0] read_tail_q;
    reg [2:0] read_count_q;
    reg [1:0] write_head_q;
    reg [1:0] write_tail_q;
    reg [2:0] write_count_q;
    reg       read_burst_active_q;

    wire fixed_read_enable = enable_delay && (fixed_read_latency > 0);
    wire fixed_write_enable = enable_delay && (fixed_write_latency > 0);
    wire read_delay_elapsed =
        (read_count_q != 0)
        && ((cycle_q - read_issue_cycle_q[read_head_q])
            >= 64'(fixed_read_latency));
    wire write_delay_elapsed =
        (write_count_q != 0)
        && ((cycle_q - write_issue_cycle_q[write_head_q])
            >= 64'(fixed_write_latency));
    wire release_read =
        !fixed_read_enable || read_burst_active_q || read_delay_elapsed;
    wire release_write_response =
        !fixed_write_enable || write_delay_elapsed;

    assign s_araddr  = m_araddr;
    assign s_arburst = m_arburst;
    assign s_arcache = m_arcache;
    assign s_arid    = m_arid;
    assign s_arlen   = m_arlen;
    assign s_arlock  = m_arlock;
    assign s_arprot  = m_arprot;
    assign s_arsize  = m_arsize;
    assign s_arvalid = m_arvalid;
    assign m_arready = s_arready;

    assign s_awaddr  = m_awaddr;
    assign s_awburst = m_awburst;
    assign s_awcache = m_awcache;
    assign s_awid    = m_awid;
    assign s_awlen   = m_awlen;
    assign s_awlock  = m_awlock;
    assign s_awprot  = m_awprot;
    assign s_awsize  = m_awsize;
    assign s_awvalid = m_awvalid;
    assign m_awready = s_awready;

    assign s_wdata  = m_wdata;
    assign s_wid    = m_wid;
    assign s_wlast  = m_wlast;
    assign s_wstrb  = m_wstrb;
    assign s_wvalid = m_wvalid;
    assign m_wready = s_wready;

    assign m_rdata  = s_rdata;
    assign m_rid    = s_rid;
    assign m_rlast  = s_rlast;
    assign m_rresp  = s_rresp;
    assign m_rvalid = s_rvalid && release_read;
    assign s_rready = m_rready && release_read;

    assign m_bid    = s_bid;
    assign m_bresp  = s_bresp;
    assign m_bvalid = s_bvalid && release_write_response;
    assign s_bready = m_bready && release_write_response;

    wire ar_fire = m_arvalid && m_arready;
    wire r_fire = m_rvalid && m_rready;
    wire rlast_fire = r_fire && m_rlast;
    wire aw_fire = m_awvalid && m_awready;
    wire b_fire = m_bvalid && m_bready;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cycle_q <= 0;
            read_head_q <= 0;
            read_tail_q <= 0;
            read_count_q <= 0;
            write_head_q <= 0;
            write_tail_q <= 0;
            write_count_q <= 0;
            read_burst_active_q <= 1'b0;
        end else begin
            cycle_q <= cycle_q + 1'b1;

            if (ar_fire) begin
                read_issue_cycle_q[read_tail_q] <= cycle_q;
                read_tail_q <= read_tail_q + 1'b1;
            end
            if (rlast_fire)
                read_head_q <= read_head_q + 1'b1;
            case ({ar_fire, rlast_fire})
                2'b10: read_count_q <= read_count_q + 1'b1;
                2'b01: read_count_q <= read_count_q - 1'b1;
                default: read_count_q <= read_count_q;
            endcase

            if (r_fire) begin
                if (m_rlast)
                    read_burst_active_q <= 1'b0;
                else
                    read_burst_active_q <= 1'b1;
            end

            if (aw_fire) begin
                write_issue_cycle_q[write_tail_q] <= cycle_q;
                write_tail_q <= write_tail_q + 1'b1;
            end
            if (b_fire)
                write_head_q <= write_head_q + 1'b1;
            case ({aw_fire, b_fire})
                2'b10: write_count_q <= write_count_q + 1'b1;
                2'b01: write_count_q <= write_count_q - 1'b1;
                default: write_count_q <= write_count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge aclk) begin
        if (aresetn && ar_fire && (read_count_q == 4) && !rlast_fire)
            $error("fixed AXI delay read timestamp queue overflow");
        if (aresetn && r_fire && (read_count_q == 0))
            $error("fixed AXI delay received R without an accepted AR");
        if (aresetn && aw_fire && (write_count_q == 4) && !b_fire)
            $error("fixed AXI delay write timestamp queue overflow");
        if (aresetn && b_fire && (write_count_q == 0))
            $error("fixed AXI delay received B without an accepted AW");
    end
`endif

    wire unused_random_seed = ^random_seed;
    wire unused_cpu_width = CPU_WIDTH == CPU_WIDTH;

endmodule
