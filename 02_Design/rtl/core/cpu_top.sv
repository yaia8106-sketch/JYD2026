// ============================================================
// Module: cpu_top
// Description: RV32I 5-stage pipeline skeleton and module interconnect
// Rule: Keep behavior in stage/helper modules; cpu_top owns wiring and small glue.
// IROM: instantiated outside this module and accessed through ports.
// DRAM: accessed through the DCache instantiated by student_top.
// Frontend Prediction: Stage-1 ABTB + PHT canonical steering
// ============================================================

`ifdef SYNTHESIS
`ifdef ABTB_MEASUREMENT
`define CPU_TOP_ABTB_OBSERVE
`endif
`else
`define CPU_TOP_ABTB_OBSERVE
`endif

module cpu_top
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // IROM interface (IF stage): 64-bit aligned block ROM
    output logic [11:0] irom_addr,
    input  logic [63:0] irom_data,

    // DCache interface (EX to MEM stage)
    output logic        cache_req,       // EX stage: memory request valid
    output logic        cache_wr,        // EX stage: 0=load, 1=store
    output logic [31:0] cache_addr,      // EX stage: memory address
    output logic [ 3:0] cache_wea,       // EX stage: byte write enable
    output logic [31:0] cache_wdata,     // EX stage: raw store data
    output logic [ 3:0] cache_load_mask, // EX stage: load byte lanes
    input  logic [31:0] cache_rdata,     // MEM stage: read data from DCache
    input  logic        cache_ready,     // MEM stage: hit or completed miss
    output logic        cache_flush,     // MEM stage: pipeline flush (abort refill)
    output logic        cache_pipeline_stall, // DCache sync: ~mem_allowin

    // MMIO interface, preserving the existing perip-style split address ports
    output logic [31:0] mmio_addr,       // EX stage: address
    output logic [31:0] mmio_wr_addr,    // MEM stage: write address
    output logic [ 3:0] mmio_wea,        // MEM stage: write enable
    output logic [31:0] mmio_wdata,      // MEM stage: write data
    input  logic [31:0] mmio_rdata,      // MEM stage: read data
    input  logic        timer_irq_pending
);

    // ================================================================
    //  Internal wires
    // ================================================================

    // ---- PC & IF ----
    // pc is driven by the frontend fetch state and doubles as the predictor
    // lookup PC for the current BP0 request.
    wire [31:0] pc;
    wire        if_valid;

    // 250MHz: Pre-computed PC+4 register - eliminates carry chain from irom_addr default path
    // Each branch computes +4 independently from its registered source (no irom_addr feedback)
    logic [31:0] pc_plus4;
    logic [31:0] pc_plus8;
    logic [31:0] pc_plus12;

    // ---- IF/ID ----
    wire        id_valid;
    (* max_fanout = 16 *) wire        id_allowin;
    wire        id_ready_go;
    wire        id_ready_go_raw;
    wire        id_ready_go_raw_if_mem_ready;
    wire        id_ready_go_raw_if_mem_wait;
    // Structured payloads keep per-slot prediction metadata adjacent to the
    // instruction as it crosses the pipeline boundary.
    wire cpu_defs::if_id_payload_t if_id_payload;
    wire cpu_defs::if_id_payload_t id_payload;
    wire [31:0] id_pc = id_payload.pc;
    wire [31:0] id_inst = id_payload.slot0.inst;
    wire [31:0] id_inst1 = id_payload.slot1.inst;
    wire        id_s1_valid;       // registered slot1 issue valid

    // ---- Instruction hold register ----
    wire        irom_held_valid;

    // ---- Decoder outputs ----
    wire [ 3:0] dec_alu_op;
    wire [ 1:0] dec_alu_src1_sel;
    wire        dec_alu_src2_sel;
    wire        dec_reg_write_en;
    wire [ 1:0] dec_wb_sel;
    wire        dec_mem_read_en;
    wire        dec_mem_write_en;
    wire [ 1:0] dec_mem_size;
    wire        dec_mem_unsigned;
    wire        dec_is_branch;
    wire [ 2:0] dec_branch_cond;
    wire        dec_is_jal;
    wire        dec_is_jalr;
    wire        dec_is_csr;
    wire        dec_csr_uses_rs1;
    wire        dec_csr_uses_imm;
    wire        dec_is_ecall;
    wire        dec_is_mret;
    wire        dec_is_muldiv;
    wire        id_is_mul = dec_is_muldiv & ~id_inst[14];
    wire        dec_is_bitmanip;
    wire cpu_defs::bitmanip_op_t dec_bitmanip_op;
    wire [ 2:0] dec_imm_type;

    // ---- Slot 1 decoder outputs ----
    wire [ 3:0] dec1_alu_op;
    wire [ 1:0] dec1_alu_src1_sel;
    wire        dec1_alu_src2_sel;
    wire        dec1_reg_write_en;
    wire [ 1:0] dec1_wb_sel;
    wire        dec1_mem_read_en;
    wire        dec1_mem_write_en;
    wire [ 1:0] dec1_mem_size;
    wire        dec1_mem_unsigned;
    wire        dec1_is_branch;
    wire [ 2:0] dec1_branch_cond;
    wire        dec1_is_jal;
    wire        dec1_is_jalr;
    wire        dec1_is_csr;
    wire        dec1_csr_uses_rs1;
    wire        dec1_csr_uses_imm;
    wire        dec1_is_ecall;
    wire        dec1_is_mret;
    wire        dec1_is_muldiv;
    wire [ 2:0] dec1_imm_type;

    // ---- Immediate ----
    wire [31:0] id_imm;
    wire [31:0] id_s1_imm;

    // ---- Regfile ----
    wire [31:0] rf_rs1_data;
    wire [31:0] rf_rs2_data;
    wire [31:0] rf_s1_rs1_data;
    wire [31:0] rf_s1_rs2_data;

    // ---- Forwarding ----
    wire [31:0] fwd_rs1_data;
    wire [31:0] fwd_rs2_data;
    wire [31:0] mul_fwd_rs1_data;
    wire [31:0] mul_fwd_rs2_data;
    wire [31:0] fwd_s1_rs1_data;
    wire [31:0] fwd_s1_rs2_data;
    wire        fwd_rs1_wb_repair;
    wire        fwd_rs2_wb_repair;
    wire        fwd_s1_rs1_wb_repair;
    wire        fwd_s1_rs2_wb_repair;

    // ---- Timing-parallelized ALU sources from forwarding ----
    wire [31:0] id_alu_src1;
    wire [31:0] id_alu_src2;
    wire [31:0] id_s1_alu_src1;
    wire [31:0] id_s1_alu_src2;

    // ---- ID/EX ----
    wire        ex_valid;
    wire        ex_allowin;
    wire cpu_defs::id_ex_slot0_t id_ex_s0_payload;
    wire cpu_defs::id_ex_slot0_t ex_s0_payload;
    wire [31:0] ex_pc = ex_s0_payload.common.pc;
    wire [31:0] ex_alu_src1 = ex_s0_payload.common.alu_src1;
    wire [31:0] ex_alu_src2 = ex_s0_payload.common.alu_src2;
    wire [31:0] ex_rs1_data = ex_s0_payload.common.rs1_data;
    wire [31:0] ex_rs2_data = ex_s0_payload.common.rs2_data;
    wire        ex_rs1_wb_repair = ex_s0_payload.common.rs1_wb_repair;
    wire        ex_rs2_wb_repair = ex_s0_payload.common.rs2_wb_repair;
    wire [ 4:0] ex_rd = ex_s0_payload.common.rd;
    wire [ 4:0] ex_rs1_addr = ex_s0_payload.common.rs1_addr;
    wire [ 4:0] ex_rs2_addr = ex_s0_payload.common.rs2_addr;
    wire        ex_alu_src1_wb_repair =
        ex_s0_payload.common.alu_src1_wb_repair;
    wire        ex_alu_src2_wb_repair =
        ex_s0_payload.common.alu_src2_wb_repair;
    wire        ex_fast_alu_src1_wb_repair;
    wire        ex_fast_alu_src2_wb_repair;
    wire [ 3:0] ex_alu_op = ex_s0_payload.common.alu_op;
    wire        ex_reg_write_en = ex_s0_payload.common.reg_write_en;
    wire [ 1:0] ex_wb_sel = ex_s0_payload.common.wb_sel;
    wire        ex_mem_read_en = ex_s0_payload.common.mem_read_en;
    wire        ex_mem_write_en = ex_s0_payload.common.mem_write_en;
    wire [ 1:0] ex_mem_size = ex_s0_payload.common.mem_size;
    wire        ex_mem_unsigned = ex_s0_payload.common.mem_unsigned;
    wire        ex_is_branch = ex_s0_payload.common.is_branch;
    wire [ 2:0] ex_branch_cond = ex_s0_payload.common.branch_cond;
    wire        ex_is_jal = ex_s0_payload.common.is_jal;
    wire        ex_is_jalr = ex_s0_payload.common.is_jalr;
    wire        ex_is_csr = ex_s0_payload.is_csr;
    wire        ex_csr_uses_imm = ex_s0_payload.csr_uses_imm;
    wire [ 2:0] ex_csr_cmd = ex_s0_payload.csr_cmd;
    wire [11:0] ex_csr_addr = ex_s0_payload.csr_addr;
    wire        ex_is_ecall = ex_s0_payload.is_ecall;
    wire        ex_is_mret = ex_s0_payload.is_mret;
    wire        ex_is_muldiv = ex_s0_payload.is_muldiv;
    wire [ 2:0] ex_muldiv_op = ex_s0_payload.muldiv_op;
    wire        ex_is_bitmanip = ex_s0_payload.is_bitmanip;
    wire cpu_defs::bitmanip_op_t ex_bitmanip_op =
        ex_s0_payload.bitmanip_op;

    // ---- Slot 1 ID/EX ----
    wire        ex_s1_valid;
    wire cpu_defs::id_ex_slot1_t id_ex_s1_payload;
    wire cpu_defs::id_ex_slot1_t ex_s1_payload;
    wire [31:0] ex_s1_pc = ex_s1_payload.common.pc;
    wire [31:0] ex_s1_inst = ex_s1_payload.inst;
    wire [ 4:0] ex_s1_rd = ex_s1_payload.common.rd;
    wire [ 4:0] ex_s1_rs1_addr = ex_s1_payload.common.rs1_addr;
    wire [ 4:0] ex_s1_rs2_addr = ex_s1_payload.common.rs2_addr;
    wire [ 3:0] ex_s1_alu_op = ex_s1_payload.common.alu_op;
    wire        ex_s1_reg_write_en = ex_s1_payload.common.reg_write_en;
    wire [ 1:0] ex_s1_wb_sel = ex_s1_payload.common.wb_sel;
    wire        ex_s1_mem_read_en = ex_s1_payload.common.mem_read_en;
    wire        ex_s1_mem_write_en = ex_s1_payload.common.mem_write_en;
    wire [ 1:0] ex_s1_mem_size = ex_s1_payload.common.mem_size;
    wire        ex_s1_mem_unsigned = ex_s1_payload.common.mem_unsigned;
    wire        ex_s1_is_branch = ex_s1_payload.common.is_branch;
    wire [ 2:0] ex_s1_branch_cond = ex_s1_payload.common.branch_cond;
    wire        ex_s1_is_jal = ex_s1_payload.common.is_jal;
    wire        ex_s1_is_jalr = ex_s1_payload.common.is_jalr;
    wire [31:0] ex_s1_alu_src1 = ex_s1_payload.common.alu_src1;
    wire [31:0] ex_s1_alu_src2 = ex_s1_payload.common.alu_src2;
    wire [31:0] ex_s1_rs1_data = ex_s1_payload.common.rs1_data;
    wire [31:0] ex_s1_rs2_data = ex_s1_payload.common.rs2_data;
    wire        ex_s1_rs1_wb_repair = ex_s1_payload.common.rs1_wb_repair;
    wire        ex_s1_rs2_wb_repair = ex_s1_payload.common.rs2_wb_repair;
    wire        ex_s1_alu_src1_wb_repair =
        ex_s1_payload.common.alu_src1_wb_repair;
    wire        ex_s1_alu_src2_wb_repair =
        ex_s1_payload.common.alu_src2_wb_repair;
    wire        ex_s1_fast_alu_src1_wb_repair;
    wire        ex_s1_fast_alu_src2_wb_repair;

    // ---- ALU ----
    wire [31:0] alu_result;
    wire [31:0] alu_sum;               // Raw ALU adder result before output MUX
    wire [31:0] alu_addr;              // Independent address adder, not alu_op-dependent
    wire [31:0] alu_s1_result;
    wire [31:0] alu_s1_sum;
    wire [31:0] alu_s1_addr;
    wire [31:0] ex_alu_src1_repair;
    wire [31:0] ex_alu_src2_repair;
    wire [31:0] ex_s1_alu_src1_repair;
    wire [31:0] ex_s1_alu_src2_repair;
    wire [31:0] ex_rs1_data_repair;
    wire [31:0] ex_rs2_data_repair;
    wire [31:0] ex_s1_rs1_data_repair;
    wire [31:0] ex_s1_rs2_data_repair;
    wire [31:0] ex_fast_alu_src1;
    wire [31:0] ex_fast_alu_src2;
    wire [31:0] ex_s1_fast_alu_src1;
    wire [31:0] ex_s1_fast_alu_src2;
    wire [ 1:0] ex_store_addr_low;
    wire [ 1:0] ex_s1_store_addr_low;

    // ---- Branch ----
    wire        branch_flush;          // EX stage combinational (for predictor update)
    wire [31:0] branch_target;         // EX stage combinational
    wire        actual_taken;          // for predictor update
    wire [31:0] actual_target;         // for predictor update
    wire [31:0] ex_control_target;     // EX-computed target for Slot 0 CFI
    wire        ex_branch_registered_flush;
    wire        ex_s1_branch_redirect; // Slot1 branch delayed frontend redirect
    wire [31:0] ex_s1_branch_target;
    wire        ex_s1_actual_taken;
    wire        ex_redirect_fire;
    wire        ex_system_inst;
    wire        ex_system_redirect;
    wire [31:0] ex_system_target;
    wire        timer_irq_request;
    wire        timer_irq_redirect;
    wire [31:0] timer_irq_target;
    wire        timer_irq_hold;
    wire        timer_irq_pipe_empty;
    wire        timer_irq_take;
    wire        ex_fast_redirect;
    wire [31:0] ex_fast_redirect_target;
    wire        ex_registered_branch_flush;
    wire [31:0] ex_registered_branch_target;

    // Ordinary Slot 0 branch misses are registered through EX/MEM. System and
    // timer redirects use the fast frontend redirect path instead.
    assign ex_branch_registered_flush = branch_flush & ex_redirect_fire & ~ex_system_inst;

    // ---- Registered branch flush (MEM stage, for 250MHz timing) ----
    wire cpu_defs::redirect_t ex_mem_redirect;
    wire cpu_defs::redirect_t mem_redirect;
    wire        mem_branch_flush = mem_redirect.valid;
    wire [31:0] mem_branch_target = mem_redirect.target;
    wire        mem_branch_replay;
    wire        frontend_branch_flush;
    wire [31:0] frontend_branch_target;

    // ---- Memory interface ----
    wire [ 3:0] dram_wea;
    wire [ 3:0] dram_wea_s1;
    wire [31:0] ex_s1_store_data_raw;
    wire [31:0] mem_load_data;         // MEM stage: raw cacheable/MMIO load data
    wire [31:0] mem_load_data_ext;
    wire        mem_load_ready;        // ready S0_MEM load can repair S0 ALU in EX
    wire        is_cacheable;          // EX stage: addr in DRAM range
    wire        is_cacheable_s1;       // EX stage: Slot1 addr in DRAM range

    // ---- EX pre-computed ----
    wire [31:0] ex_pc_plus_4;
    wire [31:0] ex_s1_pc_plus_4;

    // ---- EX/MEM ----
    wire        mem_valid;
    wire        mem_allowin;
    wire cpu_defs::ex_mem_slot0_t ex_mem_s0_payload;
    wire cpu_defs::ex_mem_slot0_t mem_s0_payload;
    wire [31:0] mem_alu_result = mem_s0_payload.alu_result;
    wire [31:0] mem_pc = mem_s0_payload.pc;
    wire [31:0] mem_pc_plus_4 = mem_s0_payload.pc_plus_4;
    wire [ 4:0] mem_rd = mem_s0_payload.rd;
    wire        mem_reg_write_en = mem_s0_payload.reg_write_en;
    wire [ 1:0] mem_wb_sel = mem_s0_payload.wb_sel;
    wire        mem_is_mul = mem_s0_payload.is_mul;
    wire        mem_mem_read_en = mem_s0_payload.mem_read_en;
    wire [ 1:0] mem_mem_size = mem_s0_payload.mem_size;
    wire        mem_mem_unsigned = mem_s0_payload.mem_unsigned;
    wire [ 3:0] mem_store_wea = mem_s0_payload.store_wea;
    wire [31:0] mem_store_data = mem_s0_payload.store_data;
    wire        is_cacheable_mem = mem_s0_payload.is_cacheable;

    // ---- Slot 1 MEM ----
    wire        mem_s1_valid;
    wire cpu_defs::ex_mem_slot1_t ex_mem_s1_payload;
    wire cpu_defs::ex_mem_slot1_t mem_s1_payload;
    wire [31:0] mem_s1_pc = mem_s1_payload.pc;
    wire [31:0] mem_s1_inst = mem_s1_payload.inst;
    wire [31:0] mem_s1_alu_result = mem_s1_payload.alu_result;
    wire [31:0] mem_s1_pc_plus_4 = mem_s1_payload.pc_plus_4;
    wire [ 4:0] mem_s1_rd = mem_s1_payload.rd;
    wire        mem_s1_reg_write_en = mem_s1_payload.reg_write_en;
    wire [ 1:0] mem_s1_wb_sel = mem_s1_payload.wb_sel;
    wire        mem_s1_mem_read_en = mem_s1_payload.mem_read_en;
    wire        mem_s1_mem_write_en = mem_s1_payload.mem_write_en;
    wire [ 1:0] mem_s1_mem_size = mem_s1_payload.mem_size;
    wire        mem_s1_mem_unsigned = mem_s1_payload.mem_unsigned;
    wire [ 3:0] mem_s1_store_wea = mem_s1_payload.store_wea;
    wire [31:0] mem_s1_store_data = mem_s1_payload.store_data;
    wire        mem_s1_is_cacheable = mem_s1_payload.is_cacheable;

    // The issue policy allows only one LSU operation per pair.
    wire        mem_s1_load_active = mem_s1_valid & mem_s1_mem_read_en;
    wire        mem_load_valid = (mem_valid & mem_mem_read_en)
                               | mem_s1_load_active;
    wire        mem_selected_load_en = mem_mem_read_en | mem_s1_load_active;
    wire [ 1:0] mem_selected_load_addr_low = mem_s1_load_active
                                                ? mem_s1_alu_result[1:0]
                                                : mem_alu_result[1:0];
    wire [ 1:0] mem_selected_load_size = mem_s1_load_active
                                            ? mem_s1_mem_size
                                            : mem_mem_size;
    wire        mem_selected_load_unsigned = mem_s1_load_active
                                                ? mem_s1_mem_unsigned
                                                : mem_mem_unsigned;

    // ---- MEM/WB ----
    wire        wb_valid;
    wire        wb_allowin;
    wire cpu_defs::mem_wb_slot0_t mem_wb_s0_payload;
    wire cpu_defs::mem_wb_slot0_t wb_s0_payload;
    wire [31:0] wb_alu_result = wb_s0_payload.alu_result;
    wire [31:0] wb_pc_plus_4 = wb_s0_payload.pc_plus_4;
    (* max_fanout = 8 *) wire [ 4:0] wb_rd = wb_s0_payload.rd;
    wire        wb_reg_write_en = wb_s0_payload.reg_write_en;
    wire [ 1:0] wb_wb_sel = wb_s0_payload.wb_sel;
    wire        wb_is_load = wb_s0_payload.is_load;
    wire [31:0] wb_load_data = wb_s0_payload.load_data;
    wire [31:0] wb_load_data_ex;

    assign ex_fast_alu_src1 = ex_fast_alu_src1_wb_repair
                            ? wb_load_data_ex : ex_alu_src1;
    assign ex_fast_alu_src2 = ex_fast_alu_src2_wb_repair
                            ? wb_load_data_ex : ex_alu_src2;
    assign ex_s1_fast_alu_src1 = ex_s1_fast_alu_src1_wb_repair
                               ? wb_load_data_ex : ex_s1_alu_src1;
    assign ex_s1_fast_alu_src2 = ex_s1_fast_alu_src2_wb_repair
                               ? wb_load_data_ex : ex_s1_alu_src2;

    // ---- Slot 1 shadow WB ----
    wire        wb_s1_valid;
    wire cpu_defs::mem_wb_slot1_t mem_wb_s1_payload;
    wire cpu_defs::mem_wb_slot1_t wb_s1_payload;
    wire [31:0] wb_s1_pc = wb_s1_payload.pc;
    wire [31:0] wb_s1_inst = wb_s1_payload.inst;
    wire [31:0] wb_s1_alu_result = wb_s1_payload.alu_result;
    wire [31:0] wb_s1_pc_plus_4 = wb_s1_payload.pc_plus_4;
    (* max_fanout = 8 *) wire [ 4:0] wb_s1_rd = wb_s1_payload.rd;
    wire        wb_s1_reg_write_en = wb_s1_payload.reg_write_en;
    wire [ 1:0] wb_s1_wb_sel = wb_s1_payload.wb_sel;
    wire        wb_s1_is_load = wb_s1_payload.is_load;

    // ---- WB ----
    wire [31:0] wb_write_data;
    wire [31:0] wb_s1_write_data;

    // ---- Minimal M-mode CSR / Trap ----
    wire [31:0] ex_csr_rdata;
    wire [31:0] ex_forward_result;
    wire [31:0] ex_pipe_alu_result;
    wire        ex_fast_alu_forward = ~ex_is_csr & ~ex_is_muldiv
                                    & (ex_wb_sel != 2'b10);

    // ---- RV32M multi-cycle unit ----
    wire        muldiv_busy;
    wire        muldiv_done;
    wire [31:0] muldiv_result;
    wire        ex_muldiv_req = ex_valid & ex_is_muldiv & ~mem_branch_flush;
    // DIV/REM retain the original EX completion handshake. Multipliers leave
    // EX one cycle earlier, so their owner is released only when the aligned
    // MEM token advances. This keeps the registered product stable across MEM
    // backpressure.
    wire        ex_div_consume = ex_valid & ex_is_muldiv & ex_muldiv_op[2]
                               & muldiv_done & mem_allowin
                               & ~mem_branch_flush;
    wire        mem_mul_consume = mem_valid & mem_is_mul
                                & cache_ready & wb_allowin;
    wire        muldiv_consume = ex_div_consume | mem_mul_consume;
    wire        muldiv_flush = frontend_branch_flush | mem_branch_flush;

    // The MEM/WB payload must carry the architectural multiplier result because
    // the early EX/MEM ALU field was sampled before that product was ready.
    // Forwarding receives the raw candidates separately and folds MUL/PC+4/ALU
    // selection into its existing one-level MEM value selector.
    wire [31:0] mem_wb_alu_result =
        ({32{mem_is_mul}}  & muldiv_result)
      | ({32{~mem_is_mul}} & mem_alu_result);

    // ---- RV32 bit-manipulation multi-cycle unit ----
    wire        bitmanip_busy;
    wire        bitmanip_done;
    wire [31:0] bitmanip_result;
    wire        ex_bitmanip_req = ex_valid & ex_is_bitmanip
                                & ~mem_branch_flush;
    wire        bitmanip_consume = ex_valid & ex_is_bitmanip
                                  & bitmanip_done & mem_allowin
                                  & ~mem_branch_flush;
    wire        bitmanip_flush = frontend_branch_flush
                               | mem_branch_flush;

    wire        ex_forward_reg_write = ex_reg_write_en
                                             & (~ex_is_muldiv | muldiv_done)
                                             & (~ex_is_bitmanip | bitmanip_done);
    // ---- Dual-issue performance counter ----
    wire [31:0] dual_issue_count;

    // ---- Handshake ----
    wire if_ready_go_w;             // driven by frontend_ftq
    wire mmio_st_ld_hazard;
    wire ex_muldiv_ready = mem_branch_flush | ~ex_muldiv_req
                         | ~ex_muldiv_op[2] | muldiv_done;
    wire ex_bitmanip_ready = mem_branch_flush | ~ex_bitmanip_req
                           | bitmanip_done;
    wire ex_ready_go_w  = ~mmio_st_ld_hazard
                        & ex_muldiv_ready & ex_bitmanip_ready;
    wire mem_ready_go_w = cache_ready; // DCache controls MEM stage flow
    wire mem_can_advance = ~mem_valid | mem_ready_go_w;
    // A completed multiplier may accept a new M owner on the same edge that
    // its MEM token advances. If MEM is held, block only a new M instruction;
    // independent ID traffic remains governed by normal pipeline capacity.
    wire mem_mul_owner_releases = ~mem_valid | ~mem_is_mul
                                | mem_ready_go_w;
    wire id_muldiv_unit_ready = ~dec_is_muldiv | ~muldiv_busy;

    // Evaluate the complete pipeline handshake for both values of the late
    // DCache-ready bit. cache_ready then selects each one-bit result only once;
    // it no longer traverses load-hazard, M-owner and downstream-allow logic.
    wire id_base_ready_if_cache_ready = id_ready_go_raw_if_mem_ready
                                      & ~timer_irq_hold;
    wire id_base_ready_if_cache_wait = id_ready_go_raw_if_mem_wait
                                     & ~timer_irq_hold;
    wire id_muldiv_owner_ready_if_cache_wait = ~dec_is_muldiv
                                             | ~mem_valid | ~mem_is_mul;

    (* keep = "true" *) wire id_ready_go_if_cache_ready =
        id_base_ready_if_cache_ready & id_muldiv_unit_ready;
    (* keep = "true" *) wire id_ready_go_if_cache_wait =
        id_base_ready_if_cache_wait & id_muldiv_unit_ready
                                    & id_muldiv_owner_ready_if_cache_wait;

    // wb_allowin is permanently true. Therefore MEM is always able to advance
    // when cache_ready=1, while cache_ready=0 permits EX to advance only into
    // an empty MEM stage.
    (* keep = "true" *) wire ex_allowin_if_cache_ready =
        ~ex_valid | ex_ready_go_w;
    (* keep = "true" *) wire ex_allowin_if_cache_wait =
        ~ex_valid | (ex_ready_go_w & ~mem_valid);

    (* keep = "true" *) wire id_allowin_if_cache_ready =
        ~id_valid | (id_ready_go_if_cache_ready
                     & ex_allowin_if_cache_ready);
    (* keep = "true" *) wire id_allowin_if_cache_wait =
        ~id_valid | (id_ready_go_if_cache_wait
                     & ex_allowin_if_cache_wait);

    assign id_ready_go = cache_ready ? id_ready_go_if_cache_ready
                                     : id_ready_go_if_cache_wait;
    assign ex_allowin = cache_ready ? ex_allowin_if_cache_ready
                                    : ex_allowin_if_cache_wait;
    assign id_allowin = cache_ready ? id_allowin_if_cache_ready
                                    : id_allowin_if_cache_wait;

`ifndef SYNTHESIS
    // Executable references retain the original serial equations.
    wire id_ready_go_reference = id_ready_go_raw & ~timer_irq_hold
                               & id_muldiv_unit_ready
                               & (~dec_is_muldiv
                                  | mem_mul_owner_releases);
    wire ex_allowin_reference = ~ex_valid
                              | (ex_ready_go_w & mem_can_advance);
    wire id_allowin_reference = ~id_valid
                              | (id_ready_go_reference
                                 & ex_allowin_reference);
`endif

    // ---- Flush / redirect ----
    wire id_flush = frontend_branch_flush;
    wire ex_flush = frontend_branch_flush;
    // This is the exact ID/EX acceptance edge. A Slot 0 MUL establishes its
    // narrow MulDiv owner here while its forwarded rs payload is duplicated
    // into free-running local DSP input registers.
    wire id_to_ex_fire_if_cache_ready = id_valid
                                      & id_ready_go_if_cache_ready
                                      & ex_allowin_if_cache_ready
                                      & ~id_flush;
    wire id_to_ex_fire_if_cache_wait = id_valid
                                     & id_ready_go_if_cache_wait
                                     & ex_allowin_if_cache_wait
                                     & ~id_flush;
    wire id_to_ex_fire = cache_ready ? id_to_ex_fire_if_cache_ready
                                     : id_to_ex_fire_if_cache_wait;
`ifndef SYNTHESIS
    wire id_to_ex_fire_reference = id_valid & id_ready_go_reference
                                 & ex_allowin_reference & ~id_flush;
`endif
    wire id_mul_prestart = id_to_ex_fire & id_is_mul;

    // ---- Register addresses from instruction (ID stage, from IF/ID reg) ----
    wire [4:0] id_rs1_addr;
    wire [4:0] id_rs2_addr;
    wire [4:0] id_rd_addr;
    wire [4:0] id_s1_rs1_addr;
    wire [4:0] id_s1_rs2_addr;
    wire [4:0] id_s1_rd_addr;
    wire [31:0] id_pc_plus_4;
    wire [31:0] id_s1_pc;
    wire [ 2:0] id_csr_cmd;
    wire [11:0] id_csr_addr;
    wire        id_alu_src1_is_rs1;
    wire        id_alu_src2_is_rs2;
    wire        id_s1_alu_src1_is_rs1;
    wire        id_s1_alu_src2_is_rs2;
    wire        id_rs1_used;
    wire        id_rs2_used;
    wire        id_s1_rs1_used;
    wire        id_s1_rs2_used;
    wire        id_s0_alu_only;
    wire        id_s1_repair_ok;
    // Qualify the same-pair bypass in ID and carry one registered bit into EX.
    // This keeps the rd/rs comparisons off the ALU-to-store-data timing path.
    wire id_s0_alu_store_data_bypass = id_s1_valid
                                     & id_s0_alu_only
                                     & dec1_mem_write_en
                                     & dec_reg_write_en
                                     & (id_rd_addr != 5'd0)
                                     & (id_s1_rs2_addr == id_rd_addr)
                                     & (id_s1_rs1_addr != id_rd_addr);
    // The LSU bridge arbitrates Slot 0/Slot 1 memory requests, routes them to
    // cache or MMIO, and returns the raw load word to the MEM load formatter.
    memory_access_unit u_memory_access_unit (
        .ex_valid            (ex_valid),
        .ex_mem_read_en      (ex_mem_read_en),
        .ex_mem_write_en     (ex_mem_write_en),
        .ex_alu_addr         (alu_addr),
        .ex_mem_size         (ex_mem_size),
        .ex_store_wea        (dram_wea),
        .ex_store_data       (ex_rs2_data_repair),
        .ex_s1_valid         (ex_s1_valid),
        .ex_s1_mem_read_en   (ex_s1_mem_read_en),
        .ex_s1_mem_write_en  (ex_s1_mem_write_en),
        .ex_s1_alu_addr      (alu_s1_addr),
        .ex_s1_mem_size      (ex_s1_mem_size),
        .ex_s1_store_wea     (dram_wea_s1),
        .ex_s1_store_data    (ex_s1_store_data_raw),
        .mem_valid           (mem_valid),
        .mem_alu_result      (mem_alu_result),
        .mem_mem_read_en     (mem_mem_read_en),
        .mem_store_wea       (mem_store_wea),
        .mem_store_data      (mem_store_data),
        .mem_is_cacheable    (is_cacheable_mem),
        .mem_s1_valid        (mem_s1_valid),
        .mem_s1_alu_result   (mem_s1_alu_result),
        .mem_s1_mem_read_en  (mem_s1_mem_read_en),
        .mem_s1_mem_write_en (mem_s1_mem_write_en),
        .mem_s1_store_wea    (mem_s1_store_wea),
        .mem_s1_store_data   (mem_s1_store_data),
        .mem_s1_is_cacheable (mem_s1_is_cacheable),
        .mem_ready_go        (mem_ready_go_w),
        .mem_allowin         (mem_allowin),
        .mem_branch_flush    (mem_branch_flush),
        .cache_rdata         (cache_rdata),
        .mmio_rdata          (mmio_rdata),
        .dual_issue_count    (dual_issue_count),
        .is_cacheable        (is_cacheable),
        .is_cacheable_s1     (is_cacheable_s1),
        .mmio_st_ld_hazard   (mmio_st_ld_hazard),
        .cache_req           (cache_req),
        .cache_wr            (cache_wr),
        .cache_addr          (cache_addr),
        .cache_wea           (cache_wea),
        .cache_wdata         (cache_wdata),
        .cache_load_mask     (cache_load_mask),
        .cache_flush         (cache_flush),
        .cache_pipeline_stall(cache_pipeline_stall),
        .mmio_addr           (mmio_addr),
        .mmio_wr_addr        (mmio_wr_addr),
        .mmio_wea            (mmio_wea),
        .mmio_wdata          (mmio_wdata),
        .mem_load_data       (mem_load_data),
        .mem_load_ready      (mem_load_ready)
    );

    // Redirect priority is centralized here: fast EX system/timer redirects
    // can override replay of the older registered MEM redirect.
    redirect_ctrl u_redirect_ctrl (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .ex_ready_go                 (ex_ready_go_w),
        .mem_allowin                 (mem_allowin),
        .mem_branch_flush            (mem_branch_flush),
        .mem_branch_target           (mem_branch_target),
        .ex_system_redirect          (ex_system_redirect),
        .ex_system_target            (ex_system_target),
        .timer_irq_redirect          (timer_irq_redirect),
        .timer_irq_target            (timer_irq_target),
        .ex_redirect_fire            (ex_redirect_fire),
        .ex_fast_redirect            (ex_fast_redirect),
        .ex_fast_redirect_target     (ex_fast_redirect_target),
        .mem_branch_replay           (mem_branch_replay),
        .frontend_branch_flush       (frontend_branch_flush),
        .frontend_branch_target      (frontend_branch_target)
    );

    // Timer interrupts wait until the pipeline is empty before redirecting to
    // mtvec, which keeps trap entry precise.
    timer_irq_ctrl u_timer_irq_ctrl (
        .clk               (clk),
        .rst_n             (rst_n),
        .timer_irq_request (timer_irq_request),
        .id_valid          (id_valid),
        .frontend_flush    (frontend_branch_flush),
        .ex_valid          (ex_valid),
        .mem_valid         (mem_valid),
        .wb_valid          (wb_valid),
        .ex_s1_valid       (ex_s1_valid),
        .mem_s1_valid      (mem_s1_valid),
        .wb_s1_valid       (wb_s1_valid),
        .timer_irq_hold    (timer_irq_hold),
        .pipeline_empty    (timer_irq_pipe_empty),
        .timer_irq_take    (timer_irq_take)
    );

    // ================================================================
    //  Stage-1 prediction wires
    // ================================================================

    // ID stage prediction (from IF/ID reg)
    wire        id_pred_taken = id_payload.slot0.prediction.taken;
    wire [31:0] id_pred_target = id_payload.slot0.prediction.target;
    wire        id_s1_pred_taken = id_payload.slot1.prediction.taken;
    wire [31:0] id_s1_pred_target = id_payload.slot1.prediction.target;

    // EX stage prediction (from ID/EX reg)
    wire        ex_pred_taken =
        ex_s0_payload.common.prediction.prediction.taken;
    wire [31:0] ex_pred_target =
        ex_s0_payload.common.prediction.prediction.target;
    wire        ex_s1_pred_taken =
        ex_s1_payload.common.prediction.prediction.taken;
    wire [31:0] ex_s1_pred_target =
        ex_s1_payload.common.prediction.prediction.target;

    // ABTB lookup/training metadata. ABTB/PHT owns Stage-1 J/CALL and branch
    // steering by default. Legacy predictor metadata has been retired.
    wire        abtb_lookup_accept;
    wire        abtb_bank0_hit;
    wire        abtb_bank0_lookup_hit;
    wire        abtb_bank0_way;
    wire [ 1:0] abtb_bank0_cfi_type;
    wire [31:0] abtb_bank0_abtb_pred_target;
    wire        abtb_bank0_pred_taken;
    wire [31:0] abtb_bank0_final_pred_target;
    wire        abtb_bank1_hit;
    wire        abtb_bank1_lookup_hit;
    wire        abtb_bank1_way;
    wire [ 1:0] abtb_bank1_cfi_type;
    wire [31:0] abtb_bank1_abtb_pred_target;
    wire        abtb_bank1_pred_taken;
    wire [31:0] abtb_bank1_final_pred_target;
    wire        abtb_shadow_pred_taken;
    wire        abtb_shadow_pred_bank;
    wire [ 1:0] abtb_shadow_pred_cfi_type;
    wire [31:0] abtb_shadow_pred_target;
    wire [31:0] abtb_shadow_pred_next_pc;

    // Compatibility probes mirror IF/ID, ID, and EX prediction metadata for
    // existing monitors. They do not participate in control.
    wire        if_abtb_hit_out = if_id_payload.slot0.prediction.abtb_hit;
    wire        if_abtb_way_out = if_id_payload.slot0.prediction.abtb_way;
    wire [ 1:0] if_abtb_cfi_type_out = if_id_payload.slot0.prediction.abtb_cfi_type;
    wire [31:0] if_abtb_target_out = if_id_payload.slot0.prediction.abtb_target;
    wire        if_abtb_pred_taken_out = if_id_payload.slot0.prediction.abtb_pred_taken;
    wire [31:0] if_abtb_pred_target_out = if_id_payload.slot0.prediction.abtb_pred_target;
    wire        if_pred_source_abtb_out = if_id_payload.slot0.prediction.source_abtb;
    wire        if_stage1_branch_owned_out =
        if_id_payload.slot0.prediction.stage1_branch_owned;
    wire        if_s1_abtb_hit_out = if_id_payload.slot1.prediction.abtb_hit;
    wire        if_s1_abtb_way_out = if_id_payload.slot1.prediction.abtb_way;
    wire [ 1:0] if_s1_abtb_cfi_type_out = if_id_payload.slot1.prediction.abtb_cfi_type;
    wire [31:0] if_s1_abtb_target_out = if_id_payload.slot1.prediction.abtb_target;
    wire        if_s1_abtb_pred_taken_out = if_id_payload.slot1.prediction.abtb_pred_taken;
    wire [31:0] if_s1_abtb_pred_target_out = if_id_payload.slot1.prediction.abtb_pred_target;
    wire        if_s1_pred_source_abtb_out = if_id_payload.slot1.prediction.source_abtb;
    wire        if_s1_stage1_branch_owned_out =
        if_id_payload.slot1.prediction.stage1_branch_owned;

    wire        id_abtb_hit = id_payload.slot0.prediction.abtb_hit;
    wire        id_abtb_way = id_payload.slot0.prediction.abtb_way;
    wire [ 1:0] id_abtb_cfi_type = id_payload.slot0.prediction.abtb_cfi_type;
    wire [31:0] id_abtb_target = id_payload.slot0.prediction.abtb_target;
    wire        id_abtb_pred_taken = id_payload.slot0.prediction.abtb_pred_taken;
    wire [31:0] id_abtb_pred_target = id_payload.slot0.prediction.abtb_pred_target;
    wire        id_pred_source_abtb = id_payload.slot0.prediction.source_abtb;
    wire        id_stage1_branch_owned = id_payload.slot0.prediction.stage1_branch_owned;
    wire        id_abtb_update_qualified_w;
    wire [ 1:0] id_abtb_update_cfi_type_w;
    wire        id_s1_abtb_hit = id_payload.slot1.prediction.abtb_hit;
    wire        id_s1_abtb_way = id_payload.slot1.prediction.abtb_way;
    wire [ 1:0] id_s1_abtb_cfi_type = id_payload.slot1.prediction.abtb_cfi_type;
    wire [31:0] id_s1_abtb_target = id_payload.slot1.prediction.abtb_target;
    wire        id_s1_abtb_pred_taken = id_payload.slot1.prediction.abtb_pred_taken;
    wire [31:0] id_s1_abtb_pred_target = id_payload.slot1.prediction.abtb_pred_target;
    wire        id_s1_pred_source_abtb = id_payload.slot1.prediction.source_abtb;
    wire        id_s1_stage1_branch_owned = id_payload.slot1.prediction.stage1_branch_owned;
    wire        id_s1_abtb_update_qualified_w;
    wire [ 1:0] id_s1_abtb_update_cfi_type_w;

    wire        ex_abtb_hit =
        ex_s0_payload.common.prediction.prediction.abtb_hit;
    wire        ex_abtb_way =
        ex_s0_payload.common.prediction.prediction.abtb_way;
    wire [ 1:0] ex_abtb_cfi_type =
        ex_s0_payload.common.prediction.prediction.abtb_cfi_type;
    wire [31:0] ex_abtb_target =
        ex_s0_payload.common.prediction.prediction.abtb_target;
    wire        ex_abtb_pred_taken =
        ex_s0_payload.common.prediction.prediction.abtb_pred_taken;
    wire [31:0] ex_abtb_pred_target =
        ex_s0_payload.common.prediction.prediction.abtb_pred_target;
    wire        ex_pred_source_abtb =
        ex_s0_payload.common.prediction.prediction.source_abtb;
    wire        ex_stage1_branch_owned =
        ex_s0_payload.common.prediction.prediction.stage1_branch_owned;
    wire        ex_abtb_update_qualified =
        ex_s0_payload.common.prediction.update_qualified;
    wire [ 1:0] ex_abtb_update_cfi_type =
        ex_s0_payload.common.prediction.update_cfi_type;
    wire        ex_s1_abtb_hit =
        ex_s1_payload.common.prediction.prediction.abtb_hit;
    wire        ex_s1_abtb_way =
        ex_s1_payload.common.prediction.prediction.abtb_way;
    wire [ 1:0] ex_s1_abtb_cfi_type =
        ex_s1_payload.common.prediction.prediction.abtb_cfi_type;
    wire [31:0] ex_s1_abtb_target =
        ex_s1_payload.common.prediction.prediction.abtb_target;
    wire        ex_s1_abtb_pred_taken =
        ex_s1_payload.common.prediction.prediction.abtb_pred_taken;
    wire [31:0] ex_s1_abtb_pred_target =
        ex_s1_payload.common.prediction.prediction.abtb_pred_target;
    wire        ex_s1_pred_source_abtb =
        ex_s1_payload.common.prediction.prediction.source_abtb;
    wire        ex_s1_stage1_branch_owned =
        ex_s1_payload.common.prediction.prediction.stage1_branch_owned;
    wire        ex_s1_abtb_update_qualified =
        ex_s1_payload.common.prediction.update_qualified;
    wire [ 1:0] ex_s1_abtb_update_cfi_type =
        ex_s1_payload.common.prediction.update_cfi_type;
    wire [ 7:0] stage1_bank0_pht_index;
    wire [ 1:0] stage1_bank0_pht_counter;
    wire        stage1_bank0_pht_taken;
    wire [ 7:0] stage1_bank1_pht_index;
    wire [ 1:0] stage1_bank1_pht_counter;
    wire        stage1_bank1_pht_taken;
    wire [ 7:0] stage1_lookup_ghr;
    wire [ 7:0] stage1_committed_ghr;
    wire [ 7:0] if_stage1_pht_index =
        if_id_payload.slot0.prediction.stage1_pht_index;
    wire [ 1:0] if_stage1_pht_counter =
        if_id_payload.slot0.prediction.stage1_pht_counter;
    wire [ 7:0] if_s1_stage1_pht_index =
        if_id_payload.slot1.prediction.stage1_pht_index;
    wire [ 1:0] if_s1_stage1_pht_counter =
        if_id_payload.slot1.prediction.stage1_pht_counter;
    wire [ 7:0] id_stage1_pht_index = id_payload.slot0.prediction.stage1_pht_index;
    wire [ 1:0] id_stage1_pht_counter = id_payload.slot0.prediction.stage1_pht_counter;
    wire [ 7:0] id_s1_stage1_pht_index = id_payload.slot1.prediction.stage1_pht_index;
    wire [ 1:0] id_s1_stage1_pht_counter = id_payload.slot1.prediction.stage1_pht_counter;
    wire [ 7:0] ex_stage1_pht_index =
        ex_s0_payload.common.prediction.prediction.stage1_pht_index;
    wire [ 1:0] ex_stage1_pht_counter =
        ex_s0_payload.common.prediction.prediction.stage1_pht_counter;
    wire [ 7:0] ex_s1_stage1_pht_index =
        ex_s1_payload.common.prediction.prediction.stage1_pht_index;
    wire [ 1:0] ex_s1_stage1_pht_counter =
        ex_s1_payload.common.prediction.prediction.stage1_pht_counter;
    wire cpu_defs::predictor_resolve_t predictor_resolve_s0;
    wire cpu_defs::predictor_resolve_t predictor_resolve_s1;
    wire cpu_defs::predictor_train_t predictor_train;
    wire cpu_defs::abtb_update_t predictor_abtb_update;
    wire cpu_defs::pht_update_t predictor_pht_update;
    wire cpu_defs::abtb_update_t predictor_abtb_write;
    wire cpu_defs::pht_update_t predictor_pht_write;

    // PHT updates use the prediction-time index and counter carried to EX.
    wire        stage1_direction_update_valid =
        predictor_pht_update.valid;
    wire [ 7:0] stage1_direction_update_index =
        predictor_pht_update.index;
    wire [ 1:0] stage1_direction_update_counter =
        predictor_pht_update.counter;
    wire        stage1_direction_write_valid =
        predictor_pht_write.valid;
    wire [ 7:0] stage1_direction_write_index =
        predictor_pht_write.index;
    wire [ 1:0] stage1_direction_write_counter =
        predictor_pht_write.counter;
    wire        stage1_direction_write_actual_taken =
        predictor_pht_write.actual_taken;

    wire        abtb_update_valid = predictor_abtb_update.valid;
    wire        abtb_update_hit = predictor_abtb_update.hit;
    wire        abtb_update_way = predictor_abtb_update.way;
    wire [31:0] abtb_update_pc = predictor_abtb_update.pc;
    wire [ 1:0] abtb_update_cfi_type =
        predictor_abtb_update.cfi_type;
    wire [31:0] abtb_update_target = predictor_abtb_update.target;
    wire        abtb_write_valid = predictor_abtb_write.valid;
    wire        abtb_write_hit = predictor_abtb_write.hit;
    wire        abtb_write_way = predictor_abtb_write.way;
    wire [31:0] abtb_write_pc = predictor_abtb_write.pc;
    wire [ 1:0] abtb_write_cfi_type = predictor_abtb_write.cfi_type;
    wire [31:0] abtb_write_target = predictor_abtb_write.target;
    wire        stage1_steer_valid;
    wire        stage1_steer_source_abtb;
    wire        stage1_steer_branch_owned;
    wire        stage1_steer_branch_owned_nt;
    wire        stage1_steer_taken;
    wire        stage1_steer_bank;
    wire [ 1:0] stage1_steer_cfi_type;
    wire [31:0] stage1_steer_target;
    wire [31:0] stage1_steer_next_pc;

    wire        s0_pred_update_valid_raw;
    wire        s1_pred_update_valid_raw;
    wire        pred_train_from_s1 = predictor_train.from_slot1;
    wire        pred_train_valid = predictor_train.valid;
    wire [31:0] pred_train_pc = predictor_train.pc;
    wire        pred_train_is_branch = predictor_train.is_branch;
    wire        pred_train_is_jal = predictor_train.is_jal;
    wire        pred_train_is_jalr = predictor_train.is_jalr;
    wire        pred_train_actual_taken = predictor_train.actual_taken;
    wire [31:0] pred_train_actual_target =
        predictor_train.actual_target;

    // ================================================================
    //  Module instantiations
    // ================================================================

    // Field extraction and lightweight decode-derived policy shared by both
    // issue slots.
    id_stage_derive u_id_stage_derive (
        .id_pc             (id_pc),
        .id_inst           (id_inst),
        .id_inst1          (id_inst1),
        .dec_alu_src1_sel  (dec_alu_src1_sel),
        .dec_alu_src2_sel  (dec_alu_src2_sel),
        .dec_reg_write_en  (dec_reg_write_en),
        .dec_wb_sel        (dec_wb_sel),
        .dec_mem_read_en   (dec_mem_read_en),
        .dec_mem_write_en  (dec_mem_write_en),
        .dec_is_branch     (dec_is_branch),
        .dec_is_jal        (dec_is_jal),
        .dec_is_jalr       (dec_is_jalr),
        .dec_is_csr        (dec_is_csr),
        .dec_csr_uses_rs1  (dec_csr_uses_rs1),
        .dec_is_muldiv     (dec_is_muldiv),
        .dec1_alu_src1_sel (dec1_alu_src1_sel),
        .dec1_alu_src2_sel (dec1_alu_src2_sel),
        .dec1_mem_read_en  (dec1_mem_read_en),
        .dec1_mem_write_en (dec1_mem_write_en),
        .dec1_is_branch    (dec1_is_branch),
        .dec1_is_jal       (dec1_is_jal),
        .dec1_is_jalr      (dec1_is_jalr),
        .dec1_csr_uses_rs1 (dec1_csr_uses_rs1),
        .id_rs1_addr       (id_rs1_addr),
        .id_rs2_addr       (id_rs2_addr),
        .id_rd_addr        (id_rd_addr),
        .id_s1_rs1_addr    (id_s1_rs1_addr),
        .id_s1_rs2_addr    (id_s1_rs2_addr),
        .id_s1_rd_addr     (id_s1_rd_addr),
        .id_pc_plus_4      (id_pc_plus_4),
        .id_s1_pc          (id_s1_pc),
        .id_csr_cmd        (id_csr_cmd),
        .id_csr_addr       (id_csr_addr),
        .id_alu_src1_is_rs1(id_alu_src1_is_rs1),
        .id_alu_src2_is_rs2(id_alu_src2_is_rs2),
        .id_s1_alu_src1_is_rs1(id_s1_alu_src1_is_rs1),
        .id_s1_alu_src2_is_rs2(id_s1_alu_src2_is_rs2),
        .id_rs1_used       (id_rs1_used),
        .id_rs2_used       (id_rs2_used),
        .id_s1_rs1_used    (id_s1_rs1_used),
        .id_s1_rs2_used    (id_s1_rs2_used),
        .id_s0_alu_only    (id_s0_alu_only),
        .id_s1_repair_ok   (id_s1_repair_ok),
        .id_abtb_update_qualified(id_abtb_update_qualified_w),
        .id_abtb_update_cfi_type (id_abtb_update_cfi_type_w),
        .id_s1_abtb_update_qualified(id_s1_abtb_update_qualified_w),
        .id_s1_abtb_update_cfi_type (id_s1_abtb_update_cfi_type_w)
    );

    // ==================== Branch Predictor ====================
    // EX resolves control-flow outcomes. The update controller chooses at most
    // one architecturally valid CFI per cycle to train ABTB/PHT.

    predictor_resolve_builder u_predictor_resolve_builder (
        .s0_valid             (ex_valid),
        .s0_pc                (ex_pc),
        .s0_is_branch         (ex_is_branch),
        .s0_is_jal            (ex_is_jal),
        .s0_is_jalr           (ex_is_jalr),
        .s0_actual_taken      (actual_taken),
        .s0_actual_target     (actual_target),
        .s0_update_qualified  (ex_abtb_update_qualified),
        .s0_update_cfi_type   (ex_abtb_update_cfi_type),
        .s0_abtb_hit          (ex_abtb_hit),
        .s0_abtb_way          (ex_abtb_way),
        .s0_pht_index         (ex_stage1_pht_index),
        .s0_pht_counter       (ex_stage1_pht_counter),
        .s1_valid             (ex_s1_valid),
        .s1_pc                (ex_s1_pc),
        .s1_is_branch         (ex_s1_is_branch),
        .s1_is_jal            (ex_s1_is_jal),
        .s1_is_jalr           (ex_s1_is_jalr),
        .s1_actual_taken      (ex_s1_actual_taken),
        .s1_actual_target     (ex_s1_branch_target),
        .s1_update_qualified  (ex_s1_abtb_update_qualified),
        .s1_update_cfi_type   (ex_s1_abtb_update_cfi_type),
        .s1_abtb_hit          (ex_s1_abtb_hit),
        .s1_abtb_way          (ex_s1_abtb_way),
        .s1_pht_index         (ex_s1_stage1_pht_index),
        .s1_pht_counter       (ex_s1_stage1_pht_counter),
        .slot0_resolve        (predictor_resolve_s0),
        .slot1_resolve        (predictor_resolve_s1)
    );

    predictor_update_ctrl u_predictor_update_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .ex_ready_go      (ex_ready_go_w),
        .mem_allowin      (mem_allowin),
        .mem_branch_flush (mem_branch_flush),
        .slot0_resolve    (predictor_resolve_s0),
        .slot1_resolve    (predictor_resolve_s1),
        .slot0_cfi_valid  (s0_pred_update_valid_raw),
        .slot1_cfi_valid  (s1_pred_update_valid_raw),
        .train            (predictor_train),
        .abtb_update      (predictor_abtb_update),
        .pht_update       (predictor_pht_update),
        .abtb_write       (predictor_abtb_write),
        .pht_write        (predictor_pht_write)
    );

    frontend_stage1_direction u_frontend_stage1_direction (
        .clk                 (clk),
        .rst_n               (rst_n),
        .predict_pc          (pc),
        .lookup_ghr          (stage1_lookup_ghr),
        .bank0_index         (stage1_bank0_pht_index),
        .bank0_counter       (stage1_bank0_pht_counter),
        .bank0_taken         (stage1_bank0_pht_taken),
        .bank1_index         (stage1_bank1_pht_index),
        .bank1_counter       (stage1_bank1_pht_counter),
        .bank1_taken         (stage1_bank1_pht_taken),
        .update_valid        (stage1_direction_write_valid),
        .update_index        (stage1_direction_write_index),
        .update_counter      (stage1_direction_write_counter),
        .update_actual_taken (stage1_direction_write_actual_taken),
        .committed_ghr       (stage1_committed_ghr)
    );

`ifdef ABTB_MEASUREMENT
    (* dont_touch = "true" *)
`endif
    frontend_abtb u_frontend_abtb (
        .clk                  (clk),
        .rst_n                (rst_n),
        .lookup_valid         (abtb_lookup_accept),
        .predict_pc           (pc),
        .bank0_branch_taken   (stage1_bank0_pht_taken),
        .bank1_branch_taken   (stage1_bank1_pht_taken),
        .bank0_ret_valid      (1'b0),
        .bank0_ret_target     (32'd0),
        .bank1_ret_valid      (1'b0),
        .bank1_ret_target     (32'd0),
        .bank0_eligible       (),
        .bank0_lookup_hit     (abtb_bank0_lookup_hit),
        .bank0_hit            (abtb_bank0_hit),
        .bank0_way            (abtb_bank0_way),
        .bank0_cfi_type       (abtb_bank0_cfi_type),
        .bank0_abtb_pred_target (abtb_bank0_abtb_pred_target),
        .bank0_pred_taken     (abtb_bank0_pred_taken),
        .bank0_final_pred_target (abtb_bank0_final_pred_target),
        .bank1_eligible       (),
        .bank1_lookup_hit     (abtb_bank1_lookup_hit),
        .bank1_hit            (abtb_bank1_hit),
        .bank1_way            (abtb_bank1_way),
        .bank1_cfi_type       (abtb_bank1_cfi_type),
        .bank1_abtb_pred_target (abtb_bank1_abtb_pred_target),
        .bank1_pred_taken     (abtb_bank1_pred_taken),
        .bank1_final_pred_target (abtb_bank1_final_pred_target),
        .pred_taken           (abtb_shadow_pred_taken),
        .pred_bank            (abtb_shadow_pred_bank),
        .pred_cfi_type        (abtb_shadow_pred_cfi_type),
        .pred_target          (abtb_shadow_pred_target),
        .pred_next_pc         (abtb_shadow_pred_next_pc),
        .update_valid         (abtb_write_valid),
        .update_hit           (abtb_write_hit),
        .update_way           (abtb_write_way),
        .update_pc            (abtb_write_pc),
        .update_cfi_type      (abtb_write_cfi_type),
        .update_target        (abtb_write_target)
    );

`ifdef CPU_TOP_ABTB_OBSERVE
    // Simulation and measurement observability only. These outputs never feed
    // production prediction, ready/valid, redirect, or IROM control.
    wire cpu_defs::abtb_lookup_bank_t abtb_monitor_bank0;
    wire cpu_defs::abtb_lookup_bank_t abtb_monitor_bank1;
    wire cpu_defs::abtb_shadow_result_t abtb_monitor_shadow;
    wire cpu_defs::stage1_steer_event_t abtb_monitor_steer;
    wire cpu_defs::frontend_abtb_counters_t abtb_monitor_counters;

    frontend_abtb_monitor_adapter u_frontend_abtb_monitor_adapter (
        .bank0_hit              (abtb_bank0_hit),
        .bank0_way              (abtb_bank0_way),
        .bank0_cfi_type         (abtb_bank0_cfi_type),
        .bank0_abtb_pred_target (abtb_bank0_abtb_pred_target),
        .bank0_pred_taken       (abtb_bank0_pred_taken),
        .bank0_final_pred_target(abtb_bank0_final_pred_target),
        .bank0_pht_taken        (stage1_bank0_pht_taken),
        .bank1_hit              (abtb_bank1_hit),
        .bank1_way              (abtb_bank1_way),
        .bank1_cfi_type         (abtb_bank1_cfi_type),
        .bank1_abtb_pred_target (abtb_bank1_abtb_pred_target),
        .bank1_pred_taken       (abtb_bank1_pred_taken),
        .bank1_final_pred_target(abtb_bank1_final_pred_target),
        .bank1_pht_taken        (stage1_bank1_pht_taken),
        .shadow_pred_taken      (abtb_shadow_pred_taken),
        .shadow_pred_bank       (abtb_shadow_pred_bank),
        .shadow_pred_cfi_type   (abtb_shadow_pred_cfi_type),
        .shadow_pred_target     (abtb_shadow_pred_target),
        .shadow_pred_next_pc    (abtb_shadow_pred_next_pc),
        .steer_valid            (stage1_steer_valid),
        .steer_source_abtb      (stage1_steer_source_abtb),
        .steer_branch_owned     (stage1_steer_branch_owned),
        .steer_branch_owned_nt  (stage1_steer_branch_owned_nt),
        .steer_bank             (stage1_steer_bank),
        .bank0_lookup           (abtb_monitor_bank0),
        .bank1_lookup           (abtb_monitor_bank1),
        .shadow_result          (abtb_monitor_shadow),
        .steer_event            (abtb_monitor_steer)
    );

    wire [31:0] abtb_lookup_block_count =
        abtb_monitor_counters.lookup_block;
    wire [31:0] abtb_bank0_hit_count = abtb_monitor_counters.bank0_hit;
    wire [31:0] abtb_bank1_hit_count = abtb_monitor_counters.bank1_hit;
    wire [31:0] abtb_ex_update_count = abtb_monitor_counters.ex_update;
    wire [31:0] abtb_allocation_count = abtb_monitor_counters.allocation;
    wire [31:0] abtb_hit_update_count = abtb_monitor_counters.hit_update;
    wire [31:0] abtb_direct_lookup_count =
        abtb_monitor_counters.direct_lookup;
    wire [31:0] abtb_direct_steer_count =
        abtb_monitor_counters.direct_steer;
    wire [31:0] abtb_direct_bank0_count =
        abtb_monitor_counters.direct_bank0;
    wire [31:0] abtb_direct_bank1_count =
        abtb_monitor_counters.direct_bank1;
    wire [31:0] abtb_direct_correct_count =
        abtb_monitor_counters.direct_correct;
    wire [31:0] abtb_direct_redirect_count =
        abtb_monitor_counters.direct_redirect;
    wire [31:0] abtb_direct_target_miss_count =
        abtb_monitor_counters.direct_target_miss;
    wire [31:0] stage1_sequential_count =
        abtb_monitor_counters.stage1_sequential;
    wire [31:0] stage1_abtb_owned_count =
        abtb_monitor_counters.stage1_abtb_owned;
    wire [31:0] stage1_branch_owned_nt_count =
        abtb_monitor_counters.stage1_branch_owned_nt;
    wire [31:0] stage1_confirmed_branch_count =
        abtb_monitor_counters.stage1_confirmed_branch;
    wire [31:0] stage1_abtb_branch_hit_count =
        abtb_monitor_counters.stage1_abtb_branch_hit;
    wire [31:0] stage1_pht_taken_count =
        abtb_monitor_counters.stage1_pht_taken;
    wire [31:0] stage1_pht_not_taken_count =
        abtb_monitor_counters.stage1_pht_not_taken;
    wire [31:0] stage1_pht_correct_count =
        abtb_monitor_counters.stage1_pht_correct;
    wire [31:0] stage1_pht_wrong_count =
        abtb_monitor_counters.stage1_pht_wrong;
    wire [31:0] stage1_bank0_branch_lookup_count =
        abtb_monitor_counters.stage1_bank0_branch_lookup;
    wire [31:0] stage1_bank1_branch_lookup_count =
        abtb_monitor_counters.stage1_bank1_branch_lookup;

    frontend_abtb_monitor u_frontend_abtb_monitor (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .frontend_pc            (pc),
        .lookup_accept          (abtb_lookup_accept),
        .bank0_lookup           (abtb_monitor_bank0),
        .bank1_lookup           (abtb_monitor_bank1),
        .shadow_result          (abtb_monitor_shadow),
        .steer_event            (abtb_monitor_steer),
        .if_slot0_prediction    (if_id_payload.slot0.prediction),
        .if_slot1_prediction    (if_id_payload.slot1.prediction),
        .id_slot0_prediction    (id_payload.slot0.prediction),
        .id_slot1_prediction    (id_payload.slot1.prediction),
        .ex_slot0_prediction    (ex_s0_payload.common.prediction),
        .ex_slot1_prediction    (ex_s1_payload.common.prediction),
        .slot0_resolve          (predictor_resolve_s0),
        .slot1_resolve          (predictor_resolve_s1),
        .ex_ready_go            (ex_ready_go_w),
        .mem_allowin            (mem_allowin),
        .mem_branch_flush       (mem_branch_flush),
        .slot0_cfi_valid        (s0_pred_update_valid_raw),
        .slot0_redirect         (branch_flush),
        .slot1_redirect         (ex_s1_branch_redirect),
        .abtb_update            (predictor_abtb_update),
        .pht_update             (predictor_pht_update),
        .counters               (abtb_monitor_counters)
    );
`endif

    // ==================== Pre-IF ====================

    wire        can_dual_issue;
    wire        raw_pair_raw;
    logic       predict_dual;

    wire [31:0] if_inst0_out = if_id_payload.slot0.inst;
    wire [31:0] if_inst1_out = if_id_payload.slot1.inst;
    wire [31:0] if_pc_out = if_id_payload.pc;
    wire        if_pred_taken_out = if_id_payload.slot0.prediction.taken;
    wire [31:0] if_pred_target_out = if_id_payload.slot0.prediction.target;
    wire        if_s1_pred_taken_out = if_id_payload.slot1.prediction.taken;
    wire [31:0] if_s1_pred_target_out = if_id_payload.slot1.prediction.target;
    wire        if_skip_out;
    wire        if_s1_valid;

    // Compatibility probes retained for the existing performance monitor.
    // The retired raw-pair and skip machinery no longer feeds the frontend.
    wire raw_inst1_is_alu_type = 1'b0;
    wire raw_inst0_is_jump = 1'b0;
    wire if_sequential_fetch = ~if_pred_taken_out;
    wire skip_inst0_valid = 1'b0;

    // Frontend FTQ owns BP0/F0/F1 fetch flow and returns at most two
    // predecoded instructions to the existing IF/ID register.
    frontend_ftq u_frontend_ftq (
        .clk              (clk),
        .rst_n            (rst_n),
        .id_allowin       (id_allowin),
        .ex_redirect_valid(frontend_branch_flush),
        .ex_redirect_target(frontend_branch_target),
        .irom_addr        (irom_addr),
        .irom_data        (irom_data),
        .abtb_bank0_lookup_hit  (abtb_bank0_lookup_hit),
        .abtb_bank0_hit         (abtb_bank0_hit),
        .abtb_bank0_way         (abtb_bank0_way),
        .abtb_bank0_cfi_type    (abtb_bank0_cfi_type),
        .abtb_bank0_abtb_pred_target      (abtb_bank0_abtb_pred_target),
        .abtb_bank0_pred_taken  (abtb_bank0_pred_taken),
        .abtb_bank0_final_pred_target (abtb_bank0_final_pred_target),
        .abtb_bank1_lookup_hit  (abtb_bank1_lookup_hit),
        .abtb_bank1_hit         (abtb_bank1_hit),
        .abtb_bank1_way         (abtb_bank1_way),
        .abtb_bank1_cfi_type    (abtb_bank1_cfi_type),
        .abtb_bank1_abtb_pred_target      (abtb_bank1_abtb_pred_target),
        .abtb_bank1_pred_taken  (abtb_bank1_pred_taken),
        .abtb_bank1_final_pred_target (abtb_bank1_final_pred_target),
        .stage1_bank0_pht_index(stage1_bank0_pht_index),
        .stage1_bank0_pht_counter(stage1_bank0_pht_counter),
        .stage1_bank1_pht_index(stage1_bank1_pht_index),
        .stage1_bank1_pht_counter(stage1_bank1_pht_counter),
        .if_valid         (if_valid),
        .if_ready_go      (if_ready_go_w),
        .if_s1_valid      (if_s1_valid),
        .if_payload       (if_id_payload),
        .current_pc       (pc),
        .abtb_lookup_accept(abtb_lookup_accept),
        .stage1_steer_valid(stage1_steer_valid),
        .stage1_steer_source_abtb(stage1_steer_source_abtb),
        .stage1_steer_branch_owned(stage1_steer_branch_owned),
        .stage1_steer_branch_owned_nt(stage1_steer_branch_owned_nt),
        .stage1_steer_taken(stage1_steer_taken),
        .stage1_steer_bank(stage1_steer_bank),
        .stage1_steer_cfi_type(stage1_steer_cfi_type),
        .stage1_steer_target(stage1_steer_target),
        .stage1_steer_next_pc(stage1_steer_next_pc),
        .can_dual_issue   (can_dual_issue),
        .raw_pair_raw     (raw_pair_raw),
        .predict_dual     (predict_dual),
        .irom_held_valid  (irom_held_valid),
        .if_skip_out      (if_skip_out)
    );

    dual_issue_counter u_dual_issue_counter (
        .clk             (clk),
        .rst_n           (rst_n),
        .wb_s1_valid     (wb_s1_valid),
        .dual_issue_count(dual_issue_count)
    );

    // ==================== IF/ID ====================

    if_id_reg u_if_id_reg (
        .clk          (clk),
        .rst_n        (rst_n),
        .if_valid     (if_valid),
        .if_ready_go  (if_ready_go_w),
        .id_allowin   (id_allowin),
        .id_valid     (id_valid),
        .id_flush     (id_flush),
        .if_s1_valid  (if_s1_valid),
        .id_s1_valid  (id_s1_valid),
        .if_payload   (if_id_payload),
        .id_payload   (id_payload)
    );

    decoder u_decoder (
        .inst           (id_inst),            // from IF/ID register
        .alu_op         (dec_alu_op),
        .alu_src1_sel   (dec_alu_src1_sel),
        .alu_src2_sel   (dec_alu_src2_sel),
        .reg_write_en   (dec_reg_write_en),
        .wb_sel         (dec_wb_sel),
        .mem_read_en    (dec_mem_read_en),
        .mem_write_en   (dec_mem_write_en),
        .mem_size       (dec_mem_size),
        .mem_unsigned   (dec_mem_unsigned),
        .is_branch      (dec_is_branch),
        .branch_cond    (dec_branch_cond),
        .is_jal         (dec_is_jal),
        .is_jalr        (dec_is_jalr),
        .is_csr         (dec_is_csr),
        .csr_uses_rs1   (dec_csr_uses_rs1),
        .csr_uses_imm   (dec_csr_uses_imm),
        .is_ecall       (dec_is_ecall),
        .is_mret        (dec_is_mret),
        .is_muldiv      (dec_is_muldiv),
        .imm_type       (dec_imm_type)
    );

    decoder u_decoder_s1 (
        .inst           (id_inst1),
        .alu_op         (dec1_alu_op),
        .alu_src1_sel   (dec1_alu_src1_sel),
        .alu_src2_sel   (dec1_alu_src2_sel),
        .reg_write_en   (dec1_reg_write_en),
        .wb_sel         (dec1_wb_sel),
        .mem_read_en    (dec1_mem_read_en),
        .mem_write_en   (dec1_mem_write_en),
        .mem_size       (dec1_mem_size),
        .mem_unsigned   (dec1_mem_unsigned),
        .is_branch      (dec1_is_branch),
        .branch_cond    (dec1_branch_cond),
        .is_jal         (dec1_is_jal),
        .is_jalr        (dec1_is_jalr),
        .is_csr         (dec1_is_csr),
        .csr_uses_rs1   (dec1_csr_uses_rs1),
        .csr_uses_imm   (dec1_csr_uses_imm),
        .is_ecall       (dec1_is_ecall),
        .is_mret        (dec1_is_mret),
        .is_muldiv      (dec1_is_muldiv),
        .imm_type       (dec1_imm_type)
    );

    bitmanip_decoder u_bitmanip_decoder (
        .inst         (id_inst),
        .is_bitmanip  (dec_is_bitmanip),
        .bitmanip_op  (dec_bitmanip_op)
    );

    imm_gen u_imm_gen (
        .inst     (id_inst),                   // from IF/ID register
        .imm_type (dec_imm_type),
        .imm      (id_imm)
    );

    imm_gen u_imm_gen_s1 (
        .inst     (id_inst1),
        .imm_type (dec1_imm_type),
        .imm      (id_s1_imm)
    );

    regfile u_regfile (
        .clk          (clk),
        .rst_n        (rst_n),
        .rs1_addr     (id_rs1_addr),
        .rs2_addr     (id_rs2_addr),
        .rs1_data     (rf_rs1_data),
        .rs2_data     (rf_rs2_data),
        .rs1_addr_s1  (id_s1_rs1_addr),
        .rs2_addr_s1  (id_s1_rs2_addr),
        .rs1_data_s1  (rf_s1_rs1_data),
        .rs2_data_s1  (rf_s1_rs2_data),
        .rd_addr      (wb_rd),
        .rd_data      (wb_write_data),
        .rd_wen       (wb_reg_write_en),
        .rd_valid     (wb_valid),
        .rd_addr_s1   (wb_s1_rd),
        .rd_data_s1   (wb_s1_write_data),
        .rd_wen_s1    (wb_s1_reg_write_en),
        .rd_valid_s1  (wb_s1_valid)
    );

    // Forwarding also returns id_ready_go_raw. Timer IRQ hold is applied after
    // hazard detection so interrupts stall ID like an ordinary readiness block.
    forwarding u_forwarding (
        .id_rs1_addr    (id_rs1_addr),
        .id_rs2_addr    (id_rs2_addr),
        .id_rs1_used    (id_rs1_used),
        .id_rs2_used    (id_rs2_used),
        .id_s0_alu_only (id_s0_alu_only),
        .id_s0_jalr     (dec_is_jalr),
        .id_s0_branch   (dec_is_branch),
        .id_s0_mem_read (dec_mem_read_en),
        .id_s0_mem_write(dec_mem_write_en),
        .id_s0_is_mul   (id_is_mul),
        .id_s0_pc       (id_pc),
        .id_s0_imm      (id_imm),
        .id_s0_alu_src1_sel(dec_alu_src1_sel),
        .id_s0_alu_src2_sel(dec_alu_src2_sel),
        .rf_rs1_data    (rf_rs1_data),
        .rf_rs2_data    (rf_rs2_data),
        .id_s1_valid    (id_s1_valid),
        .id_s1_rs1_addr (id_s1_rs1_addr),
        .id_s1_rs2_addr (id_s1_rs2_addr),
        .id_s1_rs1_used (id_s1_rs1_used),
        .id_s1_rs2_used (id_s1_rs2_used),
        .id_s1_repair_ok(id_s1_repair_ok),
        .id_s1_pc       (id_s1_pc),
        .id_s1_imm      (id_s1_imm),
        .id_s1_alu_src1_sel(dec1_alu_src1_sel),
        .id_s1_alu_src2_sel(dec1_alu_src2_sel),
        .rf_s1_rs1_data (rf_s1_rs1_data),
        .rf_s1_rs2_data (rf_s1_rs2_data),
        .ex_valid       (ex_valid),
        .ex_reg_write   (ex_forward_reg_write),
        .ex_is_bitmanip (ex_is_bitmanip),
        .ex_is_muldiv   (ex_is_muldiv),
        .ex_mem_read    (ex_mem_read_en),
        .ex_rd          (ex_rd),
        .ex_alu_result  (ex_forward_result),
        .ex_fast_alu    (ex_fast_alu_forward),
        .ex_fast_alu_result(alu_result),
        .ex_pc_plus_4   (ex_pc_plus_4),
        .ex_wb_sel      (ex_wb_sel),
        .ex_s1_valid       (ex_s1_valid),
        .ex_s1_reg_write   (ex_s1_reg_write_en),
        .ex_s1_mem_read    (ex_s1_mem_read_en),
        .ex_s1_rd          (ex_s1_rd),
        .ex_s1_alu_result  (alu_s1_result),
        .ex_s1_pc_plus_4   (ex_s1_pc_plus_4),
        .ex_s1_wb_sel      (ex_s1_wb_sel),
        .mem_valid      (mem_valid),
        .mem_reg_write  (mem_reg_write_en),
        .mem_is_load    (mem_mem_read_en),
        .mem_is_mul     (mem_is_mul),
        .mem_rd         (mem_rd),
        .mem_alu_result (mem_alu_result),
        .mem_mul_result (muldiv_result),
        .mem_pc_plus_4  (mem_pc_plus_4),
        .mem_load_ready (mem_load_ready),
        .mem_wb_sel     (mem_wb_sel),
        .mem_s1_valid       (mem_s1_valid),
        .mem_s1_reg_write   (mem_s1_reg_write_en),
        .mem_s1_is_load     (mem_s1_mem_read_en),
        .mem_s1_rd          (mem_s1_rd),
        .mem_s1_alu_result  (mem_s1_alu_result),
        .mem_s1_pc_plus_4   (mem_s1_pc_plus_4),
        .mem_s1_wb_sel      (mem_s1_wb_sel),
        .wb_valid       (wb_valid),
        .wb_reg_write   (wb_reg_write_en),
        .wb_rd          (wb_rd),
        .wb_write_data  (wb_write_data),
        .wb_s1_valid       (wb_s1_valid),
        .wb_s1_reg_write   (wb_s1_reg_write_en),
        .wb_s1_rd          (wb_s1_rd),
        .wb_s1_write_data  (wb_s1_write_data),
        .id_rs1_data    (fwd_rs1_data),
        .id_rs2_data    (fwd_rs2_data),
        .id_s1_rs1_data (fwd_s1_rs1_data),
        .id_s1_rs2_data (fwd_s1_rs2_data),
        .id_s0_alu_src1 (id_alu_src1),
        .id_s0_alu_src2 (id_alu_src2),
        .id_s1_alu_src1 (id_s1_alu_src1),
        .id_s1_alu_src2 (id_s1_alu_src2),
        .id_rs1_wb_repair(fwd_rs1_wb_repair),
        .id_rs2_wb_repair(fwd_rs2_wb_repair),
        .id_s1_rs1_wb_repair(fwd_s1_rs1_wb_repair),
        .id_s1_rs2_wb_repair(fwd_s1_rs2_wb_repair),
        .id_ready_go    (id_ready_go_raw),
        .id_ready_go_if_mem_ready(id_ready_go_raw_if_mem_ready),
        .id_ready_go_if_mem_wait(id_ready_go_raw_if_mem_wait)
    );

    // Keep the DSP operand mux physically independent from the ordinary ID/EX
    // outputs. A true EX -> MUL RAW is interlocked above, so only registered
    // MEM/WB/RF candidates can reach the local DSP input registers.
    (* keep_hierarchy = "yes" *) mul_operand_forwarding u_mul_operand_forwarding (
        .id_rs1_addr          (id_rs1_addr),
        .id_rs2_addr          (id_rs2_addr),
        .rf_rs1_data          (rf_rs1_data),
        .rf_rs2_data          (rf_rs2_data),
        .mem_valid            (mem_valid),
        .mem_reg_write        (mem_reg_write_en),
        .mem_is_load          (mem_mem_read_en),
        .mem_is_mul           (mem_is_mul),
        .mem_rd               (mem_rd),
        .mem_alu_result       (mem_alu_result),
        .mem_mul_result       (muldiv_result),
        .mem_pc_plus_4        (mem_pc_plus_4),
        .mem_wb_sel           (mem_wb_sel),
        .mem_s1_valid         (mem_s1_valid),
        .mem_s1_reg_write     (mem_s1_reg_write_en),
        .mem_s1_is_load       (mem_s1_mem_read_en),
        .mem_s1_rd            (mem_s1_rd),
        .mem_s1_alu_result    (mem_s1_alu_result),
        .mem_s1_pc_plus_4     (mem_s1_pc_plus_4),
        .mem_s1_wb_sel        (mem_s1_wb_sel),
        .wb_valid             (wb_valid),
        .wb_reg_write         (wb_reg_write_en),
        .wb_rd                (wb_rd),
        .wb_write_data        (wb_write_data),
        .wb_s1_valid          (wb_s1_valid),
        .wb_s1_reg_write      (wb_s1_reg_write_en),
        .wb_s1_rd             (wb_s1_rd),
        .wb_s1_write_data     (wb_s1_write_data),
        .mul_rs1_data         (mul_fwd_rs1_data),
        .mul_rs2_data         (mul_fwd_rs2_data)
    );

`ifndef SYNTHESIS
    // Simulation-only cycle-equivalence references for the timing-parallelized
    // ALU source outputs returned by u_forwarding.
    wire [31:0] id_alu_src1_reference;
    wire [31:0] id_alu_src2_reference;
    wire [31:0] id_s1_alu_src1_reference;
    wire [31:0] id_s1_alu_src2_reference;

    alu_src_mux u_alu_src_mux_reference (
        .rs1_data      (fwd_rs1_data),
        .rs2_data      (fwd_rs2_data),
        .pc            (id_pc),
        .imm           (id_imm),
        .alu_src1_sel  (dec_alu_src1_sel),
        .alu_src2_sel  (dec_alu_src2_sel),
        .alu_src1      (id_alu_src1_reference),
        .alu_src2      (id_alu_src2_reference)
    );

    alu_src_mux u_alu_src_mux_s1_reference (
        .rs1_data      (fwd_s1_rs1_data),
        .rs2_data      (fwd_s1_rs2_data),
        .pc            (id_s1_pc),
        .imm           (id_s1_imm),
        .alu_src1_sel  (dec1_alu_src1_sel),
        .alu_src2_sel  (dec1_alu_src2_sel),
        .alu_src1      (id_s1_alu_src1_reference),
        .alu_src2      (id_s1_alu_src2_reference)
    );
`endif

    // ==================== ID/EX ====================

    // Payload builders keep large struct assembly out of sequential registers.
    id_ex_payload_builder u_id_ex_payload_builder (
        .s0_pc                 (id_pc),
        .s0_alu_src1           (id_alu_src1),
        .s0_alu_src2           (id_alu_src2),
        .s0_rs1_data           (fwd_rs1_data),
        .s0_rs2_data           (fwd_rs2_data),
        .s0_rs1_wb_repair      (fwd_rs1_wb_repair),
        .s0_rs2_wb_repair      (fwd_rs2_wb_repair),
        .s0_rd                 (id_rd_addr),
        .s0_rs1_addr           (id_rs1_addr),
        .s0_rs2_addr           (id_rs2_addr),
        .s0_alu_src1_is_rs1    (id_alu_src1_is_rs1),
        .s0_alu_src2_is_rs2    (id_alu_src2_is_rs2),
        .s0_alu_op             (dec_alu_op),
        .s0_reg_write_en       (dec_reg_write_en),
        .s0_wb_sel             (dec_wb_sel),
        .s0_mem_read_en        (dec_mem_read_en),
        .s0_mem_write_en       (dec_mem_write_en),
        .s0_mem_size           (dec_mem_size),
        .s0_mem_unsigned       (dec_mem_unsigned),
        .s0_is_branch          (dec_is_branch),
        .s0_branch_cond        (dec_branch_cond),
        .s0_is_jal             (dec_is_jal),
        .s0_is_jalr            (dec_is_jalr),
        .s0_prediction         (id_payload.slot0.prediction),
        .s0_update_qualified   (id_abtb_update_qualified_w),
        .s0_update_cfi_type    (id_abtb_update_cfi_type_w),
        .s0_is_csr             (dec_is_csr),
        .s0_csr_uses_imm       (dec_csr_uses_imm),
        .s0_csr_cmd            (id_csr_cmd),
        .s0_csr_addr           (id_csr_addr),
        .s0_is_ecall           (dec_is_ecall),
        .s0_is_mret            (dec_is_mret),
        .s0_is_muldiv          (dec_is_muldiv),
        .s0_muldiv_op          (id_inst[14:12]),
        .s0_is_bitmanip        (dec_is_bitmanip),
        .s0_bitmanip_op        (dec_bitmanip_op),
        .s1_pc                 (id_s1_pc),
        .s1_inst               (id_inst1),
        .s1_alu_src1           (id_s1_alu_src1),
        .s1_alu_src2           (id_s1_alu_src2),
        .s1_rs1_data           (fwd_s1_rs1_data),
        .s1_rs2_data           (fwd_s1_rs2_data),
        .s1_rs1_wb_repair      (fwd_s1_rs1_wb_repair),
        .s1_rs2_wb_repair      (fwd_s1_rs2_wb_repair),
        .s1_rd                 (id_s1_rd_addr),
        .s1_rs1_addr           (id_s1_rs1_addr),
        .s1_rs2_addr           (id_s1_rs2_addr),
        .s1_alu_src1_is_rs1    (id_s1_alu_src1_is_rs1),
        .s1_alu_src2_is_rs2    (id_s1_alu_src2_is_rs2),
        .s1_alu_op             (dec1_alu_op),
        .s1_reg_write_en       (dec1_reg_write_en),
        .s1_wb_sel             (dec1_wb_sel),
        .s1_mem_read_en        (dec1_mem_read_en),
        .s1_mem_write_en       (dec1_mem_write_en),
        .s1_mem_size           (dec1_mem_size),
        .s1_mem_unsigned       (dec1_mem_unsigned),
        .s1_is_branch          (dec1_is_branch),
        .s1_branch_cond        (dec1_branch_cond),
        .s1_is_jal             (dec1_is_jal),
        .s1_is_jalr            (dec1_is_jalr),
        .s1_prediction         (id_payload.slot1.prediction),
        .s1_update_qualified   (id_s1_abtb_update_qualified_w),
        .s1_update_cfi_type    (id_s1_abtb_update_cfi_type_w),
        .slot0_payload         (id_ex_s0_payload),
        .slot1_payload         (id_ex_s1_payload)
    );

    id_ex_reg u_id_ex_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .id_valid         (id_valid),
        .id_ready_go      (id_ready_go),
        .ex_allowin       (ex_allowin),
        .ex_valid         (ex_valid),
        .ex_flush         (ex_flush),
        .id_payload       (id_ex_s0_payload),
        .ex_payload       (ex_s0_payload),
        .ex_fast_alu_src1_wb_repair(ex_fast_alu_src1_wb_repair),
        .ex_fast_alu_src2_wb_repair(ex_fast_alu_src2_wb_repair)
    );

    id_ex_reg_s1 u_id_ex_reg_s1 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .id_s1_valid         (id_s1_valid),
        .id_ready_go         (id_ready_go),
        .ex_allowin          (ex_allowin),
        .ex_flush            (ex_flush),
        .ex_s1_valid         (ex_s1_valid),
        .id_payload          (id_ex_s1_payload),
        .ex_payload          (ex_s1_payload),
        .ex_fast_alu_src1_wb_repair(ex_s1_fast_alu_src1_wb_repair),
        .ex_fast_alu_src2_wb_repair(ex_s1_fast_alu_src2_wb_repair)
    );

    // Keep this timing-sensitive one-bit control separate from the wide Slot 1
    // payload.  It follows exactly the same accept/hold/flush protocol as the
    // ID/EX register without perturbing the packed payload layout and fanout.
    logic ex_s0_alu_store_data_bypass_r;
    always_ff @(posedge clk) begin
        if (!rst_n || ex_flush)
            ex_s0_alu_store_data_bypass_r <= 1'b0;
        else if (ex_allowin)
            ex_s0_alu_store_data_bypass_r <= id_ready_go
                                             & id_s0_alu_store_data_bypass;
    end

    // ==================== EX stage ====================
    // MEM-ready load consumers repair their operands from WB here. The
    // repaired result is allowed to feed younger ID consumers after moving CFI
    // target/compare work out of ID.
    ex_stage_ctrl u_ex_stage_ctrl (
        .ex_pc                      (ex_pc),
        .ex_s1_pc                   (ex_s1_pc),
        .ex_valid                   (ex_valid),
        .ex_rs1_wb_repair           (ex_rs1_wb_repair),
        .ex_rs2_wb_repair           (ex_rs2_wb_repair),
        .wb_load_data               (wb_load_data_ex),
        .ex_alu_src1                (ex_alu_src1),
        .ex_alu_src2                (ex_alu_src2),
        .ex_alu_src1_wb_repair      (ex_alu_src1_wb_repair),
        .ex_alu_src2_wb_repair      (ex_alu_src2_wb_repair),
        .ex_rs1_data                (ex_rs1_data),
        .ex_rs2_data                (ex_rs2_data),
        .ex_is_branch               (ex_is_branch),
        .ex_is_jal                  (ex_is_jal),
        .ex_is_jalr                 (ex_is_jalr),
        .ex_is_csr                  (ex_is_csr),
        .ex_csr_rdata               (ex_csr_rdata),
        .ex_is_muldiv               (ex_is_muldiv),
        .ex_muldiv_result           (muldiv_result),
        .ex_is_bitmanip             (ex_is_bitmanip),
        .ex_bitmanip_result         (bitmanip_result),
        .alu_result                 (alu_result),
        .ex_s1_valid                (ex_s1_valid),
        .ex_s1_is_branch            (ex_s1_is_branch),
        .ex_s1_is_jal               (ex_s1_is_jal),
        .ex_s1_is_jalr              (ex_s1_is_jalr),
        .ex_s1_branch_cond          (ex_s1_branch_cond),
        .ex_s1_rs1_wb_repair        (ex_s1_rs1_wb_repair),
        .ex_s1_rs2_wb_repair        (ex_s1_rs2_wb_repair),
        .ex_s1_alu_src1             (ex_s1_alu_src1),
        .ex_s1_alu_src2             (ex_s1_alu_src2),
        .ex_s1_alu_src1_wb_repair   (ex_s1_alu_src1_wb_repair),
        .ex_s1_alu_src2_wb_repair   (ex_s1_alu_src2_wb_repair),
        .ex_s1_rs1_data             (ex_s1_rs1_data),
        .ex_s1_rs2_data             (ex_s1_rs2_data),
        .ex_s1_predicted_taken      (ex_s1_pred_taken),
        .ex_s1_predicted_target     (ex_s1_pred_target),
        .mem_branch_flush           (mem_branch_flush),
        .ex_ready_go                (ex_ready_go_w),
        .mem_allowin                (mem_allowin),
        .ex_branch_redirect         (ex_branch_registered_flush),
        .branch_target              (branch_target),
        .ex_system_redirect         (ex_system_redirect),
        .ex_system_target           (ex_system_target),
        .ex_pc_plus_4               (ex_pc_plus_4),
        .ex_s1_pc_plus_4            (ex_s1_pc_plus_4),
        .ex_alu_src1_repair         (ex_alu_src1_repair),
        .ex_alu_src2_repair         (ex_alu_src2_repair),
        .ex_s1_alu_src1_repair      (ex_s1_alu_src1_repair),
        .ex_s1_alu_src2_repair      (ex_s1_alu_src2_repair),
        .ex_rs1_data_repair         (ex_rs1_data_repair),
        .ex_rs2_data_repair         (ex_rs2_data_repair),
        .ex_s1_rs1_data_repair      (ex_s1_rs1_data_repair),
        .ex_s1_rs2_data_repair      (ex_s1_rs2_data_repair),
        .ex_forward_result          (ex_forward_result),
        .ex_pipe_alu_result         (ex_pipe_alu_result),
        .ex_control_target          (ex_control_target),
        .ex_s1_branch_target        (ex_s1_branch_target),
        .ex_s1_actual_taken         (ex_s1_actual_taken),
        .ex_s1_branch_redirect      (ex_s1_branch_redirect),
        .ex_registered_branch_flush (ex_registered_branch_flush),
        .ex_registered_branch_target(ex_registered_branch_target)
    );

    alu u_alu (
        .alu_op       (ex_alu_op),
        .alu_src1     (ex_fast_alu_src1),
        .alu_src2     (ex_fast_alu_src2),
        .alu_addr_src1(ex_alu_src1_repair),
        .alu_addr_src2(ex_alu_src2_repair),
        .alu_result   (alu_result),
        .alu_sum      (alu_sum),
        .alu_addr     (alu_addr)
    );

    alu u_alu_s1 (
        .alu_op       (ex_s1_alu_op),
        .alu_src1     (ex_s1_fast_alu_src1),
        .alu_src2     (ex_s1_fast_alu_src2),
        .alu_addr_src1(ex_s1_alu_src1_repair),
        .alu_addr_src2(ex_s1_alu_src2_repair),
        .alu_result   (alu_s1_result),
        .alu_sum      (alu_s1_sum),
        .alu_addr     (alu_s1_addr)
    );

    // Byte-lane selection only depends on addition modulo four.  Compute that
    // small result beside the full address adders so a repaired WB operand does
    // not have to traverse a 32-bit carry chain before reaching store_wea.
    assign ex_store_addr_low = ex_alu_src1_repair[1:0]
                             + ex_alu_src2_repair[1:0];
    assign ex_s1_store_addr_low = ex_s1_alu_src1_repair[1:0]
                                + ex_s1_alu_src2_repair[1:0];

    // DIV/REM hold EX until completion; prestarted MUL operations advance to
    // MEM after one EX cycle and rendezvous there with the registered product.
    muldiv_unit u_muldiv_unit (
        .clk                (clk),
        .rst_n              (rst_n),
        .mul_prestart_valid (id_mul_prestart),
        .mul_prestart_op    (id_inst[14:12]),
        // RV32M is R-type. The physically independent forwarding copy contains
        // only registered MEM/WB/RF payloads; EX RAW dependencies interlock.
        .mul_prestart_rs1   (mul_fwd_rs1_data),
        .mul_prestart_rs2   (mul_fwd_rs2_data),
        .req_valid          (ex_muldiv_req),
        .req_op             (ex_muldiv_op),
        .req_div_rs1        (ex_alu_src1),
        .req_div_rs2        (ex_alu_src2),
        .consume            (muldiv_consume),
        .flush              (muldiv_flush),
        .busy               (muldiv_busy),
        .done               (muldiv_done),
        .result             (muldiv_result)
    );

`ifndef SYNTHESIS
    // The DSP launch deliberately accepts only registered MEM/WB/RF payloads.
    // Keep both the RAW interlock and the timing-parallelized ALU source
    // selection cycle-equivalent to their architectural references.
    always_ff @(posedge clk) begin
        if (rst_n && (id_ready_go !== id_ready_go_reference))
            $fatal(1, "Timing-factored id_ready_go changed pipeline handshake");
        if (rst_n && (ex_allowin !== ex_allowin_reference))
            $fatal(1, "Timing-factored ex_allowin changed pipeline handshake");
        if (rst_n && (id_allowin !== id_allowin_reference))
            $fatal(1, "Timing-factored id_allowin changed pipeline handshake");
        if (rst_n && (id_to_ex_fire !== id_to_ex_fire_reference))
            $fatal(1, "Timing-factored ID-to-EX fire changed pipeline handshake");
        if (rst_n && id_to_ex_fire
                  && ((id_alu_src1 !== id_alu_src1_reference)
                      || (id_alu_src2 !== id_alu_src2_reference)))
            $fatal(1, "Slot-0 parallel ALU source selection changed value");
        if (rst_n && id_to_ex_fire && id_s1_valid
                  && ((id_s1_alu_src1 !== id_s1_alu_src1_reference)
                      || (id_s1_alu_src2 !== id_s1_alu_src2_reference)))
            $fatal(1, "Slot-1 parallel ALU source selection changed value");
        if (rst_n
                  && ((ex_fast_alu_src1_wb_repair
                       !== ex_alu_src1_wb_repair)
                      || (ex_fast_alu_src2_wb_repair
                          !== ex_alu_src2_wb_repair)
                      || (ex_s1_fast_alu_src1_wb_repair
                          !== ex_s1_alu_src1_wb_repair)
                      || (ex_s1_fast_alu_src2_wb_repair
                          !== ex_s1_alu_src2_wb_repair)))
            $fatal(1, "Fast ALU repair tags changed ID/EX state");
        if (rst_n
                  && ((ex_fast_alu_src1 !== ex_alu_src1_repair)
                      || (ex_fast_alu_src2 !== ex_alu_src2_repair)
                      || (ex_s1_fast_alu_src1 !== ex_s1_alu_src1_repair)
                      || (ex_s1_fast_alu_src2 !== ex_s1_alu_src2_repair)))
            $fatal(1, "Fast ALU repair operands changed value");
        if (rst_n && ex_fast_alu_forward
                  && (alu_result !== ex_forward_result))
            $fatal(1, "Fast EX ALU forwarding candidate changed value");
        if (rst_n && id_mul_prestart
                  && u_forwarding.mul_launch_ex_raw_hazard)
            $fatal(1, "MUL launched across an EX RAW interlock");
        if (rst_n && id_mul_prestart
                  && ((mul_fwd_rs1_data !== fwd_rs1_data)
                      || (mul_fwd_rs2_data !== fwd_rs2_data)))
            $fatal(1, "MUL forwarding copy disagrees with architectural forwarding");
        if (rst_n && ex_valid && ex_is_muldiv && !ex_muldiv_op[2]
                  && (ex_alu_src1_wb_repair | ex_alu_src2_wb_repair))
            $fatal(1, "MUL entered EX with an unsupported WB-repair tag");
        if (rst_n && mem_valid && mem_is_mul && !muldiv_done)
            $fatal(1, "MEM MUL token is not aligned with registered result");
        if (rst_n && muldiv_done
                  && !((mem_valid && mem_is_mul)
                       || (ex_valid && ex_is_muldiv && ex_muldiv_op[2])))
            $fatal(1, "Completed MulDiv result has no matching pipeline owner");
    end
`endif

    bitmanip_unit u_bitmanip_unit (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (ex_bitmanip_req),
        .req_op    (ex_bitmanip_op),
        .req_rs1   (ex_alu_src1_repair),
        .req_rs2   (ex_alu_src2_repair),
        .consume   (bitmanip_consume),
        .flush     (bitmanip_flush),
        .busy      (bitmanip_busy),
        .done      (bitmanip_done),
        .result    (bitmanip_result)
    );

    // ==================== Minimal M-mode CSR / Trap ====================
    csr_trap_unit u_csr_trap_unit (
        .clk               (clk),
        .rst_n             (rst_n),
        .ex_valid          (ex_valid),
        .ex_ready_go       (ex_ready_go_w),
        .mem_allowin       (mem_allowin),
        .mem_branch_flush  (mem_branch_flush),
        .ex_redirect_fire  (ex_redirect_fire),
        .ex_pc             (ex_pc),
        .ex_rs1_data       (ex_rs1_data),
        .ex_rs1_addr       (ex_rs1_addr),
        .ex_is_csr         (ex_is_csr),
        .ex_csr_uses_imm   (ex_csr_uses_imm),
        .ex_csr_cmd        (ex_csr_cmd),
        .ex_csr_addr       (ex_csr_addr),
        .ex_is_ecall       (ex_is_ecall),
        .ex_is_mret        (ex_is_mret),
        .timer_irq_pending (timer_irq_pending),
        .timer_irq_take    (timer_irq_take),
        .timer_irq_mepc    (id_pc),
        .ex_system_inst    (ex_system_inst),
        .ex_system_redirect(ex_system_redirect),
        .ex_system_target  (ex_system_target),
        .timer_irq_request (timer_irq_request),
        .timer_irq_redirect(timer_irq_redirect),
        .timer_irq_target  (timer_irq_target),
        .ex_csr_rdata      (ex_csr_rdata)
    );

    // Slot 0 branch_unit checks prediction correctness; Slot 1 redirect is
    // handled in ex_stage_ctrl because it has separate younger-slot priority.
    branch_unit u_branch_unit (
        .target_pc        (ex_control_target),
        .fallthrough_pc   (ex_pc_plus_4),
        .rs1_data         (ex_rs1_data_repair),
        .rs2_data         (ex_rs2_data_repair),
        .is_branch        (ex_is_branch),
        .branch_cond      (ex_branch_cond),
        .is_jal           (ex_is_jal),
        .is_jalr          (ex_is_jalr),
        .ex_valid         (ex_valid),
        .predicted_taken  (ex_pred_taken),
        .predicted_target (ex_pred_target),
        .branch_flush     (branch_flush),
        .branch_target    (branch_target),
        .actual_taken     (actual_taken),
        .actual_target    (actual_target)
    );

    // Store interface (EX stage -> DCache)
    mem_interface u_mem_interface (
        // Store side (EX stage)
        .store_valid     (ex_valid),
        .store_en        (ex_mem_write_en),
        .store_addr_low  (ex_store_addr_low),
        .store_mem_size  (ex_mem_size),
        .store_data_in   (ex_rs2_data_repair),
        .store_wea       (dram_wea),
        .store_data_out  (),
        // Shared load side (MEM stage, single LSU)
        .load_en         (mem_selected_load_en),
        .load_addr_low   (mem_selected_load_addr_low),
        .load_mem_size   (mem_selected_load_size),
        .load_unsigned   (mem_selected_load_unsigned),
        .load_dram_dout  (mem_load_data),
        .load_data_out   (mem_load_data_ext)
    );

    // Same-pair Slot 0 ALU forwarding is younger than every ordinary
    // forwarding/WB-repair source captured for Slot 1, so it has priority.
    // Carry only raw data across the EX and cache request boundaries; DCache
    // and MMIO perform byte-lane alignment after their pipeline register.
    assign ex_s1_store_data_raw = ex_s0_alu_store_data_bypass_r
                                ? alu_result
                                : ex_s1_rs2_data_repair;

    mem_interface u_mem_interface_s1_load (
        // Store side (EX stage, shares the single LSU when Slot0 is non-LSU)
        .store_valid     (ex_s1_valid),
        .store_en        (ex_s1_mem_write_en),
        .store_addr_low  (ex_s1_store_addr_low),
        .store_mem_size  (ex_s1_mem_size),
        .store_data_in   (ex_s1_store_data_raw),
        .store_wea       (dram_wea_s1),
        .store_data_out  (),
        // Load formatting is shared by the Slot0 instance above.
        .load_en         (1'b0),
        .load_addr_low   (2'd0),
        .load_mem_size   (2'd0),
        .load_unsigned   (1'b0),
        .load_dram_dout  (32'd0),
        .load_data_out   ()
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && ex_valid && ex_mem_write_en
                  && (ex_store_addr_low !== alu_addr[1:0]))
            $fatal(1, "Slot0 store low-address adder disagrees with full address");
        if (rst_n && ex_s1_valid && ex_s1_mem_write_en
                  && (ex_s1_store_addr_low !== alu_s1_addr[1:0]))
            $fatal(1, "Slot1 store low-address adder disagrees with full address");
        if (rst_n && ex_s1_valid
                  && ex_s0_alu_store_data_bypass_r) begin
            if (!(ex_valid && ex_reg_write_en && (ex_rd != 5'd0)
                  && ex_s1_mem_write_en && (ex_s1_rs2_addr == ex_rd)
                  && (ex_s1_rs1_addr != ex_rd)
                  && !ex_mem_read_en && !ex_mem_write_en
                  && !ex_is_csr && !ex_is_muldiv && !ex_is_bitmanip))
                $fatal(1, "Invalid Slot0-ALU to Slot1-store-data bypass tag");
            if (ex_s1_store_data_raw !== alu_result)
                $fatal(1, "Slot1 store-data bypass did not select Slot0 ALU result");
        end
    end
`endif

    // ==================== EX/MEM ====================

    ex_mem_payload_builder u_ex_mem_payload_builder (
        .redirect_valid  (ex_registered_branch_flush),
        .redirect_target (ex_registered_branch_target),
        .s0_alu_result   (ex_pipe_alu_result),
        .s0_pc           (ex_pc),
        .s0_pc_plus_4    (ex_pc_plus_4),
        .s0_rd           (ex_rd),
        .s0_reg_write_en (ex_reg_write_en),
        .s0_wb_sel       (ex_wb_sel),
        .s0_is_mul       (ex_is_muldiv & ~ex_muldiv_op[2]),
        .s0_mem_read_en  (ex_mem_read_en),
        .s0_mem_size     (ex_mem_size),
        .s0_mem_unsigned (ex_mem_unsigned),
        .s0_store_wea    (dram_wea),
        .s0_store_data   (ex_rs2_data_repair),
        .s0_is_cacheable (is_cacheable),
        .s1_pc           (ex_s1_pc),
        .s1_inst         (ex_s1_inst),
        .s1_alu_result   (alu_s1_result),
        .s1_pc_plus_4    (ex_s1_pc_plus_4),
        .s1_rd           (ex_s1_rd),
        .s1_reg_write_en (ex_s1_reg_write_en),
        .s1_wb_sel       (ex_s1_wb_sel),
        .s1_mem_read_en  (ex_s1_mem_read_en),
        .s1_mem_write_en (ex_s1_mem_write_en),
        .s1_mem_size     (ex_s1_mem_size),
        .s1_mem_unsigned (ex_s1_mem_unsigned),
        .s1_store_wea    (dram_wea_s1),
        .s1_store_data   (ex_s1_store_data_raw),
        .s1_is_cacheable (is_cacheable_s1),
        .redirect        (ex_mem_redirect),
        .slot0_payload   (ex_mem_s0_payload),
        .slot1_payload   (ex_mem_s1_payload)
    );

    ex_mem_reg u_ex_mem_reg (
        .clk              (clk),
        .rst_n            (rst_n),
        .ex_valid         (ex_valid),
        .ex_ready_go      (ex_ready_go_w),
        .mem_allowin      (mem_allowin),
        .mem_valid        (mem_valid),
        .mem_ready_go     (mem_ready_go_w),
        .wb_allowin       (wb_allowin),
        .ex_redirect      (ex_mem_redirect),
        .mem_redirect     (mem_redirect),
        .ex_payload       (ex_mem_s0_payload),
        .mem_payload      (mem_s0_payload)
    );

    ex_mem_reg_s1 u_ex_mem_reg_s1 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .ex_s1_valid         (ex_s1_valid),
        .ex_ready_go         (ex_ready_go_w),
        .mem_allowin         (mem_allowin),
        .ex_branch_flush     (branch_flush),
        .mem_branch_flush    (mem_branch_flush),
        .mem_s1_valid        (mem_s1_valid),
        .ex_payload          (ex_mem_s1_payload),
        .mem_payload         (mem_s1_payload)
    );

    // ==================== MEM/WB ====================

    mem_wb_payload_builder u_mem_wb_payload_builder (
        .s0_alu_result   (mem_wb_alu_result),
        .s0_pc_plus_4    (mem_pc_plus_4),
        .s0_rd           (mem_rd),
        .s0_reg_write_en (mem_reg_write_en),
        .s0_wb_sel       (mem_wb_sel),
        .s0_is_load      (mem_mem_read_en),
        .s0_load_data    (mem_load_data_ext),
        .s1_pc           (mem_s1_pc),
        .s1_inst         (mem_s1_inst),
        .s1_alu_result   (mem_s1_alu_result),
        .s1_pc_plus_4    (mem_s1_pc_plus_4),
        .s1_rd           (mem_s1_rd),
        .s1_reg_write_en (mem_s1_reg_write_en),
        .s1_wb_sel       (mem_s1_wb_sel),
        .s1_is_load      (mem_s1_mem_read_en),
        .slot0_payload   (mem_wb_s0_payload),
        .slot1_payload   (mem_wb_s1_payload)
    );

    mem_wb_reg u_mem_wb_reg (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_valid      (mem_valid),
        .mem_ready_go   (mem_ready_go_w),
        .wb_allowin     (wb_allowin),
        .wb_valid       (wb_valid),
        .mem_load_valid (mem_load_valid),
        .mem_payload    (mem_wb_s0_payload),
        .wb_payload     (wb_s0_payload),
        .wb_load_data_ex(wb_load_data_ex)
    );

    mem_wb_reg_s1 u_mem_wb_reg_s1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .mem_s1_valid  (mem_s1_valid),
        .mem_ready_go  (mem_ready_go_w),
        .wb_allowin    (wb_allowin),
        .mem_payload   (mem_wb_s1_payload),
        .wb_s1_valid   (wb_s1_valid),
        .wb_payload    (wb_s1_payload)
    );

    // ==================== WB stage ====================

    wb_mux u_wb_mux (
        .wb_alu_result (wb_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc_plus_4  (wb_pc_plus_4),
        .wb_sel        (wb_wb_sel),
        .wb_write_data (wb_write_data)
    );

    wb_mux u_wb_mux_s1 (
        .wb_alu_result (wb_s1_alu_result),
        .wb_load_data  (wb_load_data),
        .wb_pc_plus_4  (wb_s1_pc_plus_4),
        .wb_sel        (wb_s1_wb_sel),
        .wb_write_data (wb_s1_write_data)
    );

endmodule

`ifdef CPU_TOP_ABTB_OBSERVE
`undef CPU_TOP_ABTB_OBSERVE
`endif
