// The MIT License (MIT)
// 
// Copyright (c) 2025 Dennis Wong Guan Ming 
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

//////////////////////////////////////////////////////////////////////////////////
//
// Engineer: 				Dennis Wong Guan Ming
// Create Date: 			06/02/2025 03:17:47 PM
// Module Name: 			I2C_BH1750
// Sensor Model: 			GY302 - BH1750 Ambient Light Sensor
// Project Description: I2C Interface between FPGA & BH1750 Sensor
// 
//////////////////////////////////////////////////////////////////////////////////

module I2C_BH1750(
    input   system_clock,
    input   reset_n,
	 
	 // Core Signals: I2C_SCLK and I2C_SDA
    output  I2C_SCLK,                       // I2C_SCLK
    inout   I2C_SDA,                        // I2C_SDA
	 
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

// States Machine States
localparam RESET                        = 5'd0;
localparam WAIT_RDWR                    = 5'd1;
localparam START_WR        				 = 5'd2;
localparam START_WR_READY               = 5'd3; 
localparam START_WR_STABLE              = 5'd4;   
localparam WRITE      				   	 = 5'd5;
localparam STOP_WR                      = 5'd6;
localparam STOP_WR_READY                = 5'd7;
localparam STOP_WR_STABLE               = 5'd8;
localparam START_READ                   = 5'd9;
localparam START_READ_READY             = 5'd10;
localparam START_READ_STABLE            = 5'd11;
localparam READ               			 = 5'd12;
localparam STOP_READ                    = 5'd13;
localparam STOP_READ_READY              = 5'd14;
localparam STOP_READ_STABLE             = 5'd15;
   
// Counters and Registers
  reg [3:0] 	presentState      		= RESET;            	// State Machine States 
  reg [3:0] 	nextState         		= RESET;            	// State Machine States 
reg [31:0] 	count            			= 32'd0;            	// Generating 100khz Clock for Reference
reg [31:0] 	count_2         			= 32'd0;            	// Generating 200khz Clock to drive State Machines
reg 			i2c_sclk_local          = 1'b1;             	// The state of the Clock 100khz (HIGH/LOW)
reg 			i2c_sclk_local_200khz   = 1'b1;             	// The state of the Clock 200khz (HIGH/LOW)
reg 			i2c_sclk_local_output   = 1'b1;             	// The state of I2C_SCLK, used in State Machine Output Logic
reg 			sda_out_en              = 1'b1;             	// The SDA_OUT_EN Signal, On for SDA Output to slave, Off for SDA Input from slave
reg [7:0]   i2c_clock_cycles    		= 8'd0;             	// Register for keeping track of number of Clock Cycles elapsed
reg         i2c_sda_state       		= 1'd0;             	// I2C_SDA local register
reg [31:0]  counter_last 		  		= 32'd0;				 	// Counter for Delay after each I2C Read

// COMMANDS
reg [7:0] write_command = {7'b0100_011, 1'b0};  // Concatenate 0x23 and Write bit: 0
reg [7:0] read_command = {7'b0100_011, 1'b1};  	// Concatenate 0x23 and read bit: 1
reg [7:0] write_configuration = 8'h11;

// Creates a 100kHz clock for I2C SCLK
always @ (posedge system_clock)
begin
    if(count == 50)
    begin
         i2c_sclk_local <= ~i2c_sclk_local;
         count <= 32'd1;
    end
    else
        count <= count + 32'd1;
end

// Creates a 200kHz clock for I2C SCLK
always @ (posedge system_clock)
begin
    if(count_2 == 25)
    begin
         i2c_sclk_local_200khz <= ~i2c_sclk_local_200khz;
         count_2 <= 32'd1;
    end
    else
        count_2 <= count_2 + 32'd1;
end


// State Machine Next State Logic 
always @ (posedge i2c_sclk_local_200khz)
begin
    if(!reset_n)
        presentState <= RESET;
    else
        presentState <= nextState;
end

// SDA_OUT_EN Signal: Controls the Configuration of I2C_SDA as an input/output at various State Machine States
always @ (*)
begin
	if(presentState == WRITE)
		begin
			if(i2c_clock_cycles <= 15)
				sda_out_en = 'd1;
			else if (i2c_clock_cycles > 17 && i2c_clock_cycles <= 33)
				sda_out_en = 'd1;
			else
				sda_out_en = 'd0;
		end
	else if (presentState == READ)
		if(i2c_clock_cycles <= 15)
			sda_out_en = 'd1;
		else if(i2c_clock_cycles == 34 || i2c_clock_cycles == 35 || i2c_clock_cycles == 52 ||i2c_clock_cycles == 53)
			sda_out_en = 'd1;
		else
			sda_out_en = 'd0;
	else
		sda_out_en = 'd1;
end
	
// I2C_SDA: Assert/Deassert the I2C_SDA Signal at various State Machine States
always @ (*)
begin
    case(presentState)
        RESET:
            i2c_sda_state = 'd1;
        WAIT_RDWR:
            i2c_sda_state = i2c_sda_state;
				
					  // WRITE CONDITION					
        START_WR:
            i2c_sda_state = 'd0;
        START_WR_READY:
            i2c_sda_state = i2c_sda_state;
        START_WR_STABLE:
            i2c_sda_state = i2c_sda_state;
        WRITE: begin			
            case(i2c_clock_cycles)
                0: i2c_sda_state = write_command[7];			// First Send the Address (0x23)
                1: i2c_sda_state = write_command[7];
                2: i2c_sda_state = write_command[6];
                3: i2c_sda_state = write_command[6];
                4: i2c_sda_state = write_command[5];
                5: i2c_sda_state = write_command[5];
                6: i2c_sda_state = write_command[4];
                7: i2c_sda_state = write_command[4];
                8: i2c_sda_state = write_command[3];
                9: i2c_sda_state = write_command[3];
                10: i2c_sda_state = write_command[2];
                11: i2c_sda_state = write_command[2];
                12: i2c_sda_state = write_command[1];
                13: i2c_sda_state = write_command[1];
                14: i2c_sda_state = write_command[0];
                15: i2c_sda_state = write_command[0];
                16: begin end // do nothing 						// ACK bit - Do nothing
                17: begin end // do nothing 
					 18: i2c_sda_state = write_configuration[7]; // Then Send the Configuration Data (0x11)
                19: i2c_sda_state = write_configuration[7];
                20: i2c_sda_state = write_configuration[6];
                21: i2c_sda_state = write_configuration[6];
                22: i2c_sda_state = write_configuration[5];
                23: i2c_sda_state = write_configuration[5];
                24: i2c_sda_state = write_configuration[4];
                25: i2c_sda_state = write_configuration[4];
                26: i2c_sda_state = write_configuration[3];
                27: i2c_sda_state = write_configuration[3];
                28: i2c_sda_state = write_configuration[2];
                29: i2c_sda_state = write_configuration[2];
                30: i2c_sda_state = write_configuration[1];
                31: i2c_sda_state = write_configuration[1];
                32: i2c_sda_state = write_configuration[0];
                33: i2c_sda_state = write_configuration[0];
					 34: begin end // do nothing 						// ACK bit - Do nothing
                35: begin end // do nothing 
                default:
                    begin end // do nothing 
            endcase
        end
        STOP_WR:
                i2c_sda_state   	= 'd0;
        STOP_WR_READY: 
                i2c_sda_state 	= 'd0;
        STOP_WR_STABLE:
					 i2c_sda_state 	= 'd1;
				
					  // READ CONDITION
		  START_READ:
            i2c_sda_state = 'd0;
        START_READ_READY:
            i2c_sda_state = i2c_sda_state;
        START_READ_STABLE:
            i2c_sda_state = i2c_sda_state;
        READ: 
				begin
				    case(i2c_clock_cycles)
                0: i2c_sda_state = read_command[7];
                1: i2c_sda_state = read_command[7];
                2: i2c_sda_state = read_command[6];
                3: i2c_sda_state = read_command[6];
                4: i2c_sda_state = read_command[5];
                5: i2c_sda_state = read_command[5];
                6: i2c_sda_state = read_command[4];
                7: i2c_sda_state = read_command[4];
                8: i2c_sda_state = read_command[3];
                9: i2c_sda_state = read_command[3];
                10: i2c_sda_state = read_command[2];
                11: i2c_sda_state = read_command[2];
                12: i2c_sda_state = read_command[1];
                13: i2c_sda_state = read_command[1];
                14: i2c_sda_state = read_command[0];
                15: i2c_sda_state = read_command[0];
                16: begin end // do nothing 
                17: begin end // do nothing	
					 34: i2c_sda_state = 'd0;					// Master Acknowledges Byte 1
					 35: i2c_sda_state = 'd0;					// Master Acknowledges Byte 1
					 52: i2c_sda_state = 'd1;					// Master Acknowledges Byte 2 (END) by Sending NACK 
                53: i2c_sda_state = 'd1;					// Master Acknowledges Byte 2 (END) by Sending NACK
					default:
						begin end // do nothing 
					endcase
				end
        STOP_READ:
            i2c_sda_state   	= 'd0;
        STOP_READ_READY:
            i2c_sda_state   	= 'd0;
        STOP_READ_STABLE:
            i2c_sda_state   	= 'd1;
        default:
            i2c_sda_state 		= 'd1;
        endcase
end

// State Machine Output Logic (Sequential)
// I2C_SCLK: Generates the I2C_SCLK Signal for each State Machine State
always @ (posedge i2c_sclk_local_200khz)
begin
    case(presentState)
        RESET:
				i2c_sclk_local_output   <= 1'd1;
        WAIT_RDWR: 
            i2c_sclk_local_output   <= 1'd1; 
        START_WR:                                                                                                        
            i2c_sclk_local_output   <= 1'd1;
        START_WR_READY:                                                                                               
            i2c_sclk_local_output   <= 1'd0;
        START_WR_STABLE:                                             
            i2c_sclk_local_output   <= i2c_sclk_local_output;
        WRITE:
            begin
                i2c_clock_cycles        <= (i2c_clock_cycles + 'd1) % 36;
                i2c_sclk_local_output   <= ~i2c_sclk_local_output;
            end  
        STOP_WR: 
            i2c_sclk_local_output   <= 1'd1; 
        STOP_WR_READY: 
            i2c_sclk_local_output   <= 1'd1; 
        STOP_WR_STABLE: 
            i2c_sclk_local_output   <= i2c_sclk_local_output; 
				
		// READ CONDITION
		  START_READ:
            i2c_sclk_local_output   <= 1'd1;
        START_READ_READY:
            i2c_sclk_local_output   <= 1'd0;
        START_READ_STABLE:
            i2c_sclk_local_output   <= i2c_sclk_local_output;
        READ:                                                             // For TX: Send Address followed by writedata
            begin
                i2c_clock_cycles        <= (i2c_clock_cycles + 'd1) % 54;
                i2c_sclk_local_output   <= ~i2c_sclk_local_output;
            end  
        STOP_READ:
            i2c_sclk_local_output   <= 1'd1; 
        STOP_READ_READY:
            i2c_sclk_local_output   <= 1'd1; 
        STOP_READ_STABLE:
				begin 
					if(counter_last >= 180_00) begin counter_last <= 0; end
					else begin counter_last <= counter_last + 'd1; end
					i2c_sclk_local_output   <= i2c_sclk_local_output; 
				end
        default:
            begin 
                i2c_sclk_local_output   <= 1'd1; 
            end
    endcase
end

// State Machine Transition Logic (Combinational)
// Determines the condition to change to the nextState
always @ (*)
begin 
    case(presentState)
        RESET:
            nextState = WAIT_RDWR;
        WAIT_RDWR: 
            begin 
                nextState = START_WR;
            end
				
		  // WRITE CONDITION
        START_WR:
            nextState = START_WR_READY;
        START_WR_READY:
            nextState = START_WR_STABLE;
        START_WR_STABLE:
            nextState = WRITE;
        WRITE:                                                             // For TX: Send Address followed by writedata
            if(i2c_clock_cycles == 35)
                nextState = STOP_WR;
            else
                nextState = WRITE;
        STOP_WR:
            nextState = STOP_WR_READY;
        STOP_WR_READY:
            nextState = STOP_WR_STABLE;
        STOP_WR_STABLE:
            nextState = START_READ;
			
		  // READ CONDITION
		  START_READ:
            nextState = START_READ_READY;
        START_READ_READY:
            nextState = START_READ_STABLE;
        START_READ_STABLE:
            nextState = READ;
        READ:                                                             // For TX: Send Address followed by writedata
            if(i2c_clock_cycles == 53)
                nextState = STOP_READ;
            else
                nextState = READ;
        STOP_READ:
            nextState = STOP_READ_READY;
        STOP_READ_READY:
            nextState = STOP_READ_STABLE;
        STOP_READ_STABLE:
				if(counter_last == 180_00)			// WAIT FOR 18_000 (180ms) 
					nextState = START_READ; 		//WAIT_RDWR;
				else
					nextState = STOP_READ_STABLE; //WAIT_RDWR;
        default:
            nextState = RESET;
    endcase
end


// Core Signals 
assign I2C_SCLK     = i2c_sclk_local_output;
assign I2C_SDA      = sda_out_en ? i2c_sda_state : 1'bz;				// Assign SDA line with tri-state buffer logic
assign I2C_SCLK_Ref = i2c_sclk_local;
assign I2C_SCLK_Ref_200k = i2c_sclk_local_200khz;

// Debug by Dennis
assign presentState_output 		= presentState;
assign i2c_clock_cycles_output 	= i2c_clock_cycles;
assign i2c_bit_count_output 		= i2c_clock_cycles / 'd2;
assign sda_out_en_output			= sda_out_en;
assign counter_last_output = counter_last;

endmodule