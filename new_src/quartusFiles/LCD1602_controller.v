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
    // NEW: BCD/ASCII conversion for number1 and number2 -> dynamic_data_memX
    // We convert the 4-bit binary number to 3 ASCII characters (hundreds/tens/units)
    // and format with leading spaces. Examples:
    //  0 -> "  0"
    //  5 -> "  5"
    // 12 -> " 12"
    // ================================================================

    // ---------- fixed BCD/ASCII conversion for number1 (5 digits) and number2 (3 digits) ----------
reg [7:0] num1_t5, num1_t4, num1_t3, num1_t2, num1_t1;
reg [7:0] num2_t5, num2_t4, num2_t3, num2_t2, num2_t1;
integer n;
integer d0, d1, d2, d3, d4; // digits d4..d0 -> ten-thousands .. units

always @(*) begin
    // --- load and clamp ---
    n = number1;                // 0..65535 for 16-bit input
    if (n > 99999) n = 99999;   // optional clamp to 5-digit max (remove if you want full 0..65535)

    // --- compute decimal digits (ten-thousands..units) ---
    d4 = n / 10000;             // ten-thousands (0..9)
    d3 = (n % 10000) / 1000;    // thousands
    d2 = (n % 1000)  / 100;     // hundreds
    d1 = (n % 100)   / 10;      // tens
    d0 = n % 10;                // units

    // --- convert to ASCII but keep as raw digits first ---
    num1_t5 = "0" + d4; // ten-thousands ASCII (may be blanked)
    num1_t4 = "0" + d3; // thousands
    num1_t3 = "0" + d2; // hundreds
    num1_t2 = "0" + d1; // tens
    num1_t1 = "0" + d0; // units (always shown)

    // --- apply leading-space suppression ---
    // If ten-thousands is zero, show space; otherwise show digit.
    if (d4 == 0) num1_t5 = 8'h20; 

    // If thousands is zero and ten-thousands is blank, show space.
    if ((d3 == 0) && (num1_t5 == 8'h20)) num1_t4 = 8'h20;

    // If hundreds is zero and higher two are blank, show space.
    if ((d2 == 0) && (num1_t5 == 8'h20) && (num1_t4 == 8'h20)) num1_t3 = 8'h20;

    // If tens is zero and higher three are blank, show space.
    if ((d1 == 0) && (num1_t5 == 8'h20) && (num1_t4 == 8'h20) && (num1_t3 == 8'h20)) num1_t2 = 8'h20;

    // units always shown (num1_t1 already ASCII)

	 // --- load and clamp ---
    n = number2;                // 0..65535 for 16-bit input
    if (n > 99999) n = 99999;   // optional clamp to 5-digit max (remove if you want full 0..65535)

    // --- compute decimal digits (ten-thousands..units) ---
    d4 = n / 10000;             // ten-thousands (0..9)
    d3 = (n % 10000) / 1000;    // thousands
    d2 = (n % 1000)  / 100;     // hundreds
    d1 = (n % 100)   / 10;      // tens
    d0 = n % 10;                // units

    // --- convert to ASCII but keep as raw digits first ---
    num2_t5 = "0" + d4; // ten-thousands ASCII (may be blanked)
    num2_t4 = "0" + d3; // thousands
    num2_t3 = "0" + d2; // hundreds
    num2_t2 = "0" + d1; // tens
    num2_t1 = "0" + d0; // units (always shown)

    // --- apply leading-space suppression ---
    // If ten-thousands is zero, show space; otherwise show digit.
    if (d4 == 0) num2_t5 = 8'h20; 

    // If thousands is zero and ten-thousands is blank, show space.
    if ((d3 == 0) && (num2_t5 == 8'h20)) num2_t4 = 8'h20;

    // If hundreds is zero and higher two are blank, show space.
    if ((d2 == 0) && (num2_t5 == 8'h20) && (num2_t4 == 8'h20)) num2_t3 = 8'h20;

    // If tens is zero and higher three are blank, show space.
    if ((d1 == 0) && (num2_t5 == 8'h20) && (num2_t4 == 8'h20) && (num2_t3 == 8'h20)) num2_t2 = 8'h20;

	 
	 
	 
	

    // --- write into dynamic memory (combinational update) ---
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