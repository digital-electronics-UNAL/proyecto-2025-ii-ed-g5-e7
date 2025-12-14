module uart_tx_debug #(
    parameter CLKS_PER_BIT = 5208
)(
    input wire       clk,
    input wire       rst_n,
    input wire       tx_start,
    input wire [7:0] tx_data,
    output reg       tx_serial,
    output reg       busy,
    // --- NUEVA SEÑAL PARA DEBUG ---
    output reg       o_baud_tick // Pulso al final de cada bit
);

    localparam IDLE  = 2'b00;
    localparam START = 2'b01;
    localparam DATA  = 2'b10;
    localparam STOP  = 2'b11;

    reg [1:0]  state;
    reg [12:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  data_temp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            tx_serial   <= 1'b1;
            busy        <= 1'b0;
            clk_count   <= 0;
            bit_index   <= 0;
            data_temp   <= 0;
            o_baud_tick <= 1'b0; // Reset del tick
        end else begin
            // Por defecto el tick está en bajo, solo sube un ciclo al final del conteo
            o_baud_tick <= 1'b0; 

            case (state)
                IDLE: begin
                    tx_serial <= 1'b1;
                    busy      <= 1'b0;
                    clk_count <= 0;
                    bit_index <= 0;
                    
                    if (tx_start == 1'b1) begin
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
                        clk_count   <= 0;
                        o_baud_tick <= 1'b1; // <--- ¡PULSO DE DEBUG!
                        state       <= DATA;
                    end
                end

                DATA: begin
                    tx_serial <= data_temp[bit_index];
                    
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1;
                    end else begin
                        clk_count   <= 0;
                        o_baud_tick <= 1'b1; // <--- ¡PULSO DE DEBUG!
                        
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 1;
                        end else begin
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
                        clk_count   <= 0;
                        o_baud_tick <= 1'b1; // <--- ¡PULSO DE DEBUG!
                        busy        <= 1'b0;
                        state       <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
endmodule