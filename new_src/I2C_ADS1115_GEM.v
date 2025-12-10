module I2C_ADS1115(
    input   system_clock,
    input   reset_n,
     
    // Core Signals
    output  I2C_SCLK,
    inout   I2C_SDA,
     
    // ADC Output
    output reg [15:0] adc_value,
    output reg        adc_valid,
     
    // Debug Signals
    output          I2C_SCLK_Ref,
    output          I2C_SCLK_Ref_200k,
    output  [5:0]   presentState_output,
    output  [7:0]   i2c_clock_cycles_output,
    output  [7:0]   i2c_bit_count_output,
    output          sda_out_en_output,
    input           read_I2C_SDA,
    input           read_I2C_SCLK,
    output  [31:0]  counter_last_output
);

// -------------------------------------------------------------------------
// State Machine States
// -------------------------------------------------------------------------
localparam RESET                     = 6'd0;
localparam WAIT_START                = 6'd1;

// --- STEP 1: WRITE CONFIGURATION ---
localparam START_WR_CONFIG           = 6'd2;
localparam START_WR_CONFIG_RDY       = 6'd3;
localparam START_WR_CONFIG_STB       = 6'd4;
localparam WRITE_CONFIG              = 6'd5;
localparam STOP_WR_CONFIG            = 6'd6;
localparam STOP_WR_CONFIG_RDY        = 6'd7;
localparam STOP_WR_CONFIG_STB        = 6'd8;

// --- STEP 2: WAIT FOR CONVERSION ---
localparam WAIT_CONVERSION           = 6'd9;

// --- STEP 3: WRITE READ POINTER ---
localparam START_WR_PTR              = 6'd10;
localparam START_WR_PTR_RDY          = 6'd11;
localparam START_WR_PTR_STB          = 6'd12;
localparam WRITE_PTR                 = 6'd13;

// --- THE FIX IS FOCUSED HERE (States 14-16) ---
localparam STOP_WR_PTR               = 6'd14; // SCL Low, SDA -> Low
localparam STOP_WR_PTR_RDY           = 6'd15; // SCL High, SDA Low
localparam STOP_WR_PTR_STB           = 6'd16; // SCL High, SDA -> High (STOP)

// --- AND HERE (States 17-19) ---
localparam START_READ                = 6'd17; // SCL High, SDA High (Idle)
localparam START_READ_READY          = 6'd18; // SCL High, SDA -> Low (START)
localparam START_READ_STABLE         = 6'd19; // SCL Low, SDA Low (Ready to Tx)

// --- STEP 4: READ DATA ---
localparam READ_DATA                 = 6'd20;
localparam STOP_READ                 = 6'd21;
localparam STOP_READ_READY           = 6'd22;
localparam STOP_READ_STABLE          = 6'd23;

// -------------------------------------------------------------------------
// Registers and Counters
// -------------------------------------------------------------------------
reg [5:0]   presentState            = RESET;
reg [5:0]   nextState               = RESET;

reg [31:0]  count                   = 32'd0; 
reg [31:0]  count_2                 = 32'd0; 

reg         i2c_sclk_local          = 1'b1;
reg         i2c_sclk_local_200khz   = 1'b1;
reg         i2c_sclk_local_output   = 1'b1;
reg         sda_out_en              = 1'b1; 
reg [7:0]   i2c_clock_cycles        = 8'd0;
reg         i2c_sda_state           = 1'b1;
reg [31:0]  counter_last            = 32'd0; 

// Data capture
reg [7:0]   adc_byte_high           = 8'd0;
reg [7:0]   adc_byte_low            = 8'd0;

// -------------------------------------------------------------------------
// ADS1115 Commands and Config
// -------------------------------------------------------------------------
reg [7:0] cmd_write      = {7'b100_1000, 1'b0}; // 0x90
reg [7:0] cmd_read       = {7'b100_1000, 1'b1}; // 0x91
reg [7:0] ptr_convert    = 8'h00; 
reg [7:0] ptr_config     = 8'h01; 
reg [7:0] config_msb     = 8'hC5; 
reg [7:0] config_lsb     = 8'h83; 

// Conversion Delay
localparam [31:0] CONVERSION_DELAY = 32'd9000; 

// -------------------------------------------------------------------------
// Clock Generation (Same as before)
// -------------------------------------------------------------------------
always @ (posedge system_clock) begin
    if(count == 50) begin
         i2c_sclk_local <= ~i2c_sclk_local;
         count <= 32'd1;
    end else count <= count + 32'd1;
end

always @ (posedge system_clock) begin
    if(count_2 == 25) begin
         i2c_sclk_local_200khz <= ~i2c_sclk_local_200khz;
         count_2 <= 32'd1;
    end else count_2 <= count_2 + 32'd1;
end

// -------------------------------------------------------------------------
// State Machine Transition
// -------------------------------------------------------------------------
always @ (posedge i2c_sclk_local_200khz) begin
    if(!reset_n) presentState <= RESET;
    else presentState <= nextState;
end

// -------------------------------------------------------------------------
// SDA Direction Control
// -------------------------------------------------------------------------
always @ (*) begin
    case(presentState)
        WRITE_CONFIG: begin
            if( (i2c_clock_cycles >= 16 && i2c_clock_cycles <= 17) ||
                (i2c_clock_cycles >= 34 && i2c_clock_cycles <= 35) ||
                (i2c_clock_cycles >= 52 && i2c_clock_cycles <= 53) ||
                (i2c_clock_cycles >= 70 && i2c_clock_cycles <= 71) )
                sda_out_en = 1'b0; // ACK
            else sda_out_en = 1'b1;
        end
        
        WRITE_PTR: begin
            if( (i2c_clock_cycles >= 16 && i2c_clock_cycles <= 17) ||
                (i2c_clock_cycles >= 34 && i2c_clock_cycles <= 35) )
                sda_out_en = 1'b0; // ACK
            else sda_out_en = 1'b1;
        end
        
        READ_DATA: begin
            if( i2c_clock_cycles <= 15 ) sda_out_en = 1'b1;       
            else if (i2c_clock_cycles >= 34 && i2c_clock_cycles <= 35) sda_out_en = 1'b1; 
            else if (i2c_clock_cycles >= 52 && i2c_clock_cycles <= 53) sda_out_en = 1'b1; 
            else sda_out_en = 1'b0; 
        end
        
        default: sda_out_en = 1'b1;
    endcase
end

// -------------------------------------------------------------------------
// Data Capture Logic
// -------------------------------------------------------------------------
always @ (posedge i2c_sclk_local_200khz) begin
    if(presentState == READ_DATA && i2c_sclk_local_output == 1'b1 && sda_out_en == 1'b0) begin
        case(i2c_clock_cycles)
            19: adc_byte_high[7] <= I2C_SDA; 21: adc_byte_high[6] <= I2C_SDA;
            23: adc_byte_high[5] <= I2C_SDA; 25: adc_byte_high[4] <= I2C_SDA;
            27: adc_byte_high[3] <= I2C_SDA; 29: adc_byte_high[2] <= I2C_SDA;
            31: adc_byte_high[1] <= I2C_SDA; 33: adc_byte_high[0] <= I2C_SDA;
            
            37: adc_byte_low[7] <= I2C_SDA;  39: adc_byte_low[6] <= I2C_SDA;
            41: adc_byte_low[5] <= I2C_SDA;  43: adc_byte_low[4] <= I2C_SDA;
            45: adc_byte_low[3] <= I2C_SDA;  47: adc_byte_low[2] <= I2C_SDA;
            49: adc_byte_low[1] <= I2C_SDA;  51: adc_byte_low[0] <= I2C_SDA;
        endcase
    end
end

always @ (posedge i2c_sclk_local_200khz) begin
    if(!reset_n) begin
        adc_value <= 16'd0;
        adc_valid <= 1'b0;
    end
    else if(presentState == STOP_READ && nextState == STOP_READ_READY) begin
        adc_value <= {adc_byte_high, adc_byte_low};
        adc_valid <= 1'b1;
    end
    else if(presentState == STOP_READ_STABLE) begin
        adc_valid <= 1'b0;
    end
end

// -------------------------------------------------------------------------
// I2C SDA Output Generation
// -------------------------------------------------------------------------
always @ (*) begin
    i2c_sda_state = 1'b1; 

    case(presentState)
        // General Start/Stop Conditions
        RESET, WAIT_START, WAIT_CONVERSION: i2c_sda_state = 1'b1;

        // Config Write Start/Stop
        START_WR_CONFIG: i2c_sda_state = 1'b1;
        START_WR_CONFIG_RDY, START_WR_CONFIG_STB: i2c_sda_state = 1'b0;
        STOP_WR_CONFIG, STOP_WR_CONFIG_RDY: i2c_sda_state = 1'b0;
        STOP_WR_CONFIG_STB: i2c_sda_state = 1'b1;

        // Pointer Write Start
        START_WR_PTR: i2c_sda_state = 1'b1;
        START_WR_PTR_RDY, START_WR_PTR_STB: i2c_sda_state = 1'b0;

        // --------------------------------------------------------
        // FIX: SDA LOGIC FOR STOP POINTER AND START READ (States 14-19)
        // --------------------------------------------------------
        // State 14: SCL=0, SDA=0. (Prepare for STOP)
        STOP_WR_PTR:         i2c_sda_state = 1'b0; 
        
        // State 15: SCL=1, SDA=0. (SDA holds Low while SCL rises)
        STOP_WR_PTR_RDY:     i2c_sda_state = 1'b0; 
        
        // State 16: SCL=1, SDA=1. (SDA rises while SCL is High) -> VALID STOP
        STOP_WR_PTR_STB:     i2c_sda_state = 1'b1; 

        // State 17: SCL=1, SDA=1. (Bus Idle / Gap)
        START_READ:          i2c_sda_state = 1'b1; 
        
        // State 18: SCL=1, SDA=0. (SDA falls while SCL is High) -> VALID START
        START_READ_READY:    i2c_sda_state = 1'b0; 
        
        // State 19: SCL=0, SDA=0. (SCL falls to prepare for data)
        START_READ_STABLE:   i2c_sda_state = 1'b0;
        // --------------------------------------------------------

        // Read Stop
        STOP_READ, STOP_READ_READY: i2c_sda_state = 1'b0;
        STOP_READ_STABLE: i2c_sda_state = 1'b1;

        // Data Writing Sequences
        WRITE_CONFIG: begin
             // (Logic same as previous - Address, Pointer, MSB, LSB)
             case(i2c_clock_cycles)
                0,1: i2c_sda_state = cmd_write[7];   2,3: i2c_sda_state = cmd_write[6];
                4,5: i2c_sda_state = cmd_write[5];   6,7: i2c_sda_state = cmd_write[4];
                8,9: i2c_sda_state = cmd_write[3];   10,11: i2c_sda_state = cmd_write[2];
                12,13: i2c_sda_state = cmd_write[1]; 14,15: i2c_sda_state = cmd_write[0];
                18,19: i2c_sda_state = ptr_config[7]; 20,21: i2c_sda_state = ptr_config[6];
                22,23: i2c_sda_state = ptr_config[5]; 24,25: i2c_sda_state = ptr_config[4];
                26,27: i2c_sda_state = ptr_config[3]; 28,29: i2c_sda_state = ptr_config[2];
                30,31: i2c_sda_state = ptr_config[1]; 32,33: i2c_sda_state = ptr_config[0];
                36,37: i2c_sda_state = config_msb[7]; 38,39: i2c_sda_state = config_msb[6];
                40,41: i2c_sda_state = config_msb[5]; 42,43: i2c_sda_state = config_msb[4];
                44,45: i2c_sda_state = config_msb[3]; 46,47: i2c_sda_state = config_msb[2];
                48,49: i2c_sda_state = config_msb[1]; 50,51: i2c_sda_state = config_msb[0];
                54,55: i2c_sda_state = config_lsb[7]; 56,57: i2c_sda_state = config_lsb[6];
                58,59: i2c_sda_state = config_lsb[5]; 60,61: i2c_sda_state = config_lsb[4];
                62,63: i2c_sda_state = config_lsb[3]; 64,65: i2c_sda_state = config_lsb[2];
                66,67: i2c_sda_state = config_lsb[1]; 68,69: i2c_sda_state = config_lsb[0];
                default: i2c_sda_state = 1'b1; 
            endcase
        end

        WRITE_PTR: begin
            // (Logic same as previous - Address, Pointer)
            case(i2c_clock_cycles)
                0,1: i2c_sda_state = cmd_write[7];   2,3: i2c_sda_state = cmd_write[6];
                4,5: i2c_sda_state = cmd_write[5];   6,7: i2c_sda_state = cmd_write[4];
                8,9: i2c_sda_state = cmd_write[3];   10,11: i2c_sda_state = cmd_write[2];
                12,13: i2c_sda_state = cmd_write[1]; 14,15: i2c_sda_state = cmd_write[0];
                18,19: i2c_sda_state = ptr_convert[7]; 20,21: i2c_sda_state = ptr_convert[6];
                22,23: i2c_sda_state = ptr_convert[5]; 24,25: i2c_sda_state = ptr_convert[4];
                26,27: i2c_sda_state = ptr_convert[3]; 28,29: i2c_sda_state = ptr_convert[2];
                30,31: i2c_sda_state = ptr_convert[1]; 32,33: i2c_sda_state = ptr_convert[0];
                default: i2c_sda_state = 1'b1;
            endcase
        end

        READ_DATA: begin
             case(i2c_clock_cycles)
                0,1: i2c_sda_state = cmd_read[7];   2,3: i2c_sda_state = cmd_read[6];
                4,5: i2c_sda_state = cmd_read[5];   6,7: i2c_sda_state = cmd_read[4];
                8,9: i2c_sda_state = cmd_read[3];   10,11: i2c_sda_state = cmd_read[2];
                12,13: i2c_sda_state = cmd_read[1]; 14,15: i2c_sda_state = cmd_read[0];
                34,35: i2c_sda_state = 1'b0; // ACK
                52,53: i2c_sda_state = 1'b1; // NACK
                default: i2c_sda_state = 1'b1;
            endcase
        end
        default: i2c_sda_state = 1'b1;
    endcase
end

// -------------------------------------------------------------------------
// SCLK Generation & Counter Management
// -------------------------------------------------------------------------
// -------------------------------------------------------------------------
// 1. Counter Management (Sequential - Updates on Clock Edge)
// -------------------------------------------------------------------------
always @ (posedge i2c_sclk_local_200khz) begin
    // Default: Increment wait counter if needed
    if(presentState == WAIT_CONVERSION || presentState == STOP_READ_STABLE) begin
         if(presentState == WAIT_CONVERSION && counter_last < CONVERSION_DELAY) 
             counter_last <= counter_last + 1;
         else if (presentState == STOP_READ_STABLE && counter_last < 32'd20000) 
             counter_last <= counter_last + 1;
         else 
             counter_last <= 0;
    end else begin
         counter_last <= 0;
    end

    // Cycle Counters for Read/Write Ops
    case(presentState)
        WRITE_CONFIG: i2c_clock_cycles <= (i2c_clock_cycles + 1) % 72; 
        WRITE_PTR:    i2c_clock_cycles <= (i2c_clock_cycles + 1) % 36; 
        READ_DATA:    i2c_clock_cycles <= (i2c_clock_cycles + 1) % 54; 
        default:      i2c_clock_cycles <= 0; // Reset counter in other states
    endcase
end


// -------------------------------------------------------------------------
// 2. SCLK Generation (Combinational - Updates Immediately with State)
// -------------------------------------------------------------------------
always @ (*) begin
    case(presentState)
        // Idle / Setup States
        RESET, WAIT_START, WAIT_CONVERSION: i2c_sclk_local_output = 1'b1;

        // --- STEP 1: CONFIG WRITE ---
        START_WR_CONFIG:        i2c_sclk_local_output = 1'b1;
        START_WR_CONFIG_RDY:    i2c_sclk_local_output = 1'b1; // Start setup
        START_WR_CONFIG_STB:    i2c_sclk_local_output = 1'b0; // Start falling edge
        WRITE_CONFIG:           i2c_sclk_local_output = i2c_clock_cycles[0]; // Toggle: 0=Low, 1=High
        STOP_WR_CONFIG:         i2c_sclk_local_output = 1'b0;
        STOP_WR_CONFIG_RDY:     i2c_sclk_local_output = 1'b1;
        STOP_WR_CONFIG_STB:     i2c_sclk_local_output = 1'b1;

        // --- STEP 3: POINTER WRITE ---
        START_WR_PTR:           i2c_sclk_local_output = 1'b1;
        START_WR_PTR_RDY:       i2c_sclk_local_output = 1'b1;
        START_WR_PTR_STB:       i2c_sclk_local_output = 1'b0;
        WRITE_PTR:              i2c_sclk_local_output = i2c_clock_cycles[0]; // Toggle: 0=Low, 1=High

        // --- FIX: STOP Condition Timing ---
        // State 14: SCL Low (Setup SDA)
        STOP_WR_PTR:            i2c_sclk_local_output = 1'b0; 
        // State 15: SCL High (Hold SDA Low -> Setup)
        STOP_WR_PTR_RDY:        i2c_sclk_local_output = 1'b1; 
        // State 16: SCL High (SDA Rises -> STOP)
        STOP_WR_PTR_STB:        i2c_sclk_local_output = 1'b1; 

        // --- STEP 4: READ DATA ---
        START_READ:             i2c_sclk_local_output = 1'b1;
        START_READ_READY:       i2c_sclk_local_output = 1'b1;
        START_READ_STABLE:      i2c_sclk_local_output = 1'b0;
        READ_DATA:              i2c_sclk_local_output = i2c_clock_cycles[0]; // Toggle
        STOP_READ:              i2c_sclk_local_output = 1'b0;
        STOP_READ_READY:        i2c_sclk_local_output = 1'b1;
        STOP_READ_STABLE:       i2c_sclk_local_output = 1'b1;

        default: i2c_sclk_local_output = 1'b1;
    endcase
end

// -------------------------------------------------------------------------
// Next State Logic (Same as before)
// -------------------------------------------------------------------------
always @ (*) begin
    case(presentState)
        RESET: nextState = WAIT_START;
        WAIT_START: nextState = START_WR_CONFIG;

        // Sequence 1: Write Config
        START_WR_CONFIG:        nextState = START_WR_CONFIG_RDY;
        START_WR_CONFIG_RDY:    nextState = START_WR_CONFIG_STB;
        START_WR_CONFIG_STB:    nextState = WRITE_CONFIG;
        WRITE_CONFIG:           if(i2c_clock_cycles == 71) nextState = STOP_WR_CONFIG;
                                else nextState = WRITE_CONFIG;
        STOP_WR_CONFIG:         nextState = STOP_WR_CONFIG_RDY;
        STOP_WR_CONFIG_RDY:     nextState = STOP_WR_CONFIG_STB;
        STOP_WR_CONFIG_STB:     nextState = WAIT_CONVERSION;

        // Sequence 2: Wait for Conversion
        WAIT_CONVERSION:        if(counter_last >= CONVERSION_DELAY) nextState = START_WR_PTR;
                                else nextState = WAIT_CONVERSION;

        // Sequence 3: Set Pointer to 0x00
        START_WR_PTR:           nextState = START_WR_PTR_RDY;
        START_WR_PTR_RDY:       nextState = START_WR_PTR_STB;
        START_WR_PTR_STB:       nextState = WRITE_PTR;
        WRITE_PTR:              if(i2c_clock_cycles == 35) nextState = STOP_WR_PTR;
                                else nextState = WRITE_PTR;

        // FIX: Ensure transitions for 14-19
        STOP_WR_PTR:            nextState = STOP_WR_PTR_RDY;
        STOP_WR_PTR_RDY:        nextState = STOP_WR_PTR_STB;
        STOP_WR_PTR_STB:        nextState = START_READ;

        START_READ:             nextState = START_READ_READY;
        START_READ_READY:       nextState = START_READ_STABLE;
        START_READ_STABLE:      nextState = READ_DATA;

        READ_DATA:              if(i2c_clock_cycles == 53) nextState = STOP_READ;
                                else nextState = READ_DATA;
        STOP_READ:              nextState = STOP_READ_READY;
        STOP_READ_READY:        nextState = STOP_READ_STABLE;
        STOP_READ_STABLE:       if(counter_last == 0) nextState = WAIT_START; 
                                else nextState = STOP_READ_STABLE;
                                
        default: nextState = RESET;
    endcase
end

// Signal Assignments
assign I2C_SCLK = i2c_sclk_local_output;
assign I2C_SDA  = sda_out_en ? i2c_sda_state : 1'bz;
assign I2C_SCLK_Ref = i2c_sclk_local;
assign I2C_SCLK_Ref_200k = i2c_sclk_local_200khz;

// Debug
assign presentState_output = presentState;
assign i2c_clock_cycles_output = i2c_clock_cycles;
assign i2c_bit_count_output = i2c_clock_cycles / 2;
assign sda_out_en_output = sda_out_en;
assign counter_last_output = counter_last;

endmodule