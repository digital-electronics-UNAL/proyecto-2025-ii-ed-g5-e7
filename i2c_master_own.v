module i2c_master (
    //inputs
    input  clk,
    input  rst,
    input  start_cmd,
    input [6:0] slave_addr,
    input rw_bit,
    input sda_in,
    input [7:0] data_in,
    input last_byte, //indicates if it's the last byte and stops transmission
    //outputs
    output reg scl,
    output reg sda_out,
    output reg sda_oe,
    //debug flags
    output reg busy, 
    output reg done,
    output reg error,

    //In order to read data byte from slave
    output reg [7:0] data_out
); 

    // Parameters
    parameter SYS_CLK_FREQ = 50_000_000;
    parameter I2C_FREQ = 100_000;
    localparam DIVIDER = SYS_CLK_FREQ / (2 * I2C_FREQ);
    
    // Internal registers
    reg [15:0] clk_count;
    
    // SCL generation
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_count <= 0;
            scl <= 1'b1;
        end else if (busy_reg) begin
            if (clk_count == DIVIDER - 1) begin
                clk_count <= 0;
                scl <= ~scl;
            end else begin
                clk_count <= clk_count + 1;
            end
        end
    end


    // State definitions
    localparam IDLE         = 4'd0;  
    localparam START        = 4'd1;   // send START condition
    localparam SEND_ADDR    = 4'd2;   // send 7-bit address + R/W bit
    localparam WAIT_ACK     = 4'd3;   // wait for ACK from slave
    localparam SEND_DATA    = 4'd4;   // send data byte
    localparam RECEIVE_DATA = 4'd5;   // send data byte
    localparam SEND_ACK     = 4'd6;   // master sends ACK/NACK
    localparam STOP         = 4'd7;   // send STOP condition

    // Bit counter
    reg [2:0] bit_count;  // counts 0-7 (8 bits)
    reg [7:0] addr_rw;    // holds address + RW bit


    // State registers
    reg [3:0] state;
    reg [3:0] next_state;

    // Add flag registers at the top (with other regs)
    reg busy_reg;
    reg done_reg;
    reg error_reg;

    //other registers
    reg [7:0] data_tx; // buffer for data to send/receive

    // Combinational block 
    always @(*) begin
        // Default values
        next_state = state;
        sda_out = 1'b1;
        sda_oe = 1'b0;
        
        // Flags assignment
        busy = busy_reg;
        done = done_reg;
        error = error_reg;
        
        case (state)
            IDLE: begin
                sda_out = 1'b1;
                sda_oe = 1'b0;
                
                if (start_cmd) begin
                    next_state = START;
                end
            end
            
            START: begin
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
                sda_out = addr_rw[7 - bit_count];
                
                if (bit_count == 7 && scl == 1'b1) begin
                    next_state = WAIT_ACK;
                end
            end
            
            WAIT_ACK: begin
                sda_oe = 1'b0;
                
                if (scl == 1'b1) begin
                    if (sda_in == 1'b0) begin  // ACK
                        if (rw_bit == 1'b0) begin  // write operation
                            if (last_byte) begin
                                next_state = STOP;  // done writing
                            end else begin
                                next_state = SEND_DATA;  // send another byte
                            end
                        end else begin  // read operation
                            next_state = RECEIVE_DATA;
                        end
                    end else begin  // NAK
                        next_state = STOP;
                    end
                end
            end

            SEND_DATA: begin
                sda_oe = 1'b1;  // drive SDA
                sda_out = data_tx[7 - bit_count];  // send current bit MSB first
                
                if (bit_count == 7 && scl == 1'b1) begin
                    next_state = WAIT_ACK;
                end
            end

            RECEIVE_DATA: begin
                sda_oe = 1'b0;  // release SDA (slave drives it)
                
                if (bit_count == 7 && scl == 1'b1) begin
                    next_state = SEND_ACK;
                end
            end

            SEND_ACK: begin
                sda_oe = 1'b1;
                
                if (last_byte) begin
                    sda_out = 1'b1;  // NACK (done)
                    if (scl == 1'b1) begin
                        next_state = STOP;
                    end
                end else begin
                    sda_out = 1'b0;  // ACK (continue)
                    if (scl == 1'b1) begin
                        next_state = RECEIVE_DATA;  // read another byte
                    end
                end
            end

            STOP: begin
                sda_oe = 1'b1;  // drive SDA in order to send STOP
                
                if (scl == 1'b1) begin
                    sda_out = 1'b1;  // SDA high + SCL high = STOP
                    next_state = IDLE; 
                end else begin
                    sda_out = 1'b0;  // keep SDA low initially, wait for SCL high
                end
            end

            default: begin
                next_state = IDLE;
            end

        endcase

    end

    // Sequential block 
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            bit_count <= 0;
            addr_rw <= 0;
            busy_reg <= 0;
            done_reg <= 0;
            error_reg <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (start_cmd) begin
                        busy_reg <= 1'b1;
                        done_reg <= 1'b0;
                        error_reg <= 1'b0;
                    end
                end
                
                START: begin
                    addr_rw <= {slave_addr, rw_bit};
                    bit_count <= 0;
                end
                
                SEND_ADDR: begin
                    if (scl == 1'b1) begin
                        if (bit_count == 7) begin
                            bit_count <= 0;
                        end else begin
                            bit_count <= bit_count + 1;
                        end
                    end
                end
                
                 WAIT_ACK: begin
                    if (scl == 1'b1) begin
                        if (sda_in == 1'b1) begin  // NAK
                            error_reg <= 1'b1; // sets error flag then goes to STOP
                        end else begin  // ACK received
                            bit_count <= 0;  // reset for next byte
                            if (rw_bit == 1'b0) begin  // write operation
                                data_tx <= data_in;  // load next byte to send
                            end
                        end
                    end
                end
                 SEND_DATA: begin
                    if (scl == 1'b1) begin
                        if (bit_count == 7) begin
                            bit_count <= 0;
                        end else begin
                            bit_count <= bit_count + 1;
                        end
                    end
                end

                RECEIVE_DATA: begin
                    if (scl == 1'b1) begin  // read on SCL high
                        data_tx <= {data_tx[6:0], sda_in};  // shift in new bit
                        
                        if (bit_count == 7) begin
                            bit_count <= 0;
                            data_out <= {data_tx[6:0], sda_in};  // output complete byte
                        end else begin
                            bit_count <= bit_count + 1;
                        end
                    end
                end

                STOP: begin
                    if (scl == 1'b1) begin  // when STOP is complete
                        busy_reg <= 1'b0; //clear busy
                        done_reg <= 1'b1; //set done
                    end
                end

                SEND_ACK: begin
                    if (scl == 1'b1 && !last_byte) begin
                        bit_count <= 0;  // reset for next byte
                    end
                end

            endcase
            
            state <= next_state;
        end
    end

    

endmodule