// ============================================================
// Module: frontend_f0_packet_builder
// Description: 
// 这个模块的输入包括64bit取指包、pc、预测元数据(用于预测器训练和重定向，我喜欢称之为metadata)。
// 它的输出包括将发送到fq的元数据和一些解码信息(坦白说，它不应该被称为fq，因为它已经有了指令)。
// Domain: frontend.
//TODO 结构体信号是否冗余的问题仍有待商榷
// ============================================================

module frontend_f0_packet_builder
    import cpu_defs::*;
(
    // IROM ins fetch
    input  logic                       accept_base, // valid信号
    input  logic [31:0]                start_pc, // 64bit指令包中第一条指令对应的PC
    //* base_mask可以用start_pc[2]直接代替,并且我们在start_pc[2] = 1时slot1中已经有了NOP指令,所以我们不需要使用这个信号来控制slot1的valid。
    input  logic [ 1:0]                base_mask, // if pc[2] = 0, base_mask = 2'b11, else base_mask = 2'b01
    input  logic [63:0]                irom_data, // PC[2:0] = 0取出来的64bit指令包

    // pred metadata
    input  logic                       steer_taken, // 第一级预测器的预测结果为taken时为1,否则为0
    input  logic                       steer_source_abtb, // 该信号拉高表示预测结果来自ABTB,用于后续的预测器训练
    input  logic                       steer_bank, // 预测结果所在的bank
    input  logic [ 1:0]                steer_cfi_type, // 控制流指令的类型 00: not cfi, 01: branch, 10: jal, 11: jalr
    input  logic [31:0]                steer_target, // 预测器提供的预测地址(不包含PC+4的情况)
    //* 为什么我们要搞一个只有三个信号的结构体？
    //* 这个branch_owned信号显然冗余了，需要删掉。其实这个brranch_owned信号是用来告诉我们这个预测结果是否来自ABTB的branch entry,但是我们已经有了steer_source_abtb信号来告诉我们这个信息了，同时所以这个信号是冗余的。
    input  frontend_f0_bank_meta_t     bank0_meta, // 包含pht的counter，index和branch_owned信号。
    input  frontend_f0_bank_meta_t     bank1_meta,

    //* enq0_payload和enq0_valid本质是同一个信号，可以考虑删减，没什么区别。
    output logic                       enq0_payload, // enq0_payload = accept_base && base_mask[0]
    output logic                       enq1_payload,
    //? 这里如果slot1是valid并且slot0禁止slot1发射，那slot1是如何被保留下来的？具体逻辑是怎样的？
    output logic                       enq0_valid,
    output logic                       enq1_valid,
    //? 现在我们一旦将slot0预测为跳转，会导致slot1直接被flush掉。但是我们为什么不开放这种双发射，来获得一些可能性的收益并减轻资源占用呢？
    //? 如果我们允许这种双发射，那system指令是否应该被加入双发射逻辑中？
    //! 在决定对这个双发射逻辑进行修改之前，请确保这条slot1不会引起各种边界情况(例如错误的DRAM访问，或者是其他情况)
    output logic                       kill_after_slot0, // slot0被预测为跳转/确实是跳转时拉高，用于对slot1的指令进行冲刷
    output frontend_fq_entry_t         entry0, // 这个结构体包含了fq entry需要的所有信息。
    output frontend_fq_entry_t         entry1,
    output frontend_pair_meta_t        pair_meta0,
    output frontend_pair_meta_t        pair_meta1
);

    // 如果取指时PC[2]=1，则将slot1作为NOP进行发射。
    // 这个操作是与跳转无关的，改kill_after_slot0的时候不要误伤了
    //? 看起来我们用了两个fifo来实现fq，这样做的好处是什么？用一个fifo会不会更好？
    wire [31:0] slot0_inst = start_pc[2] ? irom_data[63:32]
                                          : irom_data[31:0];
    wire [31:0] slot1_inst = start_pc[2] ? 32'h0000_0013
                                          : irom_data[63:32];
    wire [31:0] slot0_pc = start_pc;
    wire [31:0] slot1_pc = start_pc + 32'd4;

    frontend_predecode_t slot0_dec;
    frontend_predecode_t slot1_dec;
    logic slot0_system_redirect;
    logic slot0_branch_owned;
    logic slot1_branch_owned;
    logic slot0_pred_taken;
    logic [31:0] slot0_pred_target;
    logic slot0_pred_source_abtb;
    logic slot1_pred_taken;
    logic [31:0] slot1_pred_target;
    logic slot1_pred_source_abtb;
    logic [7:0] slot0_pht_index;
    logic [1:0] slot0_pht_counter;

    // 两个预译码单元，使用cpu_def中的结构体作为output格式
    frontend_predecode u_predecode_slot0 (
        .inst    (slot0_inst),
        .decoded (slot0_dec)
    );

    frontend_predecode u_predecode_slot1 (
        .inst    (slot1_inst),
        .decoded (slot1_dec)
    );

    // 这个结构体包含了fq entry需要的所有信息。
    function automatic frontend_fq_entry_t make_entry(
        input logic                  valid,
        input logic [31:0]           pc,
        input logic [31:0]           inst,
        //? 为什么要存decode信息？
        input frontend_predecode_t   decoded,
        input logic                  force_single,
        input logic                  pred_taken,
        input logic [31:0]           pred_target,
        input logic                  pred_source_abtb,
        input logic                  branch_owned,
        input logic [1:0]            final_cfi_type,
        input logic [7:0]            pht_index,
        input logic [1:0]            pht_counter
    );
        begin
            make_entry = '0;
            make_entry.valid = valid;
            make_entry.pc = pc;
            make_entry.inst = inst;
            make_entry.pred_taken = pred_taken;
            make_entry.pred_target = pred_target;
            make_entry.pred_source_abtb = pred_source_abtb;
            make_entry.stage1_branch_owned = branch_owned;
            // 需要改成并行逻辑
            make_entry.pred_cfi_type = branch_owned
                                     ? ABTB_TYPE_BRANCH
                                     : pred_taken
                                     ? final_cfi_type
                                     : 2'd0;
            make_entry.stage1_pht_index = pht_index;
            make_entry.stage1_pht_counter = pht_counter;
            make_entry.is_branch = decoded.is_branch;
            make_entry.is_jal = decoded.is_jal;
            make_entry.is_jalr = decoded.is_jalr;
            make_entry.is_system = decoded.is_system;
            make_entry.is_fence = decoded.is_fence;
            make_entry.is_illegal = decoded.is_illegal;
            make_entry.is_muldiv = decoded.is_muldiv;
            make_entry.is_load = decoded.is_load;
            make_entry.is_store = decoded.is_store;
            make_entry.is_alu_type = decoded.is_alu_type;
            make_entry.writes_rd = decoded.writes_rd;
            make_entry.uses_rs1 = decoded.uses_rs1;
            make_entry.uses_rs2 = decoded.uses_rs2;
            make_entry.is_jump = decoded.is_jump;
            make_entry.is_control = decoded.is_control;
            make_entry.is_lsu = decoded.is_lsu;
            make_entry.force_single = force_single;
        end
    endfunction

    // 预译码信息。
    function automatic frontend_pair_meta_t make_pair_meta(
        input logic [31:0]         inst,
        input frontend_predecode_t decoded, // 包含了指令的类型信息和寄存器使用信息，以及指令是否需要单独发射的信息。
        input logic                pred_taken,
        input logic                force_single
    );
        begin
            make_pair_meta = '0;
            make_pair_meta.pred_taken = pred_taken;
            make_pair_meta.force_single = force_single;
            make_pair_meta.is_alu_type = decoded.is_alu_type;
            make_pair_meta.is_lsu = decoded.is_lsu;
            make_pair_meta.is_cfi = decoded.is_cfi;
            make_pair_meta.writes_rd = decoded.writes_rd;
            make_pair_meta.uses_rs1 = decoded.uses_rs1;
            make_pair_meta.uses_rs2 = decoded.uses_rs2;
            make_pair_meta.rd = inst[11:7];
            make_pair_meta.rs1 = inst[19:15];
            make_pair_meta.rs2 = inst[24:20];
        end
    endfunction

    // 计算给两个make_entry用的信息，没细看
    always_comb begin
        slot0_system_redirect =
            slot0_dec.is_system && (slot0_inst[14:12] == 3'b000);
        slot0_branch_owned =
            slot0_dec.is_branch
            && (start_pc[2] ? bank1_meta.branch_owned
                            : bank0_meta.branch_owned);
        slot1_branch_owned =
            slot1_dec.is_branch && !start_pc[2] && bank1_meta.branch_owned;

        slot0_pred_taken = steer_taken && (steer_bank == start_pc[2]);
        slot0_pred_target =
            slot0_pred_taken ? steer_target : (slot0_pc + 32'd4);
        slot0_pred_source_abtb = slot0_pred_taken && steer_source_abtb;
        slot1_pred_taken = steer_taken && !start_pc[2] && steer_bank;
        slot1_pred_target = slot1_pred_taken ? steer_target : 32'd0;
        slot1_pred_source_abtb = slot1_pred_taken && steer_source_abtb;

        if (start_pc[2]) begin
            slot0_pht_index = bank1_meta.pht_index;
            slot0_pht_counter = bank1_meta.pht_counter;
        end else begin
            slot0_pht_index = bank0_meta.pht_index;
            slot0_pht_counter = bank0_meta.pht_counter;
        end

        // 当slot0被预测为跳转/确实是跳转的时候，对slot1的指令进行冲刷。
        kill_after_slot0 =
            slot0_dec.is_jal
            || slot0_dec.is_jalr
            || slot0_system_redirect
            || slot0_pred_taken;
        enq0_payload = accept_base && base_mask[0];
        enq1_payload = accept_base && base_mask[1];
        enq0_valid = enq0_payload;
        enq1_valid = enq1_payload && !kill_after_slot0;

        // 结构体内包含了fq entry需要的所有信息。
        entry0 = make_entry(
            enq0_valid, // valid
            slot0_pc, // pc
            slot0_inst, // inst
            slot0_dec, // frontend_predecode_t decoded
            slot0_dec.force_single_slot0, // force_single
            slot0_pred_taken, // pred_taken
            slot0_pred_target, // pred_target
            slot0_pred_source_abtb, // pred_source_abtb
            slot0_branch_owned, // branch_owned
            steer_cfi_type, // final_cfi_type
            slot0_pht_index, // pht_index
            slot0_pht_counter // pht_counter
        );
        entry1 = make_entry(
            enq1_valid,
            slot1_pc,
            slot1_inst,
            slot1_dec,
            slot1_dec.force_single_slot1,
            slot1_pred_taken,
            slot1_pred_target,
            slot1_pred_source_abtb,
            slot1_branch_owned,
            steer_cfi_type,
            //* 这他妈放一段结构体是什么意思
            bank1_meta.pht_index,
            bank1_meta.pht_counter
        );

        // 预译码信息。
        pair_meta0 = make_pair_meta(
            slot0_inst, // inst
            slot0_dec, // frontend_predecode_t decoded
            slot0_pred_taken, // pred_taken
            slot0_dec.force_single_slot0 // force_single
        );
        pair_meta1 = make_pair_meta(
            slot1_inst,
            slot1_dec,
            slot1_pred_taken,
            slot1_dec.force_single_slot1
        );
    end

endmodule
