module i2c_master (
    // inputs
    input  clk,
    input  rst,
    input  start_cmd,
    input [6:0] slave_addr,
    input rw_bit,
    input sda_in,
    input [7:0] data_in,
    input last_byte, // indicates if it's the last byte and stops transmission
    // outputs
    output reg scl,
    output reg sda_out,
    output reg sda_oe,
    // debug flags
    output reg busy,
    output reg done,
    output reg error,
    // In order to read data byte from slave
    output reg [7:0] data_out
);

    // Parameters
    parameter SYS_CLK_FREQ = 50_000_000;
    parameter I2C_FREQ = 100_000;
    localparam integer DIVIDER = SYS_CLK_FREQ / (2 * I2C_FREQ); // scl toggles every DIVIDER clk cycles

    // Internal registers
    reg [31:0] clk_count;
    reg scl_prev;
    wire scl_rising = (scl == 1'b1) && (scl_prev == 1'b0);

    // State definitions
    localparam IDLE         = 4'd0;
    localparam START        = 4'd1;   // send START condition
    localparam SEND_ADDR    = 4'd2;   // send 7-bit address + R/W bit
    localparam WAIT_ACK     = 4'd3;   // wait for ACK from slave
    localparam SEND_DATA    = 4'd4;   // send data byte
    localparam RECEIVE_DATA = 4'd5;   // receive data byte
    localparam SEND_ACK     = 4'd6;   // master sends ACK/NACK
    localparam STOP         = 4'd7;   // send STOP condition

    // Registers
    reg [2:0] bit_count;  // 0..7
    reg [7:0] addr_rw;    // address + R/W
    reg [3:0] state, next_state;
    reg busy_reg, done_reg, error_reg;
    reg [7:0] data_tx; // shift register for transfer

    // ===== SCL generation (clocked by system clk) =====
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_count <= 0;
            scl <= 1'b1;   // idle high
            scl_prev <= 1'b1;
        end else begin
            if (busy_reg) begin
                if (clk_count == DIVIDER - 1) begin
                    clk_count <= 0;
                    scl <= ~scl;
                end else begin
                    clk_count <= clk_count + 1;
                end
            end else begin
                clk_count <= 0;
                scl <= 1'b1; // keep SCL high when idle
            end
            // sample previous SCL (for edge detection)
            scl_prev <= scl;
        end
    end

    // ===== Combinational next-state and SDA drive decisions =====
    // We compute next_state combinationally so outputs (sda_oe/sda_out) can respond quickly.
    always @(*) begin
        // defaults
        next_state = state;
        sda_out = 1'b1;
        sda_oe  = 1'b0;
        // copy status flags to outputs (driven from regs)
        busy = busy_reg;
        done = done_reg;
        error = error_reg;

        case (state)
            IDLE: begin
                sda_oe = 1'b0;
                sda_out = 1'b1;
                if (start_cmd && !busy_reg) begin
                    next_state = START;
                end
            end

            START: begin
                // Start condition: SDA goes low while SCL is high
                sda_oe = 1'b1;
                if (scl == 1'b1) begin
                    sda_out = 1'b0;
                    next_state = SEND_ADDR;
                end else begin
                    sda_out = 1'b1;
                end
            end

            SEND_ADDR: begin
                sda_oe = 1'b1;
                // send MSB first: addr_rw[7] .. addr_rw[0]
                sda_out = addr_rw[7 - bit_count];
                if (bit_count == 3'd7 && scl == 1'b1) begin
                    next_state = WAIT_ACK;
                end
            end

            WAIT_ACK: begin
                // release SDA so slave drives ACK/NACK (ACK = 0)
                sda_oe = 1'b0;
                if (scl == 1'b1) begin
                    // next_state chosen based on sampled ACK in FSM sequential (on scl rising)
                    // keep combinational default — FSM transitions on scl edges
                end
            end

            SEND_DATA: begin
                sda_oe = 1'b1;
                sda_out = data_tx[7 - bit_count];
                if (bit_count == 3'd7 && scl == 1'b1) begin
                    next_state = WAIT_ACK;
                end
            end

            RECEIVE_DATA: begin
                sda_oe = 1'b0; // release SDA, slave will drive
                if (bit_count == 3'd7 && scl == 1'b1) begin
                    next_state = SEND_ACK;
                end
            end

            SEND_ACK: begin
                sda_oe = 1'b1;
                if (last_byte) begin
                    sda_out = 1'b1; // NACK to end read
                    if (scl == 1'b1) next_state = STOP;
                end else begin
                    sda_out = 1'b0; // ACK to continue reading
                    if (scl == 1'b1) next_state = RECEIVE_DATA;
                end
            end

            STOP: begin
                sda_oe = 1'b1;
                // produce STOP: SDA goes high while SCL is high
                if (scl == 1'b1) begin
                    sda_out = 1'b1;
                    next_state = IDLE;
                end else begin
                    sda_out = 1'b0; // keep low until SCL goes high
                end
            end

            default: next_state = IDLE;
        endcase
    end

    // ===== Sequential FSM: triggered on system clock =====
    // Use scl_rising (edge detection) inside this clocked block to do bit shifting / sampling
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            bit_count <= 3'd0;
            addr_rw <= 8'd0;
            data_tx <= 8'd0;
            busy_reg <= 1'b0;
            done_reg <= 1'b0;
            error_reg <= 1'b0;
            data_out <= 8'd0;
        end else begin
            // Handle start: assert busy when new start is requested (so SCL generator begins)
            if (state == IDLE && start_cmd && !busy_reg) begin
                busy_reg <= 1'b1;
                done_reg <= 1'b0;
                error_reg <= 1'b0;
            end

            // On scl rising edge we perform bit-level actions
            if (scl_rising) begin
                case (state)
                    IDLE: begin
                        // nothing (we set busy_reg above on start)
                    end

                    START: begin
                        // load address+rw, start sending
                        addr_rw <= {slave_addr, rw_bit};
                        bit_count <= 3'd0;
                    end

                    SEND_ADDR: begin
                        // transmitted one bit per SCL rising; increment bit counter
                        if (bit_count == 3'd7) begin
                            bit_count <= 3'd0;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                        end
                    end

                    WAIT_ACK: begin
                        // sample ACK on rising edge (slave drives SDA during ACK)
                        if (sda_in == 1'b1) begin
                            // NAK
                            error_reg <= 1'b1;
                        end else begin
                            // ACK: prepare next byte depending on R/W
                            bit_count <= 3'd0;
                            if (rw_bit == 1'b0) begin
                                // write: load data to send
                                data_tx <= data_in;
                            end else begin
                                // read: prepare to receive
                                data_tx <= 8'd0;
                            end
                        end
                    end

                    SEND_DATA: begin
                        if (bit_count == 3'd7) bit_count <= 3'd0;
                        else bit_count <= bit_count + 1'b1;
                    end

                    RECEIVE_DATA: begin
                        // shift in the bit read from SDA (sample on SCL rising)
                        data_tx <= {data_tx[6:0], sda_in};
                        if (bit_count == 3'd7) begin
                            bit_count <= 3'd0;
                            data_out <= {data_tx[6:0], sda_in}; // complete byte
                        end else begin
                            bit_count <= bit_count + 1'b1;
                        end
                    end

                    SEND_ACK: begin
                        // nothing special on rising edge; ACK/NACK drive is handled combinationally
                        if (last_byte) begin
                            // the combinational logic moves to STOP when SCL is high
                        end else begin
                            // will continue reading in next cycle
                        end
                    end

                    STOP: begin
                        // When STOP is complete (SCL high and SDA high), clear busy and set done
                        // We check for state transition to IDLE in combinational, but assert flags here:
                        if (scl == 1'b1) begin
                            busy_reg <= 1'b0;
                            done_reg <= 1'b1;
                        end
                    end

                    default: ;
                endcase
            end // scl_rising

            // advance state at each clock based on next_state (combinational)
            state <= next_state;
        end
    end

    // drive the outputs from internal registers (already assigned in comb block above)
    // busy/done/error already assigned in comb above as copies; but keep the reg outputs consistent:
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            busy <= busy_reg;
            done <= done_reg;
            error <= error_reg;
        end
    end

endmodule
