`timescale 1ns / 1ps
`include "uart_tx_debug.v"
module tb_uart_debug;

    reg clk;
    reg rst_n;
    reg tx_start;
    reg [7:0] tx_data;

    wire tx_serial;
    wire busy;
    wire o_baud_tick; // Cable para ver el tick

    // Usamos divisor pequeño para simulación visual rápida
    localparam CLKS_PER_BIT = 4; 
    localparam CLK_PERIOD = 20;

    uart_tx_debug #(.CLKS_PER_BIT(CLKS_PER_BIT)) uut (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx_serial(tx_serial),
        .busy(busy),
        .o_baud_tick(o_baud_tick) // Conexión nueva
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        $dumpfile("uart_debug.vcd");
        $dumpvars(0, tb_uart_debug);

        clk = 0; rst_n = 0; tx_start = 0; tx_data = 0;
        
        #100;
        rst_n = 1;
        #40;

        // Enviar letra 'A' (0x41 = 01000001) -> LSB primero: 10000010
        tx_data = 8'h41; 
        tx_start = 1;
        #20;
        tx_start = 0;

        wait(busy == 0);
        #100;
        $finish;
    end
endmodule