function logic has_d2 (input word_t inst);
    unique case (opcode_t'(ext_opcode(inst)))
        OP_IMM, OP_LUI, OP_AUIPC, OP_JAL: has_d2 = 0;
        default: has_d2 = 1;
    endcase
endfunction

module core
#(
    parameter int NUMREGS=32,
    localparam WDATA = 32,
    localparam WPTR = 32,
    localparam WSHAM = 5,
    localparam WRFI = $clog2(NUMREGS)
) (
    input logic clk,
    input logic rst,

    output logic rf_wren,
    output logic[WRFI-1:0]  regnum,
    input  logic[WDATA-1:0] rfread_data,
    output logic[WDATA-1:0] rfwrite_data,

    output logic mem_wren,
    output logic[WPTR-1:0]  mem_addr,
    output mem_addr_t mem_size,
    input  logic[WDATA-1:0] memread_data,
    output logic[WDATA-1:0] memwrite_data
);
    logic[WPTR-1:0] pc;
    logic[WPTR-1:0] pc_next;
    cycle_t cycle;
    word_t inst;
    word_t rs1;
    word_t rs2;
    word_t saved_addr; // lsu address and branch target
    mem_addr_t saved_mem_size;
    regnum_t loadrd;
    reg is_load;
    reg is_store;

    wire is_loadstore = is_load | is_store;
    wire sig_has_d2 = has_d2(inst);

    opcode_t opcode;
    assign opcode = ext_opcode(inst);

    // state variables
    always_ff @(posedge clk) begin
        // reset
        if (rst) begin
            pc_next  <= `PC_INIT;
            cycle    <= `CYCLE_INIT;
            inst     <= `INST_INIT;
            is_load  <= 0;
            is_store <= 0;
        end else unique case (cycle)
            D1: begin
                cycle <= sig_has_d2 ? D2 : EX;
                pc_next <= adder_out; // garbage for jalr
                is_load <= opcode == OP_LOAD;
                is_store <= opcode == OP_STORE;
                if (opcode == OP_EBREAK)
                    cycle <= D1;
            end
            D2: begin
                cycle <= EX;
                unique case (opcode)
                    OP_JALR: pc_next <= adder_out;
                    OP_LOAD, OP_STORE: begin
                        loadrd <= (is_load)? ext_rd(inst) : 0;
                        inst <= memread_data;
                        saved_addr <= adder_out;
                        saved_mem_size <= mem_addr_t'(ext_f3(inst));
                    end
                    OP_BRANCH: saved_addr <= adder_out;
                endcase
            end
            EX: begin // cannot read opcode for load/store
                if (is_loadstore) begin
                    cycle <= D1;
                    pc <= pc_next;
                    is_load <= 0;
                    is_store <= 0;
                end else if (opcode == OP_BRANCH) begin
                    cycle <= BR;
                    pc_next <= alu_out[0] ? saved_addr : pc_next;
                end else begin
                    cycle <= D1;
                    pc <= pc_next;
                    inst <= memread_data;
                end
            end
            BR: begin
                cycle <= D1;
                pc <= pc_next;
                inst <= memread_data;
            end
        endcase
    end

    adderOp_t adder_op;
    word_t adder_a, adder_b, adder_out;

    // adder_op
    always_comb begin
        adder_op = ADDER_ADD;
        if (cycle==EX) begin
            unique case (opcode)
                OP_OP, OP_IMM: begin
                    unique case (ext_f3(inst))
                        FUNC_ADDSUB: adder_op = ext_arith_bit(inst)? ADDER_SUB: ADDER_ADD;
                        FUNC_SLT:    adder_op = ADDER_LT;
                        FUNC_SLTU:   adder_op = ADDER_LTU;
                    endcase
                end
                OP_BRANCH: adder_op = branch_t'(ext_f3(inst));
            endcase
        end
    end

    // adder_a / adder_b
    always_comb begin
        adder_a = 'X;
        adder_b = 'X;
        unique case (cycle)
            D1: begin // junk for jalr
                adder_a = pc;
                adder_b = (opcode == OP_JAL)? ext_j_imm(inst) : 4;
            end
            D2: begin
                unique case (opcode)
                    OP_JALR, OP_LOAD: begin
                        adder_a = rs1;
                        adder_b = ext_i_imm(inst);
                    end
                    OP_STORE: begin
                        adder_a = rs1;
                        adder_b = ext_s_imm(inst);
                    end
                    OP_BRANCH: begin
                        adder_a = pc;
                        adder_b = ext_b_imm(inst);
                    end
                endcase
            end
            EX: begin if (!is_loadstore)
                unique case (opcode)
                    OP_OP, OP_BRANCH: begin
                        adder_a = rs1;
                        adder_b = rs2;
                    end
                    OP_IMM : begin
                        adder_a = rs1;
                        adder_b = ext_i_imm(inst);
                    end
                    OP_AUIPC: begin
                        adder_a = pc;
                        adder_b = ext_u_imm(inst);
                    end
                    OP_JAL, OP_JALR: begin
                        adder_a = pc;
                        adder_b = 4;
                    end
                endcase
            end
        endcase
    end

    logic adder_cout;
    adder #(.WIDTH(WDATA)) a(adder_op, adder_a, adder_b, adder_out, adder_cout);

    wire sig_sr = opFunc_t'(ext_f3(inst)) == FUNC_SR;
    wire sig_sa = ext_arith_bit(inst);
    wire[WSHAM-1:0] sham = (opcode == OP_OP)? rs2 : ext_i_imm(inst);
    word_t shifter_out;
    shifter #(.WIDTH(WDATA), .SBITS($clog2(WDATA)), .BIAS(0)) sh(rs1, sham, sig_sr, sig_sa, shifter_out);

    word_t alu_out;
    always_comb begin
        alu_out = adder_out;
        if (cycle == EX & !is_loadstore)
            unique case (opcode)
                OP_OP, OP_IMM: unique case (ext_f3(inst))
                    FUNC_SLL, FUNC_SR: alu_out = shifter_out;
                    FUNC_XOR: alu_out = adder_a ^ adder_b;
                    FUNC_AND: alu_out = adder_a & adder_b;
                    FUNC_OR:  alu_out = adder_a | adder_b;
                endcase
                OP_LUI: alu_out = ext_u_imm(inst);
            endcase
    end

    // regfile read/write
    always_comb begin
        regnum = 'X;
        rfwrite_data = 'X;
        unique case (cycle)
            D1, D2: begin
                rf_wren = 0;
                regnum = (cycle == D1)? ext_rs1(inst) : ext_rs2(inst); // junk for jalr
            end
            EX: begin
                if (is_loadstore) begin
                    rf_wren = is_load;
                    regnum = loadrd;
                    rfwrite_data = memread_data;
                end else begin
                    rf_wren = (opcode != OP_BRANCH);
                    regnum = ext_rd(inst);
                    rfwrite_data = alu_out;
                end
            end
            BR: begin
                rf_wren = 0;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        unique case (cycle)
            D1: rs1 <= rfread_data;
            D2: rs2 <= rfread_data;
        endcase
    end

    always_comb begin
        memwrite_data = rs2;
        mem_addr = pc_next;
        mem_wren = 0;
        mem_size = MEM_W;
        if (cycle == EX & is_loadstore) begin
            mem_wren = is_store;
            mem_addr = saved_addr;
            mem_size = saved_mem_size;
        end 
        if (cycle == D1 && opcode == OP_EBREAK) begin
            mem_wren = 1;
            mem_addr = 32'h8000000;
            mem_size = MEM_W;
            memwrite_data = 32'hffffffff;
        end
    end
endmodule