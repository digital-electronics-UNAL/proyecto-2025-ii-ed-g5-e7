// LCD1602_controller.v
module LCD1602_controller #(
    parameter NUM_COMMANDS = 4,
    parameter NUM_DATA_ALL = 32,
    parameter NUM_DATA_PERLINE = 16,
    parameter DATA_BITS = 8,
    parameter COUNT_MAX = 800000
)(
    input clk,
    input reset,
    input ready_i,
    input [15:0] number1,    // 4-bit binary input -> show as 3 ASCII digits
    input [15:0] number2,
    output reg rs,
    output reg rw,
    output enable,
    output reg [DATA_BITS-1:0] data
);

    // ---------- state defs ----------
    localparam IDLE                = 3'b000;
    localparam CONFIG_CMD1         = 3'b001;
    localparam WR_STATIC_TEXT_1L   = 3'b010;
    localparam CONFIG_CMD2         = 3'b011;
    localparam WR_STATIC_TEXT_2L   = 3'b100;
    localparam WR_DYN_MAIN         = 3'b101;

    localparam DYN_CURSOR_1 = 2'b00;
    localparam DYN_WR_1     = 2'b01;
    localparam DYN_CURSOR_2 = 2'b10;
    localparam DYN_WR_2     = 2'b11;

    // ---------- LCD constants ----------
    localparam CLEAR_DISPLAY = 8'h01;
    localparam SHIFT_CURSOR_RIGHT = 8'h06;
    localparam DISPON_CURSOROFF = 8'h0C;
    localparam LINES2_MATRIX5x8_MODE8bit = 8'h38;
    localparam START_2LINE = 8'hC0;

    localparam START_AFTER_STATIC_1 = 8'h8B;
    localparam START_AFTER_STATIC_2 = 8'hCB;

    localparam NUM_DATA_DYN_1 = 5; // three chars per dynamic field
    localparam NUM_DATA_DYN_2 = 5; // three chars per dynamic field

    // ---------- regs ----------
    reg [2:0] fsm_state, next_state;
    reg [1:0] dyn_state, next_dyn_state;
    reg clk_16ms;

    // counters widths fixed
    reg [$clog2(COUNT_MAX)-1:0] clk_counter;
    reg [$clog2(NUM_COMMANDS)-1:0] command_counter;
    reg [$clog2(NUM_DATA_PERLINE)-1:0] data_counter;

    // memories
    reg [DATA_BITS-1:0] static_data_mem [0: NUM_DATA_ALL-1];
    reg [DATA_BITS-1:0] dynamic_data_mem1 [0: NUM_DATA_DYN_1-1];
    reg [DATA_BITS-1:0] dynamic_data_mem2 [0: NUM_DATA_DYN_2-1];
    reg [DATA_BITS-1:0] config_mem [0:NUM_COMMANDS-1];

    integer i;
    integer tmp;

    // ---------------- initial ----------------
    initial begin
        fsm_state = IDLE;
        command_counter = 0;
        data_counter = 0;
        rs = 1'b0;
        rw = 1'b0;
        data = 8'b0;
        clk_16ms = 1'b0;
        clk_counter = 0;

        // example static text - you may keep your $readmemh if you prefer
        for (i = 0; i < NUM_DATA_PERLINE; i = i + 1) begin
            static_data_mem[i] = 8'h20;
            static_data_mem[NUM_DATA_PERLINE + i] = 8'h20;
        end
        static_data_mem[0]  = "H";
        static_data_mem[1]  = "u";
        static_data_mem[2]  = "m";
        static_data_mem[3]  = "e";
        static_data_mem[4]  = "d";
        static_data_mem[5]  = "a";
        static_data_mem[6]  = "d";
        static_data_mem[7]  = "(";
        static_data_mem[8]  = "%";
        static_data_mem[9]  = ")";
        static_data_mem[10] = ":";
        static_data_mem[NUM_DATA_PERLINE + 0]  = "B";
        static_data_mem[NUM_DATA_PERLINE + 1]  = "a";
        static_data_mem[NUM_DATA_PERLINE + 2]  = "t";
        static_data_mem[NUM_DATA_PERLINE + 3]  = "e";
        static_data_mem[NUM_DATA_PERLINE + 4]  = "r";
        static_data_mem[NUM_DATA_PERLINE + 5]  = "i";
        static_data_mem[NUM_DATA_PERLINE + 6]  = "a";
        static_data_mem[NUM_DATA_PERLINE + 7]  = " ";
        static_data_mem[NUM_DATA_PERLINE + 8]  = "2";
        static_data_mem[NUM_DATA_PERLINE + 9]  = ":";
        static_data_mem[NUM_DATA_PERLINE + 10] = " ";

        // initial placeholders for dynamics
        dynamic_data_mem1[0] = " ";
        dynamic_data_mem1[1] = " ";
        dynamic_data_mem1[2] = " ";
        dynamic_data_mem1[3] = " ";
        dynamic_data_mem1[4] = " ";

        dynamic_data_mem2[0] = " ";
        dynamic_data_mem2[1] = " ";
        dynamic_data_mem2[2] = " ";
        dynamic_data_mem2[3] = " ";
        dynamic_data_mem2[4] = " ";
        // config mem - use blocking assignment in initial
        config_mem[0] = LINES2_MATRIX5x8_MODE8bit;
        config_mem[1] = SHIFT_CURSOR_RIGHT;
        config_mem[2] = DISPON_CURSOROFF;
        config_mem[3] = CLEAR_DISPLAY;
    end

    // ---------- clk divider ----------
    always @(posedge clk) begin
        if (clk_counter == COUNT_MAX-1) begin
            clk_16ms <= ~clk_16ms;
            clk_counter <= 'b0;
        end else begin
            clk_counter <= clk_counter + 1;
        end
    end

    // ---------- state register ----------
    always @(posedge clk_16ms or negedge reset) begin
        if (reset == 1'b0) begin
            fsm_state <= IDLE;
            dyn_state <= DYN_CURSOR_1;
        end else begin
            fsm_state <= next_state;
            dyn_state <= next_dyn_state;
        end
    end

    // ---------- next-state logic (as you had) ----------
    always @(*) begin
        next_state = fsm_state;
        next_dyn_state = dyn_state;

        case (fsm_state)
            IDLE: next_state = (ready_i) ? CONFIG_CMD1 : IDLE;
            CONFIG_CMD1: next_state = (command_counter == (NUM_COMMANDS-1)) ? WR_STATIC_TEXT_1L : CONFIG_CMD1;
            WR_STATIC_TEXT_1L: next_state = (data_counter == (NUM_DATA_PERLINE-1)) ? CONFIG_CMD2 : WR_STATIC_TEXT_1L;
            CONFIG_CMD2: next_state = WR_STATIC_TEXT_2L;
            WR_STATIC_TEXT_2L: next_state = (data_counter == (NUM_DATA_PERLINE-1)) ? WR_DYN_MAIN : WR_STATIC_TEXT_2L;
            WR_DYN_MAIN: begin
                next_state = WR_DYN_MAIN;
                case (dyn_state)
                    DYN_CURSOR_1: next_dyn_state = DYN_WR_1;
                    DYN_WR_1: next_dyn_state = (data_counter == (NUM_DATA_DYN_1-1)) ? DYN_CURSOR_2 : DYN_WR_1;
                    DYN_CURSOR_2: next_dyn_state = DYN_WR_2;
                    DYN_WR_2: next_dyn_state = (data_counter == (NUM_DATA_DYN_2-1)) ? DYN_CURSOR_1 : DYN_WR_2;
                    default: next_dyn_state = DYN_CURSOR_1;
                endcase
            end
            default: next_state = IDLE;
        endcase
    end

    // ================================================================
    // NEW: BCD/ASCII conversion using Sequential Double Dabble
    // ================================================================

    // Registers for BCD conversion
    reg [2:0] bcd_state;
    reg [4:0] bcd_counter;
    reg [35:0] shift_reg; // 20-bit BCD (5 digits) + 16-bit binary
    reg [15:0] bin_in;
    reg [19:0] bcd_out_1;
    reg [19:0] bcd_out_2;
    reg current_input_sel; // 0 for number1, 1 for number2

    localparam BCD_IDLE  = 3'd0;
    localparam BCD_LOAD  = 3'd1;
    localparam BCD_CHECK = 3'd2;
    localparam BCD_SHIFT = 3'd3;
    localparam BCD_DONE  = 3'd4;

    // Helper functions for BCD digit correction (Add 3 if >= 5)
    function [3:0] corr;
        input [3:0] val;
        begin
            corr = (val >= 4'd5) ? (val + 4'd3) : val;
        end
    endfunction

    // BCD FSM running on fast system clock `clk`
    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            bcd_state <= BCD_IDLE;
            bcd_counter <= 0;
            shift_reg <= 0;
            bin_in <= 0;
            bcd_out_1 <= 0;
            bcd_out_2 <= 0;
            current_input_sel <= 0;
        end else begin
            case (bcd_state)
                BCD_IDLE: begin
                    // Alternate between converting number1 and number2
                    if (current_input_sel == 0) begin
                        bin_in <= number1;
                        if (bin_in > 16'd99999) bin_in <= 16'd99999; // Clamp (optional)
                    end else begin
                        bin_in <= number2;
                        if (bin_in > 16'd99999) bin_in <= 16'd99999; // Clamp
                    end
                    bcd_state <= BCD_LOAD;
                end

                BCD_LOAD: begin
                    shift_reg <= {20'd0, bin_in};
                    bcd_counter <= 0;
                    bcd_state <= BCD_CHECK;
                end

                BCD_CHECK: begin
                    if (bcd_counter == 16) begin
                        bcd_state <= BCD_DONE;
                    end else begin
                        // Apply Add-3 rule to each BCD nibble
                        shift_reg[35:32] <= corr(shift_reg[35:32]); // Ten-Thousands
                        shift_reg[31:28] <= corr(shift_reg[31:28]); // Thousands
                        shift_reg[27:24] <= corr(shift_reg[27:24]); // Hundreds
                        shift_reg[23:20] <= corr(shift_reg[23:20]); // Tens
                        shift_reg[19:16] <= corr(shift_reg[19:16]); // Units
                        bcd_state <= BCD_SHIFT;
                    end
                end

                BCD_SHIFT: begin
                    shift_reg <= shift_reg << 1;
                    bcd_counter <= bcd_counter + 1;
                    bcd_state <= BCD_CHECK;
                end

                BCD_DONE: begin
                    // Store result
                    if (current_input_sel == 0) 
                        bcd_out_1 <= shift_reg[35:16];
                    else 
                        bcd_out_2 <= shift_reg[35:16];
                    
                    // Switch to next input
                    current_input_sel <= ~current_input_sel;
                    bcd_state <= BCD_IDLE;
                end
            endcase
        end
    end

    // ASCII formatting logic (Combinational, but simple lookups now)
    reg [7:0] num1_t5, num1_t4, num1_t3, num1_t2, num1_t1;
    reg [7:0] num2_t5, num2_t4, num2_t3, num2_t2, num2_t1;
    reg [3:0] d4_1, d3_1, d2_1, d1_1, d0_1;
    reg [3:0] d4_2, d3_2, d2_2, d1_2, d0_2;

    always @(*) begin
        // Unpack BCD digits for Number 1
        d4_1 = bcd_out_1[19:16];
        d3_1 = bcd_out_1[15:12];
        d2_1 = bcd_out_1[11:8];
        d1_1 = bcd_out_1[7:4];
        d0_1 = bcd_out_1[3:0];

        // Convert to ASCII with leading zero suppression
        num1_t5 = (d4_1 == 0) ? 8'h20 : ("0" + d4_1);
        num1_t4 = ((d3_1 == 0) && (num1_t5 == 8'h20)) ? 8'h20 : ("0" + d3_1);
        num1_t3 = ((d2_1 == 0) && (num1_t5 == 8'h20) && (num1_t4 == 8'h20)) ? 8'h20 : ("0" + d2_1);
        num1_t2 = ((d1_1 == 0) && (num1_t5 == 8'h20) && (num1_t4 == 8'h20) && (num1_t3 == 8'h20)) ? 8'h20 : ("0" + d1_1);
        num1_t1 = "0" + d0_1;

        // Unpack BCD digits for Number 2
        d4_2 = bcd_out_2[19:16];
        d3_2 = bcd_out_2[15:12];
        d2_2 = bcd_out_2[11:8];
        d1_2 = bcd_out_2[7:4];
        d0_2 = bcd_out_2[3:0];

        // Convert to ASCII with leading zero suppression
        num2_t5 = (d4_2 == 0) ? 8'h20 : ("0" + d4_2);
        num2_t4 = ((d3_2 == 0) && (num2_t5 == 8'h20)) ? 8'h20 : ("0" + d3_2);
        num2_t3 = ((d2_2 == 0) && (num2_t5 == 8'h20) && (num2_t4 == 8'h20)) ? 8'h20 : ("0" + d2_2);
        num2_t2 = ((d1_2 == 0) && (num2_t5 == 8'h20) && (num2_t4 == 8'h20) && (num2_t3 == 8'h20)) ? 8'h20 : ("0" + d1_2);
        num2_t1 = "0" + d0_2;

        // Write to Display Memory
        dynamic_data_mem1[0] = num1_t5;
        dynamic_data_mem1[1] = num1_t4;
        dynamic_data_mem1[2] = num1_t3;
        dynamic_data_mem1[3] = num1_t2;
        dynamic_data_mem1[4] = num1_t1;

        dynamic_data_mem2[0] = num2_t5;
        dynamic_data_mem2[1] = num2_t4;
        dynamic_data_mem2[2] = num2_t3;
        dynamic_data_mem2[3] = num2_t2;
        dynamic_data_mem2[4] = num2_t1;
    end

    // ================================================================

    // ---------- main outputs (you kept original timing) ----------
    always @(posedge clk_16ms) begin
        if (reset == 1'b0) begin
            command_counter <= 0;
            data_counter <= 0;
            data <= 8'b0;
            $readmemh("data.txt", static_data_mem);
        end else begin
            case (fsm_state)
                IDLE: begin
                    command_counter <= 0;
                    data_counter <= 0;
                    rs <= 1'b0;
                    data <= 8'b0;
                end

                CONFIG_CMD1: begin
                    rs <= 1'b0;
                    data <= config_mem[command_counter];
                    command_counter <= command_counter + 1;
                end

                WR_STATIC_TEXT_1L: begin
                    rs <= 1'b1;
                    data <= static_data_mem[data_counter];
                    data_counter <= data_counter + 1;
                end

                CONFIG_CMD2: begin
                    rs <= 1'b0;
                    data <= START_2LINE;
                    data_counter <= 0;
                end

                WR_STATIC_TEXT_2L: begin
                    rs <= 1'b1;
                    data <= static_data_mem[NUM_DATA_PERLINE + data_counter];
                    data_counter <= data_counter + 1;
                end

                WR_DYN_MAIN: begin
                    case (dyn_state)
                        DYN_CURSOR_1: begin
                            rs <= 1'b0;
                            data <= START_AFTER_STATIC_1;
                            data_counter <= 0;
                        end

                        DYN_WR_1: begin
                            rs <= 1'b1;
                            data <= dynamic_data_mem1[data_counter];
                            data_counter <= data_counter + 1;
                        end

                        DYN_CURSOR_2: begin
                            rs <= 1'b0;
                            data <= START_AFTER_STATIC_2;
                            data_counter <= 0;
                        end

                        DYN_WR_2: begin
                            rs <= 1'b1;
                            data <= dynamic_data_mem2[data_counter];
                            data_counter <= data_counter + 1;
                        end

                        default: begin
                            rs <= 1'b0;
                            data <= 8'b0;
                        end
                    endcase
                end

                default: begin
                    rs <= 1'b0;
                    data <= 8'b0;
                end
            endcase
        end
    end

    assign enable = clk_16ms;

endmodule