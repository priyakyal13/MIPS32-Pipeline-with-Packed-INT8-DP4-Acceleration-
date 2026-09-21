`timescale 1ns/1ps
// EdgeMIPS custom packed INT8 dot-product unit.
// Computes four signed 8-bit products and accumulates them into 32 bits.

module dp4_unit(
    input  [31:0] a,
    input  [31:0] b,
    output [31:0] result
);

    wire signed [7:0] a0 = a[7:0];
    wire signed [7:0] a1 = a[15:8];
    wire signed [7:0] a2 = a[23:16];
    wire signed [7:0] a3 = a[31:24];

    wire signed [7:0] b0 = b[7:0];
    wire signed [7:0] b1 = b[15:8];
    wire signed [7:0] b2 = b[23:16];
    wire signed [7:0] b3 = b[31:24];

    wire signed [15:0] p0 = a0 * b0;
    wire signed [15:0] p1 = a1 * b1;
    wire signed [15:0] p2 = a2 * b2;
    wire signed [15:0] p3 = a3 * b3;

    // Explicit sign extension avoids 16-bit intermediate overflow during addition.
    wire signed [17:0] p0e = {{2{p0[15]}}, p0};
    wire signed [17:0] p1e = {{2{p1[15]}}, p1};
    wire signed [17:0] p2e = {{2{p2[15]}}, p2};
    wire signed [17:0] p3e = {{2{p3[15]}}, p3};
    wire signed [17:0] sum = p0e + p1e + p2e + p3e;

    assign result = {{14{sum[17]}}, sum};

endmodule
