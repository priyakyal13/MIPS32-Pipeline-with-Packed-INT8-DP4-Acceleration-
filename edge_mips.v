`timescale 1ns/1ps

// EdgeMIPS
// --------
// A compact 32-bit MIPS-like five-stage pipeline with:
//   * single-edge clocking
//   * forwarding (EX/MEM -> EX and MEM/WB -> EX)
//   * one-cycle load-use hazard stalls
//   * branch flushing for BEQZ/BNEQZ
//   * custom packed INT8 dot-product instruction DP4
//   * simple hardware performance counters
//
// The project intentionally keeps the architecture small and readable.

module edge_mips(
    input         clk,
    input         reset,
    output        halted,
    output [31:0] cycle_count,
    output [31:0] instruction_count,
    output [31:0] stall_count,
    output [31:0] dp4_count
);

    // ------------------------------------------------------------------
    // Instruction set (6-bit opcode, same field layout as the original
    // Pipeline-Verilog project).
    // ------------------------------------------------------------------
    localparam [5:0] OP_ADD   = 6'b000000;
    localparam [5:0] OP_SUB   = 6'b000001;
    localparam [5:0] OP_AND   = 6'b000010;
    localparam [5:0] OP_OR    = 6'b000011;
    localparam [5:0] OP_SLT   = 6'b000100;
    localparam [5:0] OP_MUL   = 6'b000101;
    localparam [5:0] OP_LW    = 6'b001000;
    localparam [5:0] OP_SW    = 6'b001001;
    localparam [5:0] OP_ADDI  = 6'b001010;
    localparam [5:0] OP_SUBI  = 6'b001011;
    localparam [5:0] OP_SLTI  = 6'b001100;
    localparam [5:0] OP_BNEQZ = 6'b001101;
    localparam [5:0] OP_BEQZ  = 6'b001110;
    localparam [5:0] OP_DP4   = 6'b010000; // custom Edge-AI instruction
    localparam [5:0] OP_HLT   = 6'b111111;

    // ------------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------------
    reg [31:0] pc;
    reg [31:0] regs [0:31];
    reg [31:0] instr_mem [0:1023];
    reg [31:0] data_mem  [0:1023];
    reg        halted_r;

    assign halted = halted_r;

    // ------------------------------------------------------------------
    // IF/ID pipeline register
    // ------------------------------------------------------------------
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    // ------------------------------------------------------------------
    // ID/EX pipeline register
    // ------------------------------------------------------------------
    reg        id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [5:0]  id_ex_opcode;
    reg [4:0]  id_ex_rs;
    reg [4:0]  id_ex_rt;
    reg [4:0]  id_ex_rd;
    reg [31:0] id_ex_a;
    reg [31:0] id_ex_b;
    reg [31:0] id_ex_imm;
    reg        id_ex_regwrite;
    reg        id_ex_memread;
    reg        id_ex_memwrite;
    reg        id_ex_memtoreg;
    reg        id_ex_branch;
    reg        id_ex_branch_ne;
    reg        id_ex_halt;
    reg        id_ex_dp4;

    // ------------------------------------------------------------------
    // EX/MEM pipeline register
    // ------------------------------------------------------------------
    reg        ex_mem_valid;
    reg [31:0] ex_mem_alu_out;
    reg [31:0] ex_mem_store_data;
    reg [4:0]  ex_mem_dest;
    reg        ex_mem_regwrite;
    reg        ex_mem_memread;
    reg        ex_mem_memwrite;
    reg        ex_mem_memtoreg;
    reg        ex_mem_halt;
    reg        ex_mem_branch_taken;
    reg [31:0] ex_mem_branch_target;
    reg        ex_mem_dp4;

    // ------------------------------------------------------------------
    // MEM/WB pipeline register
    // ------------------------------------------------------------------
    reg        mem_wb_valid;
    reg [31:0] mem_wb_alu_out;
    reg [31:0] mem_wb_mem_data;
    reg [4:0]  mem_wb_dest;
    reg        mem_wb_regwrite;
    reg        mem_wb_memtoreg;
    reg        mem_wb_halt;
    reg        mem_wb_dp4;

    // ------------------------------------------------------------------
    // Performance counters
    // ------------------------------------------------------------------
    reg [31:0] cycle_count_r;
    reg [31:0] instruction_count_r;
    reg [31:0] stall_count_r;
    reg [31:0] dp4_count_r;

    assign cycle_count       = cycle_count_r;
    assign instruction_count = instruction_count_r;
    assign stall_count       = stall_count_r;
    assign dp4_count         = dp4_count_r;

    // ------------------------------------------------------------------
    // Decode helpers for the instruction currently in IF/ID.
    // ------------------------------------------------------------------
    wire [5:0] id_opcode = if_id_instr[31:26];
    wire [4:0] id_rs     = if_id_instr[25:21];
    wire [4:0] id_rt     = if_id_instr[20:16];
    wire [4:0] id_rd     = if_id_instr[15:11];
    wire [31:0] id_imm   = {{16{if_id_instr[15]}}, if_id_instr[15:0]};

    wire id_is_rtype = (id_opcode == OP_ADD) || (id_opcode == OP_SUB) ||
                       (id_opcode == OP_AND) || (id_opcode == OP_OR)  ||
                       (id_opcode == OP_SLT) || (id_opcode == OP_MUL);

    wire id_uses_rs = id_is_rtype || (id_opcode == OP_DP4) ||
                      (id_opcode == OP_LW) || (id_opcode == OP_SW) ||
                      (id_opcode == OP_ADDI) || (id_opcode == OP_SUBI) ||
                      (id_opcode == OP_SLTI) || (id_opcode == OP_BEQZ) ||
                      (id_opcode == OP_BNEQZ);

    wire id_uses_rt = id_is_rtype || (id_opcode == OP_DP4) ||
                      (id_opcode == OP_SW);

    // ------------------------------------------------------------------
    // Load-use hazard detection.
    // ------------------------------------------------------------------
    wire load_use_hazard = if_id_valid && id_ex_valid && id_ex_memread &&
                           (id_ex_rt != 5'd0) &&
                           ((id_uses_rs && (id_rs == id_ex_rt)) ||
                            (id_uses_rt && (id_rt == id_ex_rt)));

    // ------------------------------------------------------------------
    // Forwarding for the operands entering EX.
    // 10 = EX/MEM forwarding, 01 = MEM/WB forwarding, 00 = ID/EX value.
    // A load in EX/MEM cannot be forwarded yet because memory is read in
    // the MEM stage, so that path is explicitly excluded.
    // ------------------------------------------------------------------
    reg [1:0] forward_a_sel;
    reg [1:0] forward_b_sel;

    always @(*) begin
        forward_a_sel = 2'b00;
        forward_b_sel = 2'b00;

        // Source A: EX/MEM has priority over MEM/WB.
        if (id_ex_valid && ex_mem_valid && ex_mem_regwrite && !ex_mem_memread &&
            (ex_mem_dest != 5'd0) && (ex_mem_dest == id_ex_rs)) begin
            forward_a_sel = 2'b10;
        end else if (id_ex_valid && mem_wb_valid && mem_wb_regwrite &&
                     (mem_wb_dest != 5'd0) && (mem_wb_dest == id_ex_rs)) begin
            forward_a_sel = 2'b01;
        end

        // Source B: EX/MEM has priority over MEM/WB.
        if (id_ex_valid && ex_mem_valid && ex_mem_regwrite && !ex_mem_memread &&
            (ex_mem_dest != 5'd0) && (ex_mem_dest == id_ex_rt)) begin
            forward_b_sel = 2'b10;
        end else if (id_ex_valid && mem_wb_valid && mem_wb_regwrite &&
                     (mem_wb_dest != 5'd0) && (mem_wb_dest == id_ex_rt)) begin
            forward_b_sel = 2'b01;
        end
    end

    reg [31:0] ex_operand_a;
    reg [31:0] ex_operand_b;

    always @(*) begin
        case (forward_a_sel)
            2'b10: ex_operand_a = ex_mem_alu_out;
            2'b01: ex_operand_a = mem_wb_memtoreg ? mem_wb_mem_data : mem_wb_alu_out;
            default: ex_operand_a = id_ex_a;
        endcase

        case (forward_b_sel)
            2'b10: ex_operand_b = ex_mem_alu_out;
            2'b01: ex_operand_b = mem_wb_memtoreg ? mem_wb_mem_data : mem_wb_alu_out;
            default: ex_operand_b = id_ex_b;
        endcase
    end

    // ------------------------------------------------------------------
    // Custom DP4 arithmetic block.
    // ------------------------------------------------------------------
    wire [31:0] dp4_result;
    dp4_unit u_dp4(
        .a(ex_operand_a),
        .b(ex_operand_b),
        .result(dp4_result)
    );

    // ------------------------------------------------------------------
    // Combinational EX results.
    // ------------------------------------------------------------------
    reg [31:0] ex_alu_result;
    reg         ex_branch_taken;
    reg [31:0]  ex_branch_target;

    always @(*) begin
        ex_alu_result   = 32'd0;
        ex_branch_taken = 1'b0;
        ex_branch_target = id_ex_pc + 32'd1 + id_ex_imm;

        if (id_ex_valid) begin
            case (id_ex_opcode)
                OP_ADD:  ex_alu_result = ex_operand_a + ex_operand_b;
                OP_SUB:  ex_alu_result = ex_operand_a - ex_operand_b;
                OP_AND:  ex_alu_result = ex_operand_a & ex_operand_b;
                OP_OR:   ex_alu_result = ex_operand_a | ex_operand_b;
                OP_SLT:  ex_alu_result = ($signed(ex_operand_a) < $signed(ex_operand_b)) ? 32'd1 : 32'd0;
                OP_MUL:  ex_alu_result = ex_operand_a * ex_operand_b;
                OP_DP4:  ex_alu_result = dp4_result;
                OP_ADDI: ex_alu_result = ex_operand_a + id_ex_imm;
                OP_SUBI: ex_alu_result = ex_operand_a - id_ex_imm;
                OP_SLTI: ex_alu_result = ($signed(ex_operand_a) < $signed(id_ex_imm)) ? 32'd1 : 32'd0;
                OP_LW, OP_SW: ex_alu_result = ex_operand_a + id_ex_imm;
                OP_BEQZ: begin
                    ex_branch_taken = (ex_operand_a == 32'd0);
                end
                OP_BNEQZ: begin
                    ex_branch_taken = (ex_operand_a != 32'd0);
                end
                default: begin
                    ex_alu_result = 32'd0;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Main sequential pipeline.
    // ------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            pc <= 32'd0;
            halted_r <= 1'b0;

            if_id_valid <= 1'b0;
            if_id_pc <= 32'd0;
            if_id_instr <= {OP_HLT, 26'd0};

            id_ex_valid <= 1'b0;
            id_ex_pc <= 32'd0;
            id_ex_opcode <= OP_HLT;
            id_ex_rs <= 5'd0;
            id_ex_rt <= 5'd0;
            id_ex_rd <= 5'd0;
            id_ex_a <= 32'd0;
            id_ex_b <= 32'd0;
            id_ex_imm <= 32'd0;
            id_ex_regwrite <= 1'b0;
            id_ex_memread <= 1'b0;
            id_ex_memwrite <= 1'b0;
            id_ex_memtoreg <= 1'b0;
            id_ex_branch <= 1'b0;
            id_ex_branch_ne <= 1'b0;
            id_ex_halt <= 1'b0;
            id_ex_dp4 <= 1'b0;

            ex_mem_valid <= 1'b0;
            ex_mem_alu_out <= 32'd0;
            ex_mem_store_data <= 32'd0;
            ex_mem_dest <= 5'd0;
            ex_mem_regwrite <= 1'b0;
            ex_mem_memread <= 1'b0;
            ex_mem_memwrite <= 1'b0;
            ex_mem_memtoreg <= 1'b0;
            ex_mem_halt <= 1'b0;
            ex_mem_branch_taken <= 1'b0;
            ex_mem_branch_target <= 32'd0;
            ex_mem_dp4 <= 1'b0;

            mem_wb_valid <= 1'b0;
            mem_wb_alu_out <= 32'd0;
            mem_wb_mem_data <= 32'd0;
            mem_wb_dest <= 5'd0;
            mem_wb_regwrite <= 1'b0;
            mem_wb_memtoreg <= 1'b0;
            mem_wb_halt <= 1'b0;
            mem_wb_dp4 <= 1'b0;

            cycle_count_r <= 32'd0;
            instruction_count_r <= 32'd0;
            stall_count_r <= 32'd0;
            dp4_count_r <= 32'd0;

            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'd0;
            for (i = 0; i < 1024; i = i + 1) begin
                instr_mem[i] <= 32'hFC000000; // HLT
                data_mem[i] <= 32'd0;
            end
        end else if (!halted_r) begin
            cycle_count_r <= cycle_count_r + 32'd1;

            // --------------------------
            // WB stage
            // --------------------------
            if (mem_wb_valid) begin
                if (mem_wb_halt) begin
                    halted_r <= 1'b1;
                end else if (mem_wb_regwrite && (mem_wb_dest != 5'd0)) begin
                    regs[mem_wb_dest] <= mem_wb_memtoreg ? mem_wb_mem_data : mem_wb_alu_out;
                end

                if (!mem_wb_halt) begin
                    instruction_count_r <= instruction_count_r + 32'd1;
                    if (mem_wb_dp4)
                        dp4_count_r <= dp4_count_r + 32'd1;
                end
            end

            // --------------------------
            // MEM stage
            // --------------------------
            mem_wb_valid <= ex_mem_valid;
            mem_wb_alu_out <= ex_mem_alu_out;
            mem_wb_dest <= ex_mem_dest;
            mem_wb_regwrite <= ex_mem_regwrite;
            mem_wb_memtoreg <= ex_mem_memtoreg;
            mem_wb_halt <= ex_mem_halt;
            mem_wb_dp4 <= ex_mem_dp4;

            if (ex_mem_valid && ex_mem_memread)
                mem_wb_mem_data <= data_mem[ex_mem_alu_out[9:0]];
            else
                mem_wb_mem_data <= 32'd0;

            if (ex_mem_valid && ex_mem_memwrite && !ex_mem_branch_taken)
                data_mem[ex_mem_alu_out[9:0]] <= ex_mem_store_data;

            // --------------------------
            // EX stage -> EX/MEM
            // --------------------------
            ex_mem_valid <= id_ex_valid;
            ex_mem_alu_out <= ex_alu_result;
            ex_mem_store_data <= ex_operand_b;
            ex_mem_dest <= (id_ex_opcode == OP_LW || id_ex_opcode == OP_ADDI ||
                            id_ex_opcode == OP_SUBI || id_ex_opcode == OP_SLTI)
                            ? id_ex_rt : id_ex_rd;
            ex_mem_regwrite <= id_ex_regwrite;
            ex_mem_memread <= id_ex_memread;
            ex_mem_memwrite <= id_ex_memwrite;
            ex_mem_memtoreg <= id_ex_memtoreg;
            ex_mem_halt <= id_ex_halt;
            ex_mem_branch_taken <= id_ex_valid && id_ex_branch && ex_branch_taken;
            ex_mem_branch_target <= ex_branch_target;
            ex_mem_dp4 <= id_ex_dp4;

            // --------------------------
            // ID stage -> ID/EX
            // --------------------------
            // A taken branch flushes the instruction immediately behind it.
            // A load-use hazard inserts one bubble but holds IF/ID and PC.
            if (id_ex_valid && id_ex_branch && ex_branch_taken) begin
                id_ex_valid <= 1'b0;
                id_ex_opcode <= OP_HLT;
                id_ex_regwrite <= 1'b0;
                id_ex_memread <= 1'b0;
                id_ex_memwrite <= 1'b0;
                id_ex_memtoreg <= 1'b0;
                id_ex_branch <= 1'b0;
                id_ex_halt <= 1'b0;
                id_ex_dp4 <= 1'b0;
            end else if (load_use_hazard) begin
                stall_count_r <= stall_count_r + 32'd1;

                id_ex_valid <= 1'b0;
                id_ex_opcode <= OP_HLT;
                id_ex_regwrite <= 1'b0;
                id_ex_memread <= 1'b0;
                id_ex_memwrite <= 1'b0;
                id_ex_memtoreg <= 1'b0;
                id_ex_branch <= 1'b0;
                id_ex_halt <= 1'b0;
                id_ex_dp4 <= 1'b0;
            end else begin
                id_ex_valid <= if_id_valid;
                id_ex_pc <= if_id_pc;
                id_ex_opcode <= id_opcode;
                id_ex_rs <= id_rs;
                id_ex_rt <= id_rt;
                id_ex_rd <= id_rd;
                // Write-first bypass: if WB is retiring a value to the same
                // register ID is reading this exact cycle, a plain register
                // file read would return the stale pre-write value (Verilog
                // non-blocking semantics use old values for RHS reads within
                // the same clock edge). This matters whenever a stall
                // delays an instruction long enough that its source's
                // producer finishes WB on the very cycle it is finally
                // decoded, which the EX-stage forwarding network cannot
                // catch (that value has already left MEM/WB by then).
                if (mem_wb_valid && mem_wb_regwrite && (mem_wb_dest != 5'd0) && (mem_wb_dest == id_rs))
                    id_ex_a <= mem_wb_memtoreg ? mem_wb_mem_data : mem_wb_alu_out;
                else
                    id_ex_a <= (id_rs == 5'd0) ? 32'd0 : regs[id_rs];

                if (mem_wb_valid && mem_wb_regwrite && (mem_wb_dest != 5'd0) && (mem_wb_dest == id_rt))
                    id_ex_b <= mem_wb_memtoreg ? mem_wb_mem_data : mem_wb_alu_out;
                else
                    id_ex_b <= (id_rt == 5'd0) ? 32'd0 : regs[id_rt];
                id_ex_imm <= id_imm;

                id_ex_regwrite <= (id_is_rtype || id_opcode == OP_DP4 ||
                                   id_opcode == OP_ADDI || id_opcode == OP_SUBI ||
                                   id_opcode == OP_SLTI || id_opcode == OP_LW);
                id_ex_memread <= (id_opcode == OP_LW);
                id_ex_memwrite <= (id_opcode == OP_SW);
                id_ex_memtoreg <= (id_opcode == OP_LW);
                id_ex_branch <= (id_opcode == OP_BEQZ || id_opcode == OP_BNEQZ);
                id_ex_branch_ne <= (id_opcode == OP_BNEQZ);
                id_ex_halt <= (id_opcode == OP_HLT);
                id_ex_dp4 <= (id_opcode == OP_DP4);
            end

            // --------------------------
            // IF stage
            // --------------------------
            if (id_ex_valid && id_ex_branch && ex_branch_taken) begin
                pc <= ex_branch_target;
                if_id_valid <= 1'b0;
                if_id_pc <= 32'd0;
                if_id_instr <= {OP_HLT, 26'd0};
            end else if (load_use_hazard) begin
                pc <= pc;
                if_id_valid <= if_id_valid;
                if_id_pc <= if_id_pc;
                if_id_instr <= if_id_instr;
            end else begin
                if_id_valid <= 1'b1;
                if_id_pc <= pc;
                if_id_instr <= instr_mem[pc[9:0]];
                pc <= pc + 32'd1;
            end

            regs[0] <= 32'd0;
        end
    end

endmodule
