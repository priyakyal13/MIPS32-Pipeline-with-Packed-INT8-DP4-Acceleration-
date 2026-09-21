`timescale 1ns/1ps

module tb_edge_mips;

    reg clk;
    reg reset;

    wire halted;
    wire [31:0] cycle_count;
    wire [31:0] instruction_count;
    wire [31:0] stall_count;
    wire [31:0] dp4_count;

    edge_mips dut(
        .clk(clk),
        .reset(reset),
        .halted(halted),
        .cycle_count(cycle_count),
        .instruction_count(instruction_count),
        .stall_count(stall_count),
        .dp4_count(dp4_count)
    );

    localparam [5:0] ADD   = 6'b000000;
    localparam [5:0] SUB   = 6'b000001;
    localparam [5:0] MUL   = 6'b000101;
    localparam [5:0] LW    = 6'b001000;
    localparam [5:0] SW    = 6'b001001;
    localparam [5:0] ADDI  = 6'b001010;
    localparam [5:0] BEQZ  = 6'b001110;
    localparam [5:0] DP4   = 6'b010000;
    localparam [5:0] HLT   = 6'b111111;

    integer errors;
    integer i;
    integer scalar_cycles, scalar_instructions;
    integer dp4_cycles, dp4_instructions;

    always #5 clk = ~clk;

    function [31:0] enc_r;
        input [5:0] op;
        input [4:0] rs;
        input [4:0] rt;
        input [4:0] rd;
        begin
            enc_r = {op, rs, rt, rd, 11'd0};
        end
    endfunction

    function [31:0] enc_i;
        input [5:0] op;
        input [4:0] rs;
        input [4:0] rt;
        input integer imm;
        begin
            enc_i = {op, rs, rt, imm[15:0]};
        end
    endfunction

    task clear_program;
        begin
            for (i = 0; i < 64; i = i + 1)
                dut.instr_mem[i] = {HLT, 26'd0};
            for (i = 0; i < 64; i = i + 1)
                dut.data_mem[i] = 32'd0;
        end
    endtask

    // Assert reset for two cycles and clear memories while reset is active.
    // The caller loads its program/data before releasing reset.
    task begin_test;
        begin
            reset = 1'b1;
            repeat (2) @(posedge clk);
            // The DUT's own synchronous reset clears instr_mem/data_mem via
            // non-blocking assignment on this same clock edge. Non-blocking
            // updates apply after all blocking statements in the same time
            // step, so poking memory here immediately would be silently
            // overwritten by the DUT's own reset-driven clear. Step past
            // that update region first.
            #1;
            clear_program;
        end
    endtask

    task release_reset;
        begin
            reset = 1'b0;
            @(posedge clk);
        end
    endtask

    task wait_for_halt;
        begin
            while (!halted) begin
                @(posedge clk);
                if (cycle_count > 200) begin
                    $display("ERROR: timeout waiting for HLT");
                    errors = errors + 1;
                    disable wait_for_halt;
                end
            end
        end
    endtask

    task run_hazard_test;
        begin
            begin_test;
            // ADDI R1, R0, 10
            // ADDI R2, R0, 7
            // ADD  R3, R1, R2  (EX/MEM forwarding)
            // SUB  R4, R3, R2  (EX/MEM forwarding)
            // SW   R4, 12(R0)
            // HLT
            dut.instr_mem[0] = enc_i(ADDI, 0, 1, 10);
            dut.instr_mem[1] = enc_i(ADDI, 0, 2, 7);
            dut.instr_mem[2] = enc_r(ADD, 1, 2, 3);
            dut.instr_mem[3] = enc_r(SUB, 3, 2, 4);
            dut.instr_mem[4] = enc_i(SW, 0, 4, 12);
            dut.instr_mem[5] = {HLT, 26'd0};

            release_reset;
            wait_for_halt;

            if (dut.data_mem[12] !== 32'd10) begin
                $display("FAIL hazard/forwarding: memory[12]=%0d expected 10", dut.data_mem[12]);
                errors = errors + 1;
            end else begin
                $display("PASS hazard/forwarding test: memory[12]=10");
            end
        end
    endtask

    task run_load_use_test;
        begin
            begin_test;
            dut.data_mem[20] = 32'd99;
            // LW R1,20(R0)
            // ADDI R2,R1,1   -> exactly one load-use stall
            // SW R2,21(R0)
            // HLT
            dut.instr_mem[0] = enc_i(LW, 0, 1, 20);
            dut.instr_mem[1] = enc_i(ADDI, 1, 2, 1);
            dut.instr_mem[2] = enc_i(SW, 0, 2, 21);
            dut.instr_mem[3] = {HLT, 26'd0};

            release_reset;
            wait_for_halt;

            if (dut.data_mem[21] !== 32'd100) begin
                $display("FAIL load-use test: memory[21]=%0d expected 100", dut.data_mem[21]);
                errors = errors + 1;
            end else if (stall_count !== 32'd1) begin
                $display("FAIL load-use stall count: got %0d expected 1", stall_count);
                errors = errors + 1;
            end else begin
                $display("PASS load-use test: result=100, stalls=1");
            end
        end
    endtask

    task run_dp4_test;
        begin
            begin_test;
            // Packed INT8 vectors: [4,3,2,1] and [8,7,6,5]
            // Bytes are interpreted from low to high as 1,2,3,4 and 5,6,7,8.
            dut.data_mem[24] = 32'h04030201;
            dut.data_mem[25] = 32'h08070605;
            dut.data_mem[27] = 32'hFCFDFEFF; // [-1,-2,-3,-4]
            dut.data_mem[28] = 32'h01010101; // [1,1,1,1]

            // LW R1,24(R0)
            // LW R2,25(R0)
            // DP4 R3,R1,R2 = 1*5 + 2*6 + 3*7 + 4*8 = 70
            // SW R3,26(R0)
            // HLT
            dut.instr_mem[0] = enc_i(LW, 0, 1, 24);
            dut.instr_mem[1] = enc_i(LW, 0, 2, 25);
            dut.instr_mem[2] = enc_r(DP4, 1, 2, 3);
            dut.instr_mem[3] = enc_i(SW, 0, 3, 26);
            dut.instr_mem[4] = {HLT, 26'd0};

            release_reset;
            wait_for_halt;

            if (dut.data_mem[26] !== 32'd70) begin
                $display("FAIL DP4 test: memory[26]=%0d expected 70", dut.data_mem[26]);
                errors = errors + 1;
            end else begin
                $display("PASS DP4 positive test: result=70");
            end

            // Signed-lane check: (-1)+(-2)+(-3)+(-4) = -10.
            begin_test;
            dut.data_mem[27] = 32'hFCFDFEFF;
            dut.data_mem[28] = 32'h01010101;
            dut.instr_mem[0] = enc_i(LW, 0, 1, 27);
            dut.instr_mem[1] = enc_i(LW, 0, 2, 28);
            dut.instr_mem[2] = enc_r(DP4, 1, 2, 3);
            dut.instr_mem[3] = enc_i(SW, 0, 3, 29);
            dut.instr_mem[4] = {HLT, 26'd0};
            release_reset;
            wait_for_halt;

            if (dut.data_mem[29] !== 32'hFFFFFFF6) begin
                $display("FAIL DP4 signed test: memory[29]=0x%08h expected 0xFFFFFFF6", dut.data_mem[29]);
                errors = errors + 1;
            end else begin
                $display("PASS DP4 signed test: result=-10");
            end
        end
    endtask

    task run_benchmark_test;
        begin
            // Same mathematical dot product, first computed with scalar MUL/ADD,
            // then with two loads + one DP4 instruction.
            begin_test;

            // Scalar operands
            dut.data_mem[0] = 32'd1;
            dut.data_mem[1] = 32'd2;
            dut.data_mem[2] = 32'd3;
            dut.data_mem[3] = 32'd4;
            dut.data_mem[4] = 32'd5;
            dut.data_mem[5] = 32'd6;
            dut.data_mem[6] = 32'd7;
            dut.data_mem[7] = 32'd8;

            // Packed operands for DP4
            dut.data_mem[16] = 32'h04030201;
            dut.data_mem[17] = 32'h08070605;

            // Scalar program writes 70 to data_mem[10].
            dut.instr_mem[0]  = enc_i(LW,   0, 1, 0);
            dut.instr_mem[1]  = enc_i(LW,   0, 2, 4);
            dut.instr_mem[2]  = enc_r(MUL,  1, 2, 3);
            dut.instr_mem[3]  = enc_i(LW,   0, 1, 1);
            dut.instr_mem[4]  = enc_i(LW,   0, 2, 5);
            dut.instr_mem[5]  = enc_r(MUL,  1, 2, 4);
            dut.instr_mem[6]  = enc_r(ADD,  3, 4, 3);
            dut.instr_mem[7]  = enc_i(LW,   0, 1, 2);
            dut.instr_mem[8]  = enc_i(LW,   0, 2, 6);
            dut.instr_mem[9]  = enc_r(MUL,  1, 2, 4);
            dut.instr_mem[10] = enc_r(ADD,  3, 4, 3);
            dut.instr_mem[11] = enc_i(LW,  0, 1, 3);
            dut.instr_mem[12] = enc_i(LW,  0, 2, 7);
            dut.instr_mem[13] = enc_r(MUL, 1, 2, 4);
            dut.instr_mem[14] = enc_r(ADD, 3, 4, 3);
            dut.instr_mem[15] = enc_i(SW,  0, 3, 10);
            dut.instr_mem[16] = {HLT, 26'd0};

            release_reset;
            wait_for_halt;
            scalar_cycles = cycle_count;
            scalar_instructions = instruction_count;

            if (dut.data_mem[10] !== 32'd70) begin
                $display("FAIL scalar benchmark result: %0d expected 70", dut.data_mem[10]);
                errors = errors + 1;
            end

            // Reuse memory, but execute DP4 version after a fresh reset.
            begin_test;
            dut.data_mem[16] = 32'h04030201;
            dut.data_mem[17] = 32'h08070605;
            dut.instr_mem[0] = enc_i(LW, 0, 1, 16);
            dut.instr_mem[1] = enc_i(LW, 0, 2, 17);
            dut.instr_mem[2] = enc_r(DP4, 1, 2, 3);
            dut.instr_mem[3] = enc_i(SW, 0, 3, 18);
            dut.instr_mem[4] = {HLT, 26'd0};

            release_reset;
            wait_for_halt;
            dp4_cycles = cycle_count;
            dp4_instructions = instruction_count;

            if (dut.data_mem[18] !== 32'd70) begin
                $display("FAIL DP4 benchmark result: %0d expected 70", dut.data_mem[18]);
                errors = errors + 1;
            end

            $display("------------------------------------------------------------");
            $display("Dot-product benchmark");
            $display("Scalar MUL/ADD : cycles=%0d instructions=%0d", scalar_cycles, scalar_instructions);
            $display("Custom DP4     : cycles=%0d instructions=%0d", dp4_cycles, dp4_instructions);
            $display("DP4 retired    : %0d", dp4_count);
            if (dp4_cycles < scalar_cycles)
                $display("PASS: DP4 completed the same dot product in fewer cycles.");
            else
                $display("NOTE: DP4 cycle count was not lower; inspect stalls or tool timing.");
            $display("------------------------------------------------------------");
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b0;
        errors = 0;
        $dumpfile("edge_mips.vcd");
        $dumpvars(0, tb_edge_mips);

        run_hazard_test;
        run_load_use_test;
        run_dp4_test;
        run_benchmark_test;

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TESTS FAILED: %0d error(s)", errors);

        #10;
        $finish;
    end

endmodule
