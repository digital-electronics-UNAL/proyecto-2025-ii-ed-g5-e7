`timescale 1ns/1ps
module I2C_ADS1115(
    input   system_clock,
    input   reset_n,
	 
	 // Core Signals: I2C_SCLK and I2C_SDA
    output  I2C_SCLK,
    inout   I2C_SDA,
	 
	 // ADC Output (16-bit raw reading)
	 output reg [15:0] lux_value,
	 output reg lux_valid,
	 
	 // Debug Signals
    output  		I2C_SCLK_Ref,
    output  		I2C_SCLK_Ref_200k,
    output  [5:0] presentState_output,       // widened to expose more states
    output  [7:0] i2c_clock_cycles_output,
    output  [7:0] i2c_bit_count_output,
	 output			sda_out_en_output,
	 input			read_I2C_SDA,
	 input			read_I2C_SCLK,
	 output  [31:0]counter_last_output
);

// ----------------------
// State machine (unique values)
// ----------------------
localparam S_RESET                   = 6'd0;
localparam S_WAIT_RDWR               = 6'd1;

// Write configuration (ADDR+W, pointer=0x01, config MSB, config LSB)
localparam S_START_WR                = 6'd2;
localparam S_START_WR_READY          = 6'd3;
localparam S_START_WR_STABLE         = 6'd4;
localparam S_WRITE                   = 6'd5;
localparam S_STOP_WR                 = 6'd6;
localparam S_STOP_WR_READY           = 6'd7;
localparam S_STOP_WR_STABLE          = 6'd8;

localparam S_WAIT_CONVERSION         = 6'd30;

// Pre-read pointer write (ADDR+W, pointer=0x00)
localparam S_START_WR_PRE_READ       = 6'd9;
localparam S_START_WR_PRE_READ_RDY   = 6'd10;
localparam S_START_WR_PRE_READ_STAB  = 6'd11;
localparam S_WRITE_PRE_READ          = 6'd12;
localparam S_STOP_WR_PRE_READ        = 6'd13;
localparam S_STOP_WR_PRE_READ_RDY    = 6'd14;
localparam S_STOP_WR_PRE_READ_STAB   = 6'd15;

// Read transaction (ADDR+R, read two bytes)
localparam S_START_READ              = 6'd16;
localparam S_START_READ_READY        = 6'd17;
localparam S_START_READ_STABLE       = 6'd18;
localparam S_READ                    = 6'd19;
localparam S_STOP_READ               = 6'd20;
localparam S_STOP_READ_READY         = 6'd21;
localparam S_STOP_READ_STABLE        = 6'd22;

// ----------------------
// Registers and signals
// ----------------------
reg [19:0] counter = 1'b0;

reg [5:0]  presentState       = S_RESET;
reg [5:0]  nextState          = S_RESET;
reg [31:0] count              = 32'd0;
reg [31:0] count_2            = 32'd0;
reg        i2c_sclk_local     = 1'b1;
reg        i2c_sclk_local_200khz = 1'b1;
reg        i2c_sclk_local_output = 1'b1;
reg        sda_out_en         = 1'b0; // default tri-state
reg [7:0]  i2c_clock_cycles   = 8'd0;
reg        i2c_sda_state      = 1'b1;
reg [31:0] counter_last       = 32'd0;

// incoming data
reg [7:0] lux_byte_high = 8'd0;
reg [7:0] lux_byte_low  = 8'd0;

// ADS1115 address/commands
reg [7:0] write_command = {7'b100_1000, 1'b0};  // 0x90 (write)
reg [7:0] read_command  = {7'b100_1000, 1'b1};  // 0x91 (read)

reg [7:0] pointer_conv   = 8'h00;
reg [7:0] pointer_config = 8'h01;

// Configuration bytes recommended for 1.2V sensor (PGA ±2.048V, 128SPS)
reg [7:0] write_configuration_1 = 8'hC5; // OS=1, MUX=100(AIN0), PGA=010 (±2.048V), MODE=1
reg [7:0] write_configuration_2 = 8'h83; // DR=100 (128SPS), comparator disabled

localparam integer WAIT_CYCLES = 2000; // ~10 ms with this clocking approach

// ----------------------
// Clock dividers
// ----------------------
//Wait for conversion time 9 ms 
always @ (posedge system_clock) begin
    if (presentState == S_WAIT_CONVERSION) begin
        counter <= counter + 1'b1;
    end else begin
    end
end



always @ (posedge system_clock) begin
    if (count == 50) begin
        i2c_sclk_local <= ~i2c_sclk_local;
        count <= 32'd1;
    end else begin
        count <= count + 32'd1;
    end
end

always @ (posedge system_clock) begin
    if (count_2 == 25) begin
        i2c_sclk_local_200khz <= ~i2c_sclk_local_200khz;
        count_2 <= 32'd1;
    end else begin
        count_2 <= count_2 + 32'd1;
    end
end

// presentState update (clocked by internal SCLK tick)
always @ (posedge i2c_sclk_local_200khz) begin
    if (!reset_n) begin
        presentState <= S_RESET;
    end else begin
        presentState <= nextState;
    end
end

// Reemplaza tu always @(*) que controla sda_out_en por esto:
always @ (*)
begin
    // default: release SDA (tri-state)
    //sda_out_en = 1'b0;

    // Force drive during START/STOP sequences so we actually assert SDA low/high
    if (presentState == S_START_WR ||
        presentState == S_START_WR_READY ||
        presentState == S_START_WR_STABLE ||//StartWrite

        presentState == S_START_WR_PRE_READ ||
        presentState == S_START_WR_PRE_READ_RDY ||
        presentState == S_START_WR_PRE_READ_STAB ||

        presentState == S_START_READ ||
        presentState == S_START_READ_READY ||
        presentState == S_START_READ_STABLE ||

        presentState == S_STOP_WR ||
        presentState == S_STOP_WR_READY ||
        presentState == S_STOP_WR_STABLE ||

        presentState == S_STOP_WR_PRE_READ ||
        presentState == S_STOP_WR_PRE_READ_RDY ||
        presentState == S_STOP_WR_PRE_READ_STAB ||

        presentState == S_STOP_READ ||
        presentState == S_STOP_READ_READY ||
        presentState == S_STOP_READ_STABLE)
    begin
        sda_out_en = 1'b1;
    end
    else if (presentState == S_WRITE) begin
        if ( i2c_clock_cycles == 16 || i2c_clock_cycles == 17 
            || i2c_clock_cycles == 34 || i2c_clock_cycles == 35 
            || i2c_clock_cycles == 52 || i2c_clock_cycles == 53 
            || i2c_clock_cycles == 70 || i2c_clock_cycles == 71)
            sda_out_en = 1'b0;
        else
            sda_out_en = 1'b1;
    end
    else if (presentState == S_WRITE_PRE_READ) begin
        if (i2c_clock_cycles == 16 || i2c_clock_cycles == 17 
            ||  i2c_clock_cycles == 34 || i2c_clock_cycles == 35)
            sda_out_en = 1'b0;
        else
            sda_out_en = 1'b1;
    end
    else if (presentState == S_READ) begin
        if ( (i2c_clock_cycles <= 15) || // address phase
             i2c_clock_cycles == 34 || i2c_clock_cycles == 35 || // ACK after byte1
             i2c_clock_cycles == 52 || i2c_clock_cycles == 53 ) // NACK after byte2
            
            sda_out_en = 1'b1;
        else
            sda_out_en = 1'b0;
    end
    else begin
        sda_out_en = 1'b0;
    end
end


// SDA drive value when driving (we set high by default; bits will be set per cycle)
always @ (*) begin
    i2c_sda_state = 1'b1;

    case (presentState)
        S_RESET: i2c_sda_state = 1'b1;

        // START conditions: hold SDA low while SCL high
        S_START_WR: i2c_sda_state = 1'b1;
        S_START_WR_READY: i2c_sda_state = 1'b0;

        S_STOP_WR: i2c_sda_state = 1'b0;
        S_STOP_WR_READY: i2c_sda_state = 1'b0;
        S_STOP_WR_STABLE: i2c_sda_state = 1'b1;

        S_START_WR_PRE_READ: i2c_sda_state = 1'b0;
        S_START_WR_PRE_READ_STAB: i2c_sda_state = 1'b0;

        S_START_READ: i2c_sda_state = 1'b0;

        // WRITE transaction (address, pointer, config MSB, config LSB)
        S_WRITE: begin
            // mapping for bits (each bit held for two ticks). We'll follow the mapping used previously.
            case (i2c_clock_cycles)
                // Address byte (write_command) bits 0..15
                0: i2c_sda_state = write_command[7]; 1: i2c_sda_state = write_command[7];
                2: i2c_sda_state = write_command[6]; 3: i2c_sda_state = write_command[6];
                4: i2c_sda_state = write_command[5]; 5: i2c_sda_state = write_command[5];
                6: i2c_sda_state = write_command[4]; 7: i2c_sda_state = write_command[4];
                8: i2c_sda_state = write_command[3]; 9: i2c_sda_state = write_command[3];
                10: i2c_sda_state = write_command[2]; 11: i2c_sda_state = write_command[2];
                12: i2c_sda_state = write_command[1]; 13: i2c_sda_state = write_command[1];
                14: i2c_sda_state = write_command[0]; 15: i2c_sda_state = write_command[0];
                // 16..17 are ACK sampling (master releases SDA)

                // Pointer_config (0x01)
                18: i2c_sda_state = pointer_config[7]; 19: i2c_sda_state = pointer_config[7];
                20: i2c_sda_state = pointer_config[6]; 21: i2c_sda_state = pointer_config[6];
                22: i2c_sda_state = pointer_config[5]; 23: i2c_sda_state = pointer_config[5];
                24: i2c_sda_state = pointer_config[4]; 25: i2c_sda_state = pointer_config[4];
                26: i2c_sda_state = pointer_config[3]; 27: i2c_sda_state = pointer_config[3];
                28: i2c_sda_state = pointer_config[2]; 29: i2c_sda_state = pointer_config[2];
                30: i2c_sda_state = pointer_config[1]; 31: i2c_sda_state = pointer_config[1];
                32: i2c_sda_state = pointer_config[0]; 33: i2c_sda_state = pointer_config[0];
                // 34..35 ACK

                // Config MSB
                36: i2c_sda_state = write_configuration_1[7]; 37: i2c_sda_state = write_configuration_1[7];
                38: i2c_sda_state = write_configuration_1[6]; 39: i2c_sda_state = write_configuration_1[6];
                40: i2c_sda_state = write_configuration_1[5]; 41: i2c_sda_state = write_configuration_1[5];
                42: i2c_sda_state = write_configuration_1[4]; 43: i2c_sda_state = write_configuration_1[4];
                44: i2c_sda_state = write_configuration_1[3]; 45: i2c_sda_state = write_configuration_1[3];
                46: i2c_sda_state = write_configuration_1[2]; 47: i2c_sda_state = write_configuration_1[2];
                48: i2c_sda_state = write_configuration_1[1]; 49: i2c_sda_state = write_configuration_1[1];
                50: i2c_sda_state = write_configuration_1[0]; 51: i2c_sda_state = write_configuration_1[0];
                // 52..53 ACK

                // Config LSB
                54: i2c_sda_state = write_configuration_2[7]; 55: i2c_sda_state = write_configuration_2[7];
                56: i2c_sda_state = write_configuration_2[6]; 57: i2c_sda_state = write_configuration_2[6];
                58: i2c_sda_state = write_configuration_2[5]; 59: i2c_sda_state = write_configuration_2[5];
                60: i2c_sda_state = write_configuration_2[4]; 61: i2c_sda_state = write_configuration_2[4];
                62: i2c_sda_state = write_configuration_2[3]; 63: i2c_sda_state = write_configuration_2[3];
                64: i2c_sda_state = write_configuration_2[2]; 65: i2c_sda_state = write_configuration_2[2];
                66: i2c_sda_state = write_configuration_2[1]; 67: i2c_sda_state = write_configuration_2[1];
                68: i2c_sda_state = write_configuration_2[0]; 69: i2c_sda_state = write_configuration_2[0];
                // 70..71 ACK
                default: i2c_sda_state = 1'b1;
            endcase
        end

        // PRE-READ pointer write (ADDR + pointer_conv)
        S_WRITE_PRE_READ: begin
            case (i2c_clock_cycles)
                0: i2c_sda_state = write_command[7]; 1: i2c_sda_state = write_command[7];
                2: i2c_sda_state = write_command[6]; 3: i2c_sda_state = write_command[6];
                4: i2c_sda_state = write_command[5]; 5: i2c_sda_state = write_command[5];
                6: i2c_sda_state = write_command[4]; 7: i2c_sda_state = write_command[4];
                8: i2c_sda_state = write_command[3]; 9: i2c_sda_state = write_command[3];
                10: i2c_sda_state = write_command[2]; 11: i2c_sda_state = write_command[2];
                12: i2c_sda_state = write_command[1]; 13: i2c_sda_state = write_command[1];
                14: i2c_sda_state = write_command[0]; 15: i2c_sda_state = write_command[0];
                // 16..17 ack
                18: i2c_sda_state = pointer_conv[7]; 19: i2c_sda_state = pointer_conv[7];
                20: i2c_sda_state = pointer_conv[6]; 21: i2c_sda_state = pointer_conv[6];
                22: i2c_sda_state = pointer_conv[5]; 23: i2c_sda_state = pointer_conv[5];
                24: i2c_sda_state = pointer_conv[4]; 25: i2c_sda_state = pointer_conv[4];
                26: i2c_sda_state = pointer_conv[3]; 27: i2c_sda_state = pointer_conv[3];
                28: i2c_sda_state = pointer_conv[2]; 29: i2c_sda_state = pointer_conv[2];
                30: i2c_sda_state = pointer_conv[1]; 31: i2c_sda_state = pointer_conv[1];
                32: i2c_sda_state = pointer_conv[0]; 33: i2c_sda_state = pointer_conv[0];
                // 34..35 ack
                default: i2c_sda_state = 1'b1;
            endcase
        end

        // READ: master drives address+R then releases; master drives ACK/NACK at specified slots
        S_READ: begin
            case (i2c_clock_cycles)
                0: i2c_sda_state = read_command[7]; 1: i2c_sda_state = read_command[7];
                2: i2c_sda_state = read_command[6]; 3: i2c_sda_state = read_command[6];
                4: i2c_sda_state = read_command[5]; 5: i2c_sda_state = read_command[5];
                6: i2c_sda_state = read_command[4]; 7: i2c_sda_state = read_command[4];
                8: i2c_sda_state = read_command[3]; 9: i2c_sda_state = read_command[3];
                10: i2c_sda_state = read_command[2]; 11: i2c_sda_state = read_command[2];
                12: i2c_sda_state = read_command[1]; 13: i2c_sda_state = read_command[1];
                14: i2c_sda_state = read_command[0]; 15: i2c_sda_state = read_command[0];
                // 16..17 ack from slave
                // Slave drives data bytes (we tri-state) - master ACK after first byte
                34: i2c_sda_state = 1'b0; 35: i2c_sda_state = 1'b0; // ACK
                // NACK after final byte (master drives high)
                52: i2c_sda_state = 1'b1; 53: i2c_sda_state = 1'b1;
                default: i2c_sda_state = 1'b1;
            endcase
        end

        S_STOP_WR, S_STOP_WR_READY, S_STOP_WR_STABLE,
        S_STOP_WR_PRE_READ, S_STOP_WR_PRE_READ_RDY, S_STOP_WR_PRE_READ_STAB,
        S_STOP_READ, S_STOP_READ_READY, S_STOP_READ_STABLE:
            i2c_sda_state = 1'b1;

        default: i2c_sda_state = 1'b1;
    endcase
end

// Capture incoming data during READ (use read_I2C_SDA)
always @ (posedge i2c_sclk_local_200khz) begin
    if (presentState == S_READ && i2c_sclk_local_output == 1'b1 && sda_out_en == 1'b0) begin
        case (i2c_clock_cycles)
            // high byte
            19: lux_byte_high[7] <= read_I2C_SDA;
            21: lux_byte_high[6] <= read_I2C_SDA;
            23: lux_byte_high[5] <= read_I2C_SDA;
            25: lux_byte_high[4] <= read_I2C_SDA;
            27: lux_byte_high[3] <= read_I2C_SDA;
            29: lux_byte_high[2] <= read_I2C_SDA;
            31: lux_byte_high[1] <= read_I2C_SDA;
            33: lux_byte_high[0] <= read_I2C_SDA;
            // low byte
            37: lux_byte_low[7] <= read_I2C_SDA;
            39: lux_byte_low[6] <= read_I2C_SDA;
            41: lux_byte_low[5] <= read_I2C_SDA;
            43: lux_byte_low[4] <= read_I2C_SDA;
            45: lux_byte_low[3] <= read_I2C_SDA;
            47: lux_byte_low[2] <= read_I2C_SDA;
            49: lux_byte_low[1] <= read_I2C_SDA;
            51: lux_byte_low[0] <= read_I2C_SDA;
            default: ;
        endcase
    end
end

// Update lux_value and valid flag
always @ (posedge i2c_sclk_local_200khz) begin
    if (!reset_n) begin
        lux_value <= 16'd0;
        lux_valid <= 1'b0;
    end else if (presentState == S_STOP_READ && nextState == S_STOP_READ_READY) begin
        lux_value <= {lux_byte_high, lux_byte_low};
        lux_valid <= 1'b1;
    end else if (presentState == S_STOP_READ_STABLE && counter_last == 32'd0) begin
        lux_valid <= 1'b0;
    end
end

// I2C_SCLK generation and cycle counters (driven by FSM)
always @ (posedge i2c_sclk_local_200khz) begin
    case (presentState)
        S_RESET: i2c_sclk_local_output <= 1'b1;
        S_WAIT_RDWR: i2c_sclk_local_output <= 1'b1;

        S_START_WR: i2c_sclk_local_output <= 1'b1;
        S_START_WR_READY: i2c_sclk_local_output <= 1'b0;
        S_START_WR_STABLE: i2c_sclk_local_output <= i2c_sclk_local_output;
        S_WRITE: begin
            i2c_clock_cycles <= (i2c_clock_cycles + 8'd1) % 72; // covers up to 72 cycles used in WRITE mapping
            i2c_sclk_local_output <= ~i2c_sclk_local_output;
        end
        S_STOP_WR, S_STOP_WR_READY: i2c_sclk_local_output <= 1'b1;
        S_STOP_WR_STABLE: i2c_sclk_local_output <= 1'b0;

        S_WAIT_CONVERSION: i2c_sclk_local_output <= 1'b0;
        //Wait 9 ms then begin preread
        S_START_WR_PRE_READ: i2c_sclk_local_output <= 1'b1;
        S_START_WR_PRE_READ_RDY: i2c_sclk_local_output <= 1'b1;
        S_START_WR_PRE_READ_STAB: i2c_sclk_local_output <= i2c_sclk_local_output;
        S_WRITE_PRE_READ: begin
            i2c_clock_cycles <= (i2c_clock_cycles + 8'd1) % 36;
            i2c_sclk_local_output <= ~i2c_sclk_local_output;
        end
        S_STOP_WR_PRE_READ, S_STOP_WR_PRE_READ_RDY: i2c_sclk_local_output <= 1'b1;
        S_STOP_WR_PRE_READ_STAB: i2c_sclk_local_output <= i2c_sclk_local_output;

        S_START_READ: i2c_sclk_local_output <= 1'b1;
        S_START_READ_READY: i2c_sclk_local_output <= 1'b0;
        S_START_READ_STABLE: i2c_sclk_local_output <= i2c_sclk_local_output;
        S_READ: begin
            i2c_clock_cycles <= (i2c_clock_cycles + 8'd1) % 54;
            i2c_sclk_local_output <= ~i2c_sclk_local_output;
        end
        S_STOP_READ, S_STOP_READ_READY: i2c_sclk_local_output <= 1'b1;
        S_STOP_READ_STABLE: begin
            if (counter_last >= WAIT_CYCLES) counter_last <= 32'd0;
            else counter_last <= counter_last + 32'd1;
            i2c_sclk_local_output <= i2c_sclk_local_output;
        end

        default: i2c_sclk_local_output <= 1'b1;
    endcase
end

// State transition logic
always @ (*) begin
    case (presentState)
        S_RESET: nextState = S_WAIT_RDWR;
        S_WAIT_RDWR: nextState = S_START_WR;

        // WRITE config
        S_START_WR: nextState = S_START_WR_READY;
        S_START_WR_READY: nextState = S_START_WR_STABLE;
        S_START_WR_STABLE: nextState = S_WRITE;
        S_WRITE: if (i2c_clock_cycles == 8'd71) nextState = S_STOP_WR; else nextState = S_WRITE;
        S_STOP_WR: nextState = S_STOP_WR_READY;
        S_STOP_WR_READY: nextState = S_STOP_WR_STABLE;
        S_STOP_WR_STABLE: nextState = S_WAIT_CONVERSION;

        S_WAIT_CONVERSION: if(counter >= 19'd450_000) nextState = S_START_WR_PRE_READ; else nextState = S_WAIT_CONVERSION;
        // PRE-READ pointer write
        S_START_WR_PRE_READ: nextState = S_START_WR_PRE_READ_RDY;
        S_START_WR_PRE_READ_RDY: nextState = S_START_WR_PRE_READ_STAB;
        S_START_WR_PRE_READ_STAB: nextState = S_WRITE_PRE_READ;
        S_WRITE_PRE_READ: if (i2c_clock_cycles == 8'd35) nextState = S_STOP_WR_PRE_READ; else nextState = S_WRITE_PRE_READ;
        S_STOP_WR_PRE_READ: nextState = S_STOP_WR_PRE_READ_RDY;
        S_STOP_WR_PRE_READ_RDY: nextState = S_STOP_WR_PRE_READ_STAB;
        S_STOP_WR_PRE_READ_STAB: nextState = S_START_READ;

        // READ
        S_START_READ: nextState = S_START_READ_READY;
        S_START_READ_READY: nextState = S_START_READ_STABLE;
        S_START_READ_STABLE: nextState = S_READ;
        S_READ: if (i2c_clock_cycles == 8'd53) nextState = S_STOP_READ; else nextState = S_READ;
        S_STOP_READ: nextState = S_STOP_READ_READY;
        S_STOP_READ_READY: nextState = S_STOP_READ_STABLE;
        S_STOP_READ_STABLE: if (counter_last == WAIT_CYCLES) nextState = S_START_READ; else nextState = S_STOP_READ_STABLE;

        default: nextState = S_RESET;
    endcase
end

// Core signal assignments
assign I2C_SCLK = i2c_sclk_local_output;
assign I2C_SDA  = sda_out_en ? i2c_sda_state : 1'bz;
assign I2C_SCLK_Ref = i2c_sclk_local;
assign I2C_SCLK_Ref_200k = i2c_sclk_local_200khz;

// debug outputs
assign presentState_output = presentState;
assign i2c_clock_cycles_output = i2c_clock_cycles;
assign i2c_bit_count_output = i2c_clock_cycles / 8'd2;
assign sda_out_en_output = sda_out_en;
assign counter_last_output = counter_last;

endmodule
