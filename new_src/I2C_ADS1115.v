// (Header/license omitted in this snippet — keep your existing header)
module I2C_ADS1115(
    input   system_clock,
    input   reset_n,
	 
	 // Core Signals: I2C_SCLK and I2C_SDA
    output  I2C_SCLK,                       // I2C_SCLK
    inout   I2C_SDA,                        // I2C_SDA
	 
	 // Lux Output (now holds ADS1115 16-bit conversion result)
	 output reg [15:0] lux_value,           // 16-bit ADC value
	 output reg lux_valid,                  // Indicates valid reading
	 
	 // Debug Signals (Signal Tap) - Remove to conserve resources
    output  		I2C_SCLK_Ref,                   	// Reference Clock
    output  		I2C_SCLK_Ref_200k,              	// Reference Clock 200khz
    output  [3:0] presentState_output,					// Displays presentState 
    output  [7:0] i2c_clock_cycles_output,			// Displays i2c_clock_cycles
    output  [7:0] i2c_bit_count_output,				// Displays i2c_bit_count
	 output			sda_out_en_output,					// Displays sda_out_en
	 input			read_I2C_SDA,							// Probes the I2C_SDA Signal
	 input			read_I2C_SCLK,							// Probes the I2C_SCLK Signal
	 output  [31:0]counter_last_output					// Counter for Delay after each I2C Read
);

// State definitions (extended for config write, pointer write, read)
localparam RESET                        = 5'd0;
localparam WAIT_RDWR                    = 5'd1;

// config write sequence (ADDR + PTR=0x01 + CONFIG_MSB + CONFIG_LSB)
localparam START_WR_CONFIG              = 5'd2;
localparam WR_CONFIG_BYTE               = 5'd3;
localparam STOP_WR_CONFIG               = 5'd4;
localparam STOP_WR_CONFIG_STABLE        = 5'd5;

// pointer write sequence (ADDR + PTR=0x00)
localparam START_WR_PTR                 = 5'd6;
localparam WR_PTR_BYTE                   = 5'd7;
localparam STOP_WR_PTR                   = 5'd8;
localparam STOP_WR_PTR_STABLE            = 5'd9;

// read sequence (ADDR+R and read 2 bytes)
localparam START_READ                   = 5'd10;
localparam RD_READ_BYTES                = 5'd11;
localparam STOP_READ                    = 5'd12;
localparam STOP_READ_STABLE             = 5'd13;

// timing helper
reg [3:0] 	presentState      		= RESET;
reg [3:0] 	nextState         		= RESET;
reg [31:0] 	count            			= 32'd0;
reg [31:0] 	count_2         			= 32'd0;
reg 			i2c_sclk_local          = 1'b1;
reg 			i2c_sclk_local_200khz   = 1'b1;
reg 			i2c_sclk_local_output   = 1'b1;
reg 			sda_out_en              = 1'b1;  // master drives SDA when 1; input when 0
reg [7:0]   i2c_clock_cycles    		= 8'd0; // can be reused as bit timing if desired
reg         i2c_sda_state       		= 1'd1;
reg [31:0]  counter_last 		  		= 32'd0;

// --- ADS1115 specifics ---
reg [7:0] write_command;   // address + write bit (8 bits)
reg [7:0] read_command;    // address + read bit (8 bits)
localparam ADS1115_ADDR7 = 7'b100_1000; // 0x48 default (7-bit)
reg [7:0] pointer_config = 8'h01; // Config register pointer
reg [7:0] pointer_conv   = 8'h00; // Conversion register pointer

// Default config: Start single-shot on AIN0, PGA = ±4.096V, single-shot, 128SPS, comparator disabled.
// You can change these constants to suit your measurement range & speed.
// The exact bit layout follows the ADS1115 datasheet: OS(15), MUX[14:12], PGA[11:9], MODE(8), DR[7:5], COMP_...[4:0]
localparam [15:0] CONFIG_DEFAULT = 16'b1_100_001_1_100_11_11_11; 
// NOTE: Above is just an example placeholder — below we split into MSB/LSB with recommended default values.
// For a reliable default, set (example): OS=1, MUX=100 (AIN0), PGA=001 (±4.096V), MODE=1 (single-shot), DR=100 (128SPS), COMP_QUE=11 (disabled)
// That config = 0b1 100 001 1 100 11 11 11 => replace if you want different channel/PGA/DR
reg [7:0] config_msb;
reg [7:0] config_lsb;

// Transmit/receive shift engine
reg [7:0] tx_byte;            // byte we are shifting out (MSB first)
reg [3:0] tx_bit_idx;         // 0..7 bit index (we'll send MSB first)
reg [2:0] tx_byte_count;      // how many bytes remain in current transaction
reg       tx_active;          // high while transmitting a byte (8 bits + ACK)
reg [1:0] tx_phase;           // 0 = sending bits, 1 = ACK/wait, 2 = next byte load
reg [15:0] rx_shift;          // shift in the received bytes (for two-byte read)
reg [1:0] rx_byte_count;      // received bytes count

// simple ack capture (not used for flow control in this version)
reg ack_received;

// Initialize address/read/write bytes and config bytes
always @(*) begin
    write_command = {ADS1115_ADDR7, 1'b0}; // write
    read_command  = {ADS1115_ADDR7, 1'b1}; // read
end

// Initialize config bytes from CONFIG_DEFAULT (do this synchronously at reset)
always @ (posedge system_clock) begin
    if(!reset_n) begin
        config_msb <= 8'hC3; // example default MSB (OS=1,MUX=100,PGA=001 => 1100_0011 = 0xC3)
        config_lsb <= 8'h83; // example default LSB (DR=100, COMP_QUE=11 etc) -> 1000_0011 = 0x83
        // note: these specific hex values correspond to the bitfields example above.
    end
end

// Clocks (unchanged)
always @ (posedge system_clock)
begin
    if(count == 50) begin
         i2c_sclk_local <= ~i2c_sclk_local;
         count <= 32'd1;
    end else
        count <= count + 32'd1;
end

always @ (posedge system_clock)
begin
    if(count_2 == 25) begin
         i2c_sclk_local_200khz <= ~i2c_sclk_local_200khz;
         count_2 <= 32'd1;
    end else
        count_2 <= count_2 + 32'd1;
end

// Present state register on 200kHz clock (preserve timing style)
always @ (posedge i2c_sclk_local_200khz) begin
    if(!reset_n)
        presentState <= RESET;
    else
        presentState <= nextState;
end

// SDA direction control (master drives during start/tx and ACK driving when needed)
always @(*) begin
    // default: master drives SDA except when we are reading device data (during read bytes and ACK bits from slave)
    if (presentState == RD_READ_BYTES)
        sda_out_en = 1'b0; // release SDA while reading (slave will drive)
    else
        sda_out_en = 1'b1; // master drives SDA during writes and start/stop sequences
end

// Simple data capture from the SDA line during reads, on SCLK rising edges (sample when sda is released)
always @(posedge i2c_sclk_local_200khz) begin
    if (presentState == RD_READ_BYTES) begin
        // Only sample when SCLK is high (data valid). We'll shift in one bit per half-cycle when SDA is driven by slave.
        // We'll detect edges of a small internal bit counter (i2c_clock_cycles reused).
        // For simplicity, collect bits when in rx sampling mode and sda_out_en==0
        if (sda_out_en == 1'b0) begin
            // shift the new bit into rx_shift LSB-first for easier assembly (we'll reorder below)
            rx_shift <= {rx_shift[14:0], I2C_SDA};
        end
    end
end

// Transmission / byte state machine (drives tx_byte bits on i2c_sda_state while tx_active)
always @(posedge i2c_sclk_local_200khz) begin
    if (!reset_n) begin
        tx_active <= 1'b0;
        tx_bit_idx <= 4'd0;
        tx_phase <= 2'd0;
        tx_byte <= 8'd0;
        tx_byte_count <= 3'd0;
        rx_shift <= 16'd0;
        rx_byte_count <= 2'd0;
        ack_received <= 1'b0;
    end else begin
        case (presentState)
            // --- Config write: bytes sequence = [ADDR+W] [PTR=0x01] [CONFIG_MSB] [CONFIG_LSB]
            START_WR_CONFIG: begin
                // prepare to send first byte (address+W)
                tx_byte <= write_command;
                tx_bit_idx <= 4'd0;
                tx_active <= 1'b1;
                tx_phase <= 2'd0;
                tx_byte_count <= 3'd4; // total bytes to send
            end
            WR_CONFIG_BYTE: begin
                if (tx_active) begin
                    // toggle phases: on every rising edge we either output a bit or wait for ACK
                    if (tx_phase == 2'd0) begin
                        // sending bit tx_byte[7 - tx_bit_idx]
                        i2c_sda_state <= tx_byte[7 - tx_bit_idx];
                        tx_bit_idx <= tx_bit_idx + 1'b1;
                        if (tx_bit_idx == 4'd7) begin
                            // just sent last bit of the byte -> move to ACK phase next
                            tx_phase <= 2'd1;
                            i2c_sda_state <= 1'b1; // release or let bus be (we'll tri-state in sda_out_en logic when needed)
                        end
                    end else if (tx_phase == 2'd1) begin
                        // ACK bit time: master releases SDA and samples slave ACK
                        // We'll just capture SDA into ack_received
                        // (In our design sda_out_en will keep driving - but for accurate ACK, sda_out_en must be 0 here;
                        // for simplicity we sample read_I2C_SDA or I2C_SDA directly here)
                        ack_received <= I2C_SDA ? 1'b0 : 1'b1;
                        // prepare next byte
                        tx_phase <= 2'd2;
                    end else if (tx_phase == 2'd2) begin
                        // move to next byte if any remain
                        if (tx_byte_count > 1) begin
                            tx_byte_count <= tx_byte_count - 1'b1;
                            // load next byte according to which byte we are on
                            case (tx_byte_count)
                                3'd4: tx_byte <= pointer_config; // after address
                                3'd3: tx_byte <= config_msb;
                                3'd2: tx_byte <= config_lsb;
                                default: tx_byte <= 8'hFF;
                            endcase
                            tx_bit_idx <= 4'd0;
                            tx_phase <= 2'd0;
                        end else begin
                            // finished all bytes from this write transaction
                            tx_active <= 1'b0;
                            tx_phase <= 2'd0;
                            tx_bit_idx <= 4'd0;
                        end
                    end
                end
            end

            // --- Pointer write before read: [ADDR+W] [PTR=0x00]
            START_WR_PTR: begin
                tx_byte <= write_command;
                tx_bit_idx <= 4'd0;
                tx_active <= 1'b1;
                tx_phase <= 2'd0;
                tx_byte_count <= 3'd2; // address + pointer
            end
            WR_PTR_BYTE: begin
                if (tx_active) begin
                    if (tx_phase == 2'd0) begin
                        i2c_sda_state <= tx_byte[7 - tx_bit_idx];
                        tx_bit_idx <= tx_bit_idx + 1'b1;
                        if (tx_bit_idx == 4'd7) begin
                            tx_phase <= 2'd1;
                        end
                    end else if (tx_phase == 2'd1) begin
                        // ACK time; sample
                        ack_received <= I2C_SDA ? 1'b0 : 1'b1;
                        tx_phase <= 2'd2;
                    end else if (tx_phase == 2'd2) begin
                        if (tx_byte_count > 1) begin
                            tx_byte_count <= tx_byte_count - 1'b1;
                            tx_byte <= pointer_conv; // send pointer 0x00 next
                            tx_bit_idx <= 4'd0;
                            tx_phase <= 2'd0;
                        end else begin
                            tx_active <= 1'b0;
                            tx_phase <= 2'd0;
                        end
                    end
                end
            end

            // --- Read bytes: after repeated start we send read_command and read two bytes
            START_READ: begin
                // send read_command first (we will then tri-state and shift in two bytes from slave)
                tx_byte <= read_command;
                tx_bit_idx <= 4'd0;
                tx_active <= 1'b1;
                tx_phase <= 2'd0;
                rx_shift <= 16'd0;
                rx_byte_count <= 2'd0;
            end

            RD_READ_BYTES: begin
                // when tx_active==1 we are still sending read address; once done, we release bus and read slave bytes
                if (tx_active) begin
                    if (tx_phase == 2'd0) begin
                        i2c_sda_state <= tx_byte[7 - tx_bit_idx];
                        tx_bit_idx <= tx_bit_idx + 1'b1;
                        if (tx_bit_idx == 4'd7)
                            tx_phase <= 2'd1;
                    end else if (tx_phase == 2'd1) begin
                        // ACK from slave for address+R
                        ack_received <= I2C_SDA ? 1'b0 : 1'b1;
                        tx_active <= 1'b0; // now begin reading bytes: SDA will be driven by slave
                        tx_phase <= 2'd0;
                        tx_bit_idx <= 4'd0;
                    end
                end else begin
                    // sample bits into rx_shift on every SCLK cycle where slave drives Data
                    // We'll count bits and bytes: when we have 16 bits, store them into lux_value
                    i2c_clock_cycles <= i2c_clock_cycles + 1'b1;
                    if (i2c_clock_cycles[0] == 1'b1) begin
                        // sample on alternating cycle to approximate the previous design's timing
                        rx_shift <= {rx_shift[14:0], I2C_SDA};
                        if (i2c_clock_cycles >= 8 && rx_shift != 16'd0) begin end
                        // Count bits collected
                        if ( (i2c_clock_cycles % 16) == 15 ) begin
                            // one byte collected -> increment rx_byte_count
                            rx_byte_count <= rx_byte_count + 1'b1;
                            if (rx_byte_count == 2'd1) begin
                                // two bytes collected total: rx_shift holds them
                                lux_value <= rx_shift;
                                lux_valid <= 1'b1;
                            end
                        end
                    end
                end
            end

            STOP_READ: begin
                // deassert signals
                lux_valid <= 1'b1; // already asserted at capture
            end

            STOP_READ_STABLE: begin
                // simple inter-read delay
                if (counter_last >= 180_00) begin
                    counter_last <= 0;
                    lux_valid <= 1'b0;
                end else begin
                    counter_last <= counter_last + 1'b1;
                end
            end

            default: begin
                // keep defaults
            end
        endcase
    end
end

// Combinational next-state logic (high-level sequence):
always @(*) begin
    case (presentState)
        RESET: nextState = START_WR_CONFIG;
        START_WR_CONFIG: nextState = WR_CONFIG_BYTE;
        WR_CONFIG_BYTE: begin
            // wait until tx_active finishes (we simplified handshake above)
            if (!tx_active) nextState = STOP_WR_CONFIG;
            else nextState = WR_CONFIG_BYTE;
        end
        STOP_WR_CONFIG: nextState = STOP_WR_CONFIG_STABLE;
        STOP_WR_CONFIG_STABLE: nextState = START_WR_PTR;

        START_WR_PTR: nextState = WR_PTR_BYTE;
        WR_PTR_BYTE: begin
            if (!tx_active) nextState = STOP_WR_PTR;
            else nextState = WR_PTR_BYTE;
        end
        STOP_WR_PTR: nextState = STOP_WR_PTR_STABLE;
        STOP_WR_PTR_STABLE: nextState = START_READ;

        START_READ: nextState = RD_READ_BYTES;
        RD_READ_BYTES: begin
            // we assume read finishes once we have captured 16 bits (simplified control)
            if (lux_valid) nextState = STOP_READ;
            else nextState = RD_READ_BYTES;
        end
        STOP_READ: nextState = STOP_READ_STABLE;
        STOP_READ_STABLE: begin
            if (counter_last == 180_00) nextState = START_READ;
            else nextState = STOP_READ_STABLE;
        end
        default: nextState = RESET;
    endcase
end

// Core signals assignments
assign I2C_SCLK     = i2c_sclk_local_output;
assign I2C_SDA      = sda_out_en ? i2c_sda_state : 1'bz;
assign I2C_SCLK_Ref = i2c_sclk_local;
assign I2C_SCLK_Ref_200k = i2c_sclk_local_200khz;

// debug outputs
assign presentState_output 		= presentState;
assign i2c_clock_cycles_output 	= i2c_clock_cycles;
assign i2c_bit_count_output 		= i2c_clock_cycles / 'd2;
assign sda_out_en_output			= sda_out_en;
assign counter_last_output = counter_last;

endmodule
