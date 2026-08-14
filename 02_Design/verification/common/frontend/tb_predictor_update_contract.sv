`timescale 1ns/1ps

module tb_predictor_update_contract;
    import cpu_defs::*;

    logic               clk;
    logic               rst_n;
    logic               ex_ready_go;
    logic               mem_allowin;
    logic               mem_branch_flush;
    predictor_resolve_t slot0_resolve;
    predictor_resolve_t slot1_resolve;
    logic               slot0_cfi_valid;
    logic               slot1_cfi_valid;
    predictor_train_t   train;
    abtb_update_t       abtb_update;
    pht_update_t        pht_update;
    abtb_update_t       abtb_write;
    pht_update_t        pht_write;

    integer cases;
    integer random_seed;
    integer random_state;
    logic prior_capture_valid;
    abtb_update_t prior_abtb_capture;
    pht_update_t  prior_pht_capture;

    predictor_update_ctrl dut (.*);

    always #5 clk = ~clk;

    task automatic fail(input string message);
        $fatal(1, "[FAIL] predictor update case=%0d: %s", cases, message);
    endtask

    task automatic clear_inputs;
        begin
            ex_ready_go = 1'b1;
            mem_allowin = 1'b1;
            mem_branch_flush = 1'b0;
            slot0_resolve = '0;
            slot1_resolve = '0;
        end
    endtask

    task automatic set_conditional(
        input logic       use_slot1,
        input logic [31:0] pc,
        input logic       taken,
        input logic [31:0] target,
        input logic       qualified,
        input logic [7:0] pht_index,
        input logic [1:0] pht_counter
    );
        predictor_resolve_t value;
        begin
            value = '0;
            value.valid = 1'b1;
            value.pc = pc;
            value.is_conditional_branch = 1'b1;
            value.actual_taken = taken;
            value.actual_target = target;
            value.update_qualified = qualified;
            value.update_cfi_type = CFI_TYPE_BRANCH;
            value.abtb_hit = pc[2];
            value.abtb_way = pc[3];
            value.pht_index = pht_index;
            value.pht_counter = pht_counter;
            if (use_slot1)
                slot1_resolve = value;
            else
                slot0_resolve = value;
        end
    endtask

    task automatic set_jump(
        input logic        use_slot1,
        input logic [31:0] pc,
        input logic [31:0] target,
        input logic        indirect,
        input logic        qualified,
        input logic [ 1:0] cfi_type
    );
        predictor_resolve_t value;
        begin
            value = '0;
            value.valid = 1'b1;
            value.pc = pc;
            value.is_direct_jump = ~indirect;
            value.is_indirect_jump = indirect;
            value.actual_taken = 1'b1;
            value.actual_target = target;
            value.update_qualified = qualified;
            value.update_cfi_type = cfi_type;
            value.abtb_hit = pc[2];
            value.abtb_way = pc[3];
            if (use_slot1)
                slot1_resolve = value;
            else
                slot0_resolve = value;
        end
    endtask

    // 参考模型保留未拆分的语义方程，避免测试只复述 DUT 的物理优化写法。
    task automatic build_reference(
        output logic             exp_slot0_cfi,
        output logic             exp_slot1_cfi,
        output predictor_train_t exp_train,
        output abtb_update_t     exp_abtb,
        output pht_update_t      exp_pht
    );
        predictor_resolve_t selected;
        logic fire;
        logic selected_slot1;
        logic abtb_qualified;
        begin
            exp_slot0_cfi = slot0_resolve.valid
                & (slot0_resolve.is_conditional_branch
                   | slot0_resolve.is_direct_jump
                   | slot0_resolve.is_indirect_jump);
            exp_slot1_cfi = slot1_resolve.valid
                & (slot1_resolve.is_conditional_branch
                   | slot1_resolve.is_direct_jump
                   | slot1_resolve.is_indirect_jump);
            selected_slot1 = exp_slot1_cfi;
            selected = selected_slot1 ? slot1_resolve : slot0_resolve;
            fire = ex_ready_go & mem_allowin & ~mem_branch_flush;

            exp_train = '0;
            exp_train.valid = fire & (exp_slot0_cfi | exp_slot1_cfi);
            exp_train.from_slot1 = selected_slot1;
            exp_train.pc = selected.pc;
            exp_train.is_conditional_branch =
                selected.is_conditional_branch;
            exp_train.is_direct_jump = selected.is_direct_jump;
            exp_train.is_indirect_jump = selected.is_indirect_jump;
            exp_train.actual_taken = selected.actual_taken;
            exp_train.actual_target = selected.actual_target;

            abtb_qualified = selected.update_qualified
                & ((selected.update_cfi_type != CFI_TYPE_BRANCH)
                   | selected.actual_taken);
            exp_abtb = '0;
            exp_abtb.valid = fire & selected.valid & abtb_qualified;
            exp_abtb.hit = selected.abtb_hit;
            exp_abtb.way = selected.abtb_way;
            exp_abtb.pc = selected.pc;
            exp_abtb.cfi_type = selected.update_cfi_type;
            exp_abtb.target = selected.actual_target;

            exp_pht = '0;
            exp_pht.valid = fire & selected.valid
                          & selected.is_conditional_branch;
            exp_pht.index = selected.pht_index;
            exp_pht.counter = selected.pht_counter;
            exp_pht.actual_taken = selected.actual_taken;
        end
    endtask

    task automatic check_cycle(input string name);
        logic exp_slot0_cfi;
        logic exp_slot1_cfi;
        predictor_train_t exp_train;
        abtb_update_t exp_abtb;
        pht_update_t exp_pht;
        begin
            #1;
            // 从上一时钟沿捕获的 write 在本周期内必须稳定。这个检查专门
            // 覆盖“新出现的 flush 不能撤销已经捕获的训练事件”。
            if (prior_capture_valid) begin
                if (abtb_write !== prior_abtb_capture)
                    fail("prior ABTB write changed before the next edge");
                if (pht_write !== prior_pht_capture)
                    fail("prior PHT write changed before the next edge");
            end
            build_reference(exp_slot0_cfi, exp_slot1_cfi,
                            exp_train, exp_abtb, exp_pht);
            if (slot0_cfi_valid !== exp_slot0_cfi
                || slot1_cfi_valid !== exp_slot1_cfi)
                fail("CFI candidate classification mismatch");
            if (train !== exp_train)
                fail("EX-aligned training payload mismatch");
            if (abtb_update !== exp_abtb)
                fail("EX-aligned ABTB update mismatch");
            if (pht_update !== exp_pht)
                fail("EX-aligned PHT update mismatch");

            // 写口必须恰好在这个边沿捕获当前事件及 payload。
            @(posedge clk);
            #1;
            if (abtb_write !== exp_abtb)
                fail("registered ABTB event was not delayed by exactly one edge");
            if (pht_write !== exp_pht)
                fail("registered PHT event was not delayed by exactly one edge");
            prior_capture_valid = 1'b1;
            prior_abtb_capture = exp_abtb;
            prior_pht_capture = exp_pht;
            cases = cases + 1;
            if (cases <= 13)
                $display("[INFO] predictor update case %0d: %s", cases, name);
            @(negedge clk);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cases = 0;
        random_seed = 32'hab7b_2026;
        random_state = random_seed;
        random_state = $urandom(random_state);
        prior_capture_valid = 1'b0;
        prior_abtb_capture = '0;
        prior_pht_capture = '0;
        clear_inputs();
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        clear_inputs();
        check_cycle("idle cycle leaves both write ports invalid");

        clear_inputs();
        set_conditional(1'b0, 32'h1c00_0100, 1'b0, 32'h1c00_0200,
                        1'b1, 8'h31, 2'b10);
        check_cycle("not-taken branch trains PHT without allocating ABTB");

        clear_inputs();
        set_conditional(1'b0, 32'h1c00_0110, 1'b1, 32'h1c00_0300,
                        1'b1, 8'ha2, 2'b01);
        check_cycle("taken Slot0 branch updates PHT and ABTB");

        clear_inputs();
        set_jump(1'b0, 32'h1c00_0120, 32'h1c00_0420,
                 1'b0, 1'b1, CFI_TYPE_CALL);
        check_cycle("direct jump updates ABTB but not PHT");

        clear_inputs();
        set_jump(1'b1, 32'h1c00_0134, 32'h1c00_0550,
                 1'b1, 1'b1, CFI_TYPE_RETURN);
        check_cycle("Slot1 indirect jump selects Slot1 payload");

        clear_inputs();
        set_conditional(1'b0, 32'h1c00_0140, 1'b1, 32'h1c00_0600,
                        1'b0, 8'h5c, 2'b11);
        check_cycle("unqualified branch still trains direction only");

        clear_inputs();
        set_jump(1'b0, 32'h1c00_0150, 32'h1c00_0700,
                 1'b0, 1'b1, CFI_TYPE_JUMP);
        ex_ready_go = 1'b0;
        check_cycle("EX stall suppresses predictor capture");

        clear_inputs();
        set_jump(1'b0, 32'h1c00_0160, 32'h1c00_0800,
                 1'b0, 1'b1, CFI_TYPE_JUMP);
        mem_allowin = 1'b0;
        check_cycle("MEM backpressure suppresses predictor capture");

        clear_inputs();
        set_jump(1'b0, 32'h1c00_0170, 32'h1c00_0900,
                 1'b0, 1'b1, CFI_TYPE_JUMP);
        mem_branch_flush = 1'b1;
        check_cycle("older redirect suppresses wrong-path capture");

        // 连续周期事件覆盖寄存边界的吞吐和顺序。第二个周期同时出现 flush，
        // 它只能阻止第二个事件，不能撤销当前仍可见的第一个 write。
        clear_inputs();
        set_jump(1'b0, 32'h1c00_0180, 32'h1c00_0a00,
                 1'b0, 1'b1, CFI_TYPE_JUMP);
        check_cycle("capture event before a later redirect");
        clear_inputs();
        set_jump(1'b1, 32'h1c00_0194, 32'h1c00_0b00,
                 1'b1, 1'b1, CFI_TYPE_RETURN);
        mem_branch_flush = 1'b1;
        check_cycle("later redirect suppresses only the next event");

        clear_inputs();
        set_conditional(1'b0, 32'h1c00_01a0, 1'b1, 32'h1c00_0c00,
                        1'b1, 8'h44, 2'b10);
        check_cycle("first event of a full-rate pair");
        clear_inputs();
        set_jump(1'b1, 32'h1c00_01b4, 32'h1c00_0d00,
                 1'b1, 1'b1, CFI_TYPE_CALL);
        check_cycle("second event of a full-rate pair");

        // 约束随机覆盖：每周期最多一个 CFI，保持真实发射策略不变量。
        for (int i = 0; i < 3000; i++) begin
            clear_inputs();
            ex_ready_go = $urandom_range(0, 1);
            mem_allowin = $urandom_range(0, 1);
            mem_branch_flush = $urandom_range(0, 1);
            case ($urandom_range(0, 2))
                1: begin
                    if ($urandom_range(0, 1))
                        set_conditional(1'b0, $urandom, $urandom_range(0, 1),
                            $urandom, $urandom_range(0, 1),
                            $urandom, $urandom_range(0, 3));
                    else
                        set_jump(1'b0, $urandom, $urandom,
                            $urandom_range(0, 1), $urandom_range(0, 1),
                            cfi_type_t'($urandom_range(0, 3)));
                end
                2: begin
                    if ($urandom_range(0, 1))
                        set_conditional(1'b1, $urandom, $urandom_range(0, 1),
                            $urandom, $urandom_range(0, 1),
                            $urandom, $urandom_range(0, 3));
                    else
                        set_jump(1'b1, $urandom, $urandom,
                            $urandom_range(0, 1), $urandom_range(0, 1),
                            cfi_type_t'($urandom_range(0, 3)));
                end
                default: begin
                    // 无 CFI 周期也允许一个普通有效指令存在。
                    slot0_resolve.valid = $urandom_range(0, 1);
                end
            endcase
            check_cycle("constrained random capture/update state");
        end

        $display("[PASS] predictor update contract cases=%0d seed=%0d",
                 cases, random_seed);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "[FAIL] predictor update contract timeout");
    end

endmodule
