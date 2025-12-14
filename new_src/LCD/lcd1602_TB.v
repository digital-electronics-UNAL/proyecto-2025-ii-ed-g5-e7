`timescale 1ns / 1ps
`include "LCD1602_controller.v"

module LCD1602_controller_TB();
    reg clk;
    reg rst;
    reg ready_i;
    reg [15:0] num1;
    reg [3:0] num2;


    LCD1602_controller #(4, 32, 16, 8, 50) uut (
        .clk(clk),
        .reset(rst),
        .ready_i(ready_i),
        .number1(num1),
        .number2(num2)
    );

    initial begin
        clk = 0;
        rst = 1;
        ready_i = 1;
        num1 = 16'h0008;
        num2 = 4'b1111; 
        #10 rst = 0;
        #10 rst = 1;
    end

    always #10 clk = ~clk;

    initial begin: TEST_CASE
        $dumpfile("gLCD.vcd");
        $dumpvars(-1, uut);
        #(1000000) $finish;
    end


endmodule