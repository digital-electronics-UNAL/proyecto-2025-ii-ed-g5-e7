module uart_tx #(
    parameter CLKS_PER_BIT = 5208 // Default para 50MHz @ 9600
)(
    input wire       clk,
    input wire       rst_n,
    input wire       tx_start,
    input wire [7:0] tx_data,
    output reg       tx_serial,
    output reg       busy
);

    localparam IDLE  = 2'b00;
    localparam START = 2'b01;
    localparam DATA  = 2'b10;
    localparam STOP  = 2'b11;

    reg [1:0]  state;
    reg [15:0] clk_count; // Aumentado a 16 bits por seguridad si bajas el baudrate
    reg [2:0]  bit_index;
    reg [7:0]  data_temp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            tx_serial <= 1'b1;
            busy      <= 1'b0;
            clk_count <= 0;
            bit_index <= 0;
        end else begin
            case (state)
                IDLE: begin
                    tx_serial <= 1'b1;
                    busy      <= 1'b0;
                    clk_count <= 0;
                    bit_index <= 0;
                    if (tx_start) begin
                        data_temp <= tx_data;
                        busy      <= 1'b1;
                        state     <= START;
                    end
                end

                START: begin
                    tx_serial <= 1'b0;
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count <= 0;
                        state     <= DATA;
                    end
                end

                DATA: begin
                    tx_serial <= data_temp[bit_index];
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count <= 0;
                        if (bit_index < 7)
                            bit_index <= bit_index + 1;
                        else begin
                            bit_index <= 0;
                            state     <= STOP;
                        end
                    end
                end

                STOP: begin
                    tx_serial <= 1'b1;
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count <= 0;
                        busy      <= 1'b0;
                        state     <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule