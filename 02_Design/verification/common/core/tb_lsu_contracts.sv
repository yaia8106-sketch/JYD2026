`timescale 1ns/1ps

module tb_lsu_contracts;

    // 双发射 LSU 槽位选择与同组 store-data 旁路。
    logic        id_slot1_valid;
    logic        id_slot0_alu_only;
    logic        id_slot0_reg_write_en;
    logic [4:0]  id_slot0_rd;
    logic        id_slot1_mem_write_en;
    logic [4:0]  id_slot1_rs1;
    logic [4:0]  id_slot1_rs2;
    logic        id_slot0_to_slot1_store_bypass;
    logic        ex_slot1_valid;
    logic        ex_slot1_mem_read_en;
    logic        ex_slot1_mem_write_en;
    logic        ex_slot0_branch_redirect;
    logic        ex_slot0_priv_trap;
    logic        ex_slot1_addr_replay;
    logic        ex_slot1_lsu_select;
    logic        ex_slot1_side_effect_kill;
    logic        ex_slot0_store_bypass_q;
    logic [31:0] ex_slot0_alu_result;
    logic [31:0] ex_slot1_rs2_data;
    logic [31:0] ex_slot1_store_data;

    // 地址准备。
    logic [31:0] base_operand;
    logic [31:0] repaired_base_operand;
    logic [31:0] offset_operand;
    logic        use_repaired_base;
    logic [18:0] lookup_addr_low;
    logic [ 1:0] align_addr_low;

    // 原始 mem_interface 数据格式。
    logic        store_valid;
    logic        store_en;
    logic [ 1:0] store_addr_low;
    logic [ 1:0] store_mem_size;
    logic [31:0] store_data_in;
    logic [ 3:0] store_wea;
    logic [31:0] store_data_out;
    logic        load_en;
    logic [ 1:0] load_addr_low;
    logic [ 1:0] load_mem_size;
    logic        load_unsigned;
    logic [31:0] load_dram_dout;
    logic [31:0] load_data_out;

    // lsu_data_format 的双槽 store 门控及 NSCSCC 已格式化 load 路径。
    logic        fmt_s0_valid;
    logic        fmt_s0_kill;
    logic        fmt_s0_store;
    logic [ 1:0] fmt_s0_addr_low;
    logic [ 1:0] fmt_s0_mem_size;
    logic [31:0] fmt_s0_store_data;
    logic [ 3:0] fmt_s0_wea_raw;
    logic [ 3:0] fmt_s0_wea_cached;
    logic        fmt_s1_valid;
    logic        fmt_s1_kill;
    logic        fmt_s1_store;
    logic [ 1:0] fmt_s1_addr_low;
    logic [ 1:0] fmt_s1_mem_size;
    logic [31:0] fmt_s1_store_data;
    logic [ 3:0] fmt_s1_wea_raw;
    logic [ 3:0] fmt_s1_wea_cached;
    logic        fmt_load_en;
    logic [ 1:0] fmt_load_addr_low;
    logic [ 1:0] fmt_load_size;
    logic        fmt_load_unsigned;
    logic [31:0] fmt_load_data;
    logic [31:0] fmt_load_data_ex;
    logic [31:0] fmt_raw_result;
    logic [31:0] fmt_raw_repair_result;
    logic [31:0] fmt_cached_result;
    logic [31:0] fmt_cached_repair_result;

    integer cases;
    integer random_seed;
    integer random_state;
    logic [31:0] selected_base;
    logic [31:0] full_sum;

    dual_issue_lsu_ctrl u_dual_issue_lsu_ctrl (
        .*
    );

    lsu_address_prepare u_lsu_address_prepare (
        .*
    );

    mem_interface u_mem_interface (
        .*
    );

    lsu_data_format #(
        .CACHE_RDATA_FORMATTED(1'b0)
    ) u_lsu_data_format_raw (
        .ex_slot0_valid       (fmt_s0_valid),
        .ex_slot0_kill        (fmt_s0_kill),
        .ex_slot0_store       (fmt_s0_store),
        .ex_slot0_addr_low    (fmt_s0_addr_low),
        .ex_slot0_mem_size    (fmt_s0_mem_size),
        .ex_slot0_store_data  (fmt_s0_store_data),
        .ex_slot0_store_wea   (fmt_s0_wea_raw),
        .ex_slot1_valid       (fmt_s1_valid),
        .ex_slot1_kill        (fmt_s1_kill),
        .ex_slot1_store       (fmt_s1_store),
        .ex_slot1_addr_low    (fmt_s1_addr_low),
        .ex_slot1_mem_size    (fmt_s1_mem_size),
        .ex_slot1_store_data  (fmt_s1_store_data),
        .ex_slot1_store_wea   (fmt_s1_wea_raw),
        .mem_load_en          (fmt_load_en),
        .mem_load_addr_low    (fmt_load_addr_low),
        .mem_load_size        (fmt_load_size),
        .mem_load_unsigned    (fmt_load_unsigned),
        .mem_load_data        (fmt_load_data),
        .mem_load_data_ex     (fmt_load_data_ex),
        .mem_load_result      (fmt_raw_result),
        .mem_load_repair_result(fmt_raw_repair_result)
    );

    lsu_data_format #(
        .CACHE_RDATA_FORMATTED(1'b1)
    ) u_lsu_data_format_cached (
        .ex_slot0_valid       (fmt_s0_valid),
        .ex_slot0_kill        (fmt_s0_kill),
        .ex_slot0_store       (fmt_s0_store),
        .ex_slot0_addr_low    (fmt_s0_addr_low),
        .ex_slot0_mem_size    (fmt_s0_mem_size),
        .ex_slot0_store_data  (fmt_s0_store_data),
        .ex_slot0_store_wea   (fmt_s0_wea_cached),
        .ex_slot1_valid       (fmt_s1_valid),
        .ex_slot1_kill        (fmt_s1_kill),
        .ex_slot1_store       (fmt_s1_store),
        .ex_slot1_addr_low    (fmt_s1_addr_low),
        .ex_slot1_mem_size    (fmt_s1_mem_size),
        .ex_slot1_store_data  (fmt_s1_store_data),
        .ex_slot1_store_wea   (fmt_s1_wea_cached),
        .mem_load_en          (fmt_load_en),
        .mem_load_addr_low    (fmt_load_addr_low),
        .mem_load_size        (fmt_load_size),
        .mem_load_unsigned    (fmt_load_unsigned),
        .mem_load_data        (fmt_load_data),
        .mem_load_data_ex     (fmt_load_data_ex),
        .mem_load_result      (fmt_cached_result),
        .mem_load_repair_result(fmt_cached_repair_result)
    );

    function automatic logic [3:0] expected_store_wea(
        input logic       valid,
        input logic       enable,
        input logic [1:0] size,
        input logic [1:0] addr_low
    );
        logic [3:0] raw;
        begin
            case (size)
                2'b00: raw = 4'b0001 << addr_low;
                2'b01: raw = 4'b0011 << addr_low;
                2'b10: raw = 4'b1111;
                default: raw = 4'b0000;
            endcase
            expected_store_wea = (valid & enable) ? raw : 4'b0000;
        end
    endfunction

    function automatic logic [31:0] expected_load_data(
        input logic [31:0] word,
        input logic [ 1:0] addr_low,
        input logic [ 1:0] size,
        input logic        is_unsigned
    );
        logic [31:0] shifted;
        begin
            shifted = word >> {addr_low, 3'b0};
            case (size)
                2'b00: expected_load_data = is_unsigned
                    ? {24'd0, shifted[7:0]}
                    : {{24{shifted[7]}}, shifted[7:0]};
                2'b01: expected_load_data = is_unsigned
                    ? {16'd0, shifted[15:0]}
                    : {{16{shifted[15]}}, shifted[15:0]};
                2'b10: expected_load_data = shifted;
                default: expected_load_data = 32'd0;
            endcase
        end
    endfunction

    task automatic fail(input string message);
        $fatal(1, "[FAIL] LSU contract case=%0d: %s", cases, message);
    endtask

    task automatic clear_inputs;
        begin
            id_slot1_valid = 1'b0;
            id_slot0_alu_only = 1'b0;
            id_slot0_reg_write_en = 1'b0;
            id_slot0_rd = 5'd0;
            id_slot1_mem_write_en = 1'b0;
            id_slot1_rs1 = 5'd0;
            id_slot1_rs2 = 5'd0;
            ex_slot1_valid = 1'b0;
            ex_slot1_mem_read_en = 1'b0;
            ex_slot1_mem_write_en = 1'b0;
            ex_slot0_branch_redirect = 1'b0;
            ex_slot0_priv_trap = 1'b0;
            ex_slot1_addr_replay = 1'b0;
            ex_slot0_store_bypass_q = 1'b0;
            ex_slot0_alu_result = 32'd0;
            ex_slot1_rs2_data = 32'd0;

            base_operand = 32'd0;
            repaired_base_operand = 32'd0;
            offset_operand = 32'd0;
            use_repaired_base = 1'b0;

            store_valid = 1'b0;
            store_en = 1'b0;
            store_addr_low = 2'd0;
            store_mem_size = 2'd0;
            store_data_in = 32'd0;
            load_en = 1'b0;
            load_addr_low = 2'd0;
            load_mem_size = 2'd0;
            load_unsigned = 1'b0;
            load_dram_dout = 32'd0;

            fmt_s0_valid = 1'b0;
            fmt_s0_kill = 1'b0;
            fmt_s0_store = 1'b0;
            fmt_s0_addr_low = 2'd0;
            fmt_s0_mem_size = 2'd0;
            fmt_s0_store_data = 32'd0;
            fmt_s1_valid = 1'b0;
            fmt_s1_kill = 1'b0;
            fmt_s1_store = 1'b0;
            fmt_s1_addr_low = 2'd0;
            fmt_s1_mem_size = 2'd0;
            fmt_s1_store_data = 32'd0;
            fmt_load_en = 1'b0;
            fmt_load_addr_low = 2'd0;
            fmt_load_size = 2'd0;
            fmt_load_unsigned = 1'b0;
            fmt_load_data = 32'd0;
            fmt_load_data_ex = 32'd0;
        end
    endtask

    task automatic check_dual_issue_ctrl;
        logic exp_bypass;
        begin
            #1;
            exp_bypass = id_slot1_valid & id_slot0_alu_only
                       & id_slot1_mem_write_en & id_slot0_reg_write_en
                       & (id_slot0_rd != 5'd0)
                       & (id_slot1_rs2 == id_slot0_rd)
                       & (id_slot1_rs1 != id_slot0_rd);
            if (id_slot0_to_slot1_store_bypass !== exp_bypass)
                fail("same-group store-data bypass qualification mismatch");
            if (ex_slot1_lsu_select !==
                (ex_slot1_valid
                 & (ex_slot1_mem_read_en | ex_slot1_mem_write_en)))
                fail("Slot1 LSU selection mismatch");
            if (ex_slot1_side_effect_kill !==
                (ex_slot0_branch_redirect | ex_slot0_priv_trap
                 | ex_slot1_addr_replay))
                fail("younger Slot1 side-effect kill mismatch");
            if (ex_slot1_store_data !==
                (ex_slot0_store_bypass_q ? ex_slot0_alu_result
                                         : ex_slot1_rs2_data))
                fail("Slot1 store-data selection mismatch");
            cases = cases + 1;
        end
    endtask

    initial begin
        cases = 0;
        random_seed = 32'h1a50_2026;
        random_state = random_seed;
        random_state = $urandom(random_state);
        clear_inputs();

        // 控制逻辑使用随机矩阵覆盖所有门控位，并特别包含地址依赖禁止旁路。
        for (int i = 0; i < 5000; i++) begin
            id_slot1_valid = $urandom_range(0, 1);
            id_slot0_alu_only = $urandom_range(0, 1);
            id_slot0_reg_write_en = $urandom_range(0, 1);
            id_slot0_rd = $urandom_range(0, 31);
            id_slot1_mem_write_en = $urandom_range(0, 1);
            id_slot1_rs1 = $urandom_range(0, 31);
            id_slot1_rs2 = $urandom_range(0, 31);
            ex_slot1_valid = $urandom_range(0, 1);
            ex_slot1_mem_read_en = $urandom_range(0, 1);
            ex_slot1_mem_write_en = $urandom_range(0, 1);
            ex_slot0_branch_redirect = $urandom_range(0, 1);
            ex_slot0_priv_trap = $urandom_range(0, 1);
            ex_slot1_addr_replay = $urandom_range(0, 1);
            ex_slot0_store_bypass_q = $urandom_range(0, 1);
            ex_slot0_alu_result = $urandom;
            ex_slot1_rs2_data = $urandom;
            check_dual_issue_ctrl();
        end

        // 独立的低位加法器必须与完整 32 位有效地址的低 19/2 位一致。
        for (int i = 0; i < 5000; i++) begin
            base_operand = $urandom;
            repaired_base_operand = $urandom;
            offset_operand = $urandom;
            use_repaired_base = $urandom_range(0, 1);
            #1;
            selected_base = use_repaired_base
                          ? repaired_base_operand : base_operand;
            full_sum = selected_base + offset_operand;
            if (lookup_addr_low !== full_sum[18:0])
                fail("truncated DCache lookup address mismatch");
            if (align_addr_low !== full_sum[1:0])
                fail("independent alignment address mismatch");
            cases = cases + 1;
        end

        // 所有大小和低地址组合，包括非法未对齐候选；异常单元负责最终
        // 屏蔽非法访问，而格式单元本身必须保持确定的字节通道行为。
        store_data_in = 32'h89ab_cdef;
        store_valid = 1'b1;
        store_en = 1'b1;
        for (int size = 0; size < 4; size++) begin
            for (int addr = 0; addr < 4; addr++) begin
                store_mem_size = size;
                store_addr_low = addr;
                #1;
                if (store_wea !== expected_store_wea(
                        1'b1, 1'b1, store_mem_size, store_addr_low))
                    fail("store byte-enable mismatch");
                if (store_data_out !==
                    (store_data_in << {store_addr_low, 3'b0}))
                    fail("store data alignment mismatch");
                cases = cases + 1;
            end
        end
        store_valid = 1'b0;
        #1;
        if (store_wea !== 4'b0000)
            fail("invalid store was not suppressed");

        load_en = 1'b1;
        load_dram_dout = 32'h80ff_7f01;
        for (int size = 0; size < 4; size++) begin
            for (int addr = 0; addr < 4; addr++) begin
                for (int uns = 0; uns < 2; uns++) begin
                    load_mem_size = size;
                    load_addr_low = addr;
                    load_unsigned = uns;
                    #1;
                    if (load_data_out !== expected_load_data(
                            load_dram_dout, load_addr_low,
                            load_mem_size, load_unsigned))
                        fail("load extraction/sign-extension mismatch");
                    cases = cases + 1;
                end
            end
        end

        // 双槽 store kill 门控。
        fmt_s0_valid = 1'b1;
        fmt_s0_store = 1'b1;
        fmt_s0_addr_low = 2'd2;
        fmt_s0_mem_size = 2'b00;
        fmt_s1_valid = 1'b1;
        fmt_s1_store = 1'b1;
        fmt_s1_addr_low = 2'd0;
        fmt_s1_mem_size = 2'b01;
        #1;
        if (fmt_s0_wea_raw !== 4'b0100
            || fmt_s0_wea_cached !== 4'b0100
            || fmt_s1_wea_raw !== 4'b0011
            || fmt_s1_wea_cached !== 4'b0011)
            fail("two-slot store format mismatch");
        fmt_s0_kill = 1'b1;
        fmt_s1_kill = 1'b1;
        #1;
        if (fmt_s0_wea_raw !== 4'b0000
            || fmt_s1_wea_raw !== 4'b0000
            || fmt_s0_wea_cached !== 4'b0000
            || fmt_s1_wea_cached !== 4'b0000)
            fail("killed store retained a byte enable");
        cases = cases + 1;

        // NSCSCC DCache 已经格式化正常返回和 EX repair 返回，不能再进行
        // 二次移位/符号扩展；其他平台则共享原始字格式器。
        fmt_load_en = 1'b1;
        fmt_load_addr_low = 2'd3;
        fmt_load_size = 2'b00;
        fmt_load_unsigned = 1'b0;
        fmt_load_data = 32'h80ff_7f01;
        fmt_load_data_ex = 32'h1234_5678;
        #1;
        if (fmt_raw_result !== 32'hffff_ff80
            || fmt_raw_repair_result !== 32'hffff_ff80)
            fail("raw load/repair formatting mismatch");
        if (fmt_cached_result !== fmt_load_data
            || fmt_cached_repair_result !== fmt_load_data_ex)
            fail("NSCSCC formatted load path modified DCache data");
        cases = cases + 1;

        $display("[PASS] LSU control/address/data contracts cases=%0d seed=%0d",
                 cases, random_seed);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "[FAIL] LSU contract timeout");
    end

endmodule
