`timescale 1ns/1ps

module tb_backend_flow_contract;

    logic clk;
    logic rst_n;

    logic cache_ready;
    logic wb_allowin;
    logic id_valid;
    logic id_issue_is_muldiv;
    logic id_issue_serializing;
    logic id_decoded_serializing;
    logic id_dependency_ready;
    logic id_dependency_ready_if_mem_ready;
    logic id_dependency_ready_if_mem_wait;
    logic id_non_load_hazard;
    logic id_flush;
    logic ex_valid;
    logic ex_slot1_valid;
    logic ex_is_muldiv;
    logic ex_is_divrem;
    logic ex_priv_wait_older;
    logic mmio_store_load_hazard;
    logic mem_valid;
    logic mem_slot1_valid;
    logic mem_is_mul;
    logic mem_branch_flush;
    logic wb_valid;
    logic wb_slot1_valid;
    logic muldiv_busy;
    logic muldiv_done;
    logic muldiv_consume;
    logic serializing_inflight;
    logic timer_irq_request;
    logic timer_irq_hold;

    logic ex_muldiv_ready;
    logic ex_priv_ready;
    logic ex_priv_commit_ready;
    logic ex_ready_go;
    logic mem_ready_go;
    logic mem_allowin_lsu;
    logic mem_allowin_control;
    logic mem_allowin_pipe;
    logic timer_irq_block;
    logic id_serializing_ready;
    logic id_barrier_ready;
    logic id_muldiv_unit_ready;
    logic id_ready_go;
    logic ex_allowin_if_cache_ready;
    logic ex_allowin_if_cache_wait;
    logic ex_allowin;
    logic ex_allowin_timing_copy;
    logic id_allowin;
    logic id_allowin_pipe;
    logic id_allowin_frontend;
    logic id_to_ex_fire;

    integer cases;
    integer random_seed;
    integer random_state;

    backend_flow_ctrl dut (
        .*
    );

    always #5 clk = ~clk;

    // 这三个输入在 cpu_top 中来自同一份译码/相关性事实。测试平台保持
    // 这种真实约束，再独立计算未拆分的 ready/allow 参考方程。
    always_comb begin
        id_decoded_serializing = id_issue_serializing;
        id_dependency_ready =
            (cache_ready ? id_dependency_ready_if_mem_ready
                         : id_dependency_ready_if_mem_wait)
            & ~id_non_load_hazard;
    end

    task automatic fail(input string message);
        $fatal(1, "[FAIL] backend flow case=%0d: %s", cases, message);
    endtask

    task automatic check_outputs;
        logic exp_ex_muldiv_ready;
        logic exp_ex_priv_commit_ready;
        logic exp_ex_priv_ready;
        logic exp_ex_ready_go;
        logic exp_mem_allowin;
        logic exp_timer_irq_block;
        logic exp_serializing_ready;
        logic exp_barrier_ready;
        logic exp_muldiv_unit_ready;
        logic exp_id_ready_go;
        logic exp_ex_allowin;
        logic exp_id_allowin;
        logic exp_id_to_ex_fire;
        logic older_pending;
        logic backend_empty;
        logic mem_can_advance;
        logic mem_mul_owner_releases;
        begin
            older_pending = mem_valid | mem_slot1_valid
                          | wb_valid | wb_slot1_valid;
            backend_empty = ~ex_valid & ~ex_slot1_valid
                          & ~mem_valid & ~mem_slot1_valid
                          & ~wb_valid & ~wb_slot1_valid;
            mem_can_advance = ~mem_valid | cache_ready;
            mem_mul_owner_releases = ~mem_valid | ~mem_is_mul
                                   | cache_ready;

            exp_ex_muldiv_ready = mem_branch_flush | ~ex_valid
                                | ~ex_is_muldiv | ~ex_is_divrem
                                | muldiv_done;
            exp_ex_priv_commit_ready = ~older_pending;
            exp_ex_priv_ready = ~ex_priv_wait_older | ~older_pending;
            exp_ex_ready_go = ~mmio_store_load_hazard
                            & exp_ex_muldiv_ready
                            & exp_ex_priv_ready;
            exp_mem_allowin = ~mem_valid | (cache_ready & wb_allowin);
            exp_timer_irq_block = timer_irq_request | timer_irq_hold;
            exp_serializing_ready = ~id_issue_serializing | backend_empty;
            exp_barrier_ready = ~serializing_inflight;
            exp_muldiv_unit_ready = ~id_issue_is_muldiv | ~muldiv_busy;
            exp_id_ready_go = id_dependency_ready
                            & ~exp_timer_irq_block
                            & exp_serializing_ready
                            & exp_barrier_ready
                            & exp_muldiv_unit_ready
                            & (~id_issue_is_muldiv | ~muldiv_done
                               | muldiv_consume)
                            & (~id_issue_is_muldiv
                               | mem_mul_owner_releases);
            exp_ex_allowin = ~ex_valid
                           | (exp_ex_ready_go & mem_can_advance);
            exp_id_allowin = ~id_valid
                           | (exp_id_ready_go & exp_ex_allowin);
            exp_id_to_ex_fire = id_valid & exp_id_ready_go
                              & exp_ex_allowin & ~id_flush;

            if (ex_muldiv_ready !== exp_ex_muldiv_ready)
                fail("ex_muldiv_ready mismatch");
            if (ex_priv_commit_ready !== exp_ex_priv_commit_ready)
                fail("ex_priv_commit_ready mismatch");
            if (ex_priv_ready !== exp_ex_priv_ready)
                fail("ex_priv_ready mismatch");
            if (ex_ready_go !== exp_ex_ready_go)
                fail("ex_ready_go mismatch");
            if (mem_ready_go !== cache_ready)
                fail("mem_ready_go mismatch");
            if ((mem_allowin_lsu !== exp_mem_allowin)
                || (mem_allowin_control !== exp_mem_allowin)
                || (mem_allowin_pipe !== exp_mem_allowin))
                fail("MEM allowin copies diverged");
            if (timer_irq_block !== exp_timer_irq_block)
                fail("timer IRQ block mismatch");
            if (id_serializing_ready !== exp_serializing_ready)
                fail("serializing drain condition mismatch");
            if (id_barrier_ready !== exp_barrier_ready)
                fail("serialization barrier mismatch");
            if (id_muldiv_unit_ready !== exp_muldiv_unit_ready)
                fail("MulDiv ownership mismatch");
            if (id_ready_go !== exp_id_ready_go)
                fail("id_ready_go mismatch");
            if (ex_allowin !== exp_ex_allowin
                || ex_allowin_timing_copy !== exp_ex_allowin)
                fail("EX allowin copies diverged");
            if ((id_allowin !== exp_id_allowin)
                || (id_allowin_pipe !== exp_id_allowin)
                || (id_allowin_frontend !== exp_id_allowin))
                fail("ID allowin copies diverged");
            if (id_to_ex_fire !== exp_id_to_ex_fire)
                fail("ID-to-EX fire mismatch");
        end
    endtask

    task automatic clear_inputs;
        begin
            cache_ready = 1'b1;
            wb_allowin = 1'b1;
            id_valid = 1'b0;
            id_issue_is_muldiv = 1'b0;
            id_issue_serializing = 1'b0;
            id_dependency_ready_if_mem_ready = 1'b1;
            id_dependency_ready_if_mem_wait = 1'b1;
            id_non_load_hazard = 1'b0;
            id_flush = 1'b0;
            ex_valid = 1'b0;
            ex_slot1_valid = 1'b0;
            ex_is_muldiv = 1'b0;
            ex_is_divrem = 1'b0;
            ex_priv_wait_older = 1'b0;
            mmio_store_load_hazard = 1'b0;
            mem_valid = 1'b0;
            mem_slot1_valid = 1'b0;
            mem_is_mul = 1'b0;
            mem_branch_flush = 1'b0;
            wb_valid = 1'b0;
            wb_slot1_valid = 1'b0;
            muldiv_busy = 1'b0;
            muldiv_done = 1'b0;
            muldiv_consume = 1'b0;
            serializing_inflight = 1'b0;
            timer_irq_request = 1'b0;
            timer_irq_hold = 1'b0;
        end
    endtask

    task automatic check_case(input string name);
        begin
            #1;
            check_outputs();
            cases = cases + 1;
            @(posedge clk);
            #1;
            $display("[INFO] backend flow case %0d: %s", cases, name);
        end
    endtask

    task automatic randomize_real_state;
        begin
            cache_ready = $urandom_range(0, 1);
            // 当前 WB 级无阻塞，cpu_top 中 wb_allowin 恒为 1。这里不制造
            // 后端实际不可能出现的 WB wait 状态。
            wb_allowin = 1'b1;
            id_valid = $urandom_range(0, 1);
            id_issue_is_muldiv = $urandom_range(0, 1);
            id_issue_serializing = $urandom_range(0, 1);
            id_dependency_ready_if_mem_ready = $urandom_range(0, 1);
            id_dependency_ready_if_mem_wait = $urandom_range(0, 1);
            id_non_load_hazard = $urandom_range(0, 1);
            id_flush = $urandom_range(0, 1);
            ex_valid = $urandom_range(0, 1);
            ex_slot1_valid = $urandom_range(0, 1);
            ex_is_muldiv = $urandom_range(0, 1);
            ex_is_divrem = $urandom_range(0, 1);
            ex_priv_wait_older = $urandom_range(0, 1);
            mmio_store_load_hazard = $urandom_range(0, 1);
            mem_valid = $urandom_range(0, 1);
            mem_slot1_valid = $urandom_range(0, 1);
            mem_is_mul = $urandom_range(0, 1);
            mem_branch_flush = $urandom_range(0, 1);
            wb_valid = $urandom_range(0, 1);
            wb_slot1_valid = $urandom_range(0, 1);
            muldiv_busy = $urandom_range(0, 1);
            muldiv_done = $urandom_range(0, 1);
            serializing_inflight = $urandom_range(0, 1);
            timer_irq_request = $urandom_range(0, 1);
            timer_irq_hold = $urandom_range(0, 1);

            // MulDiv consume 来自真实的 EX/MEM 所有者释放条件，而不是独立
            // 随机位；否则会制造 cpu_top 中不可能出现的控制组合。
            muldiv_consume =
                (ex_valid & ex_is_muldiv & ex_is_divrem & muldiv_done
                 & (~mem_valid | cache_ready)
                 & ~mem_branch_flush)
              | (mem_valid & mem_is_mul & cache_ready);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cases = 0;
        random_seed = 32'h2026_0814;
        random_state = random_seed;
        random_state = $urandom(random_state);
        clear_inputs();
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        clear_inputs();
        id_valid = 1'b1;
        check_case("empty backend accepts an ordinary instruction");

        clear_inputs();
        id_valid = 1'b1;
        mem_valid = 1'b1;
        cache_ready = 1'b0;
        check_case("DCache wait blocks occupied MEM and upstream stages");

        clear_inputs();
        id_valid = 1'b1;
        id_issue_serializing = 1'b1;
        wb_slot1_valid = 1'b1;
        check_case("serializing instruction waits for both commit slots");

        clear_inputs();
        id_valid = 1'b1;
        timer_irq_request = 1'b1;
        check_case("pending timer interrupt blocks a new ID issue");

        clear_inputs();
        id_valid = 1'b1;
        id_flush = 1'b1;
        check_case("flush suppresses fire without changing allowin");

        clear_inputs();
        ex_valid = 1'b1;
        ex_is_muldiv = 1'b1;
        ex_is_divrem = 1'b1;
        muldiv_done = 1'b0;
        check_case("unfinished DIV keeps EX occupied");

        clear_inputs();
        ex_valid = 1'b1;
        ex_is_muldiv = 1'b1;
        ex_is_divrem = 1'b1;
        muldiv_done = 1'b0;
        mem_branch_flush = 1'b1;
        check_case("redirect releases an unfinished wrong-path DIV");

        for (int i = 0; i < 10000; i++) begin
            @(negedge clk);
            randomize_real_state();
            #1;
            check_outputs();
            cases = cases + 1;
        end

        $display("[PASS] backend flow contract cases=%0d seed=%0d",
                 cases, random_seed);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "[FAIL] backend flow contract timeout");
    end

endmodule
