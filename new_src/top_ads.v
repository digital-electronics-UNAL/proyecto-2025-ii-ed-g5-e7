// top_i2c_bh1750_lcd.v
module top_i2c_bh1750_lcd (
    input  wire        clk,   // e.g. 50 MHz
    input  wire        reset, // active-low reset (keep using active-low as in your cores)
    // I2C physical pins
    output wire        I2C_SCLK,
    inout  wire        I2C_SDA,
    // LCD pins (connect to your LCD module pins)
    output wire        rs,
    output wire        rw,
    output wire        enable,
    output wire [7:0]  data
);

// -----------------------------------------------------------------------------
// Parameters: change as needed
// -----------------------------------------------------------------------------
parameter integer SYS_CLK_FREQ = 50_000_000; // system clock frequency in Hz
parameter integer STARTUP_MS  = 100;         // internal startup hold in ms

localparam integer STARTUP_CYCLES = (SYS_CLK_FREQ / 1000) * STARTUP_MS;

// -----------------------------------------------------------------------------
// Internal interconnect wires
// -----------------------------------------------------------------------------
wire [15:0] ads_value;
wire        ads_valid;

// minimal internal debug wires for I2C core (kept internal so you don't reassign)
wire        I2C_SCLK_Ref;
wire        I2C_SCLK_Ref_200k;
wire [5:0]  presentState_output;
wire [7:0]  i2c_bit_count_output;
wire        sda_out_en_output;
wire [31:0] counter_last_output;

// -----------------------------------------------------------------------------
// Startup/reset logic for LCD (internal active-low reset)
// -----------------------------------------------------------------------------
reg  [31:0] startup_cnt;
reg         lcd_reset_n;   // active-low reset used by LCD controller
reg         startup_done;

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        startup_cnt  <= 32'd0;
        lcd_reset_n  <= 1'b0; // hold LCD in reset while external reset is asserted
        startup_done <= 1'b0;
    end else begin
        if (!startup_done) begin
            if (startup_cnt < STARTUP_CYCLES) begin
                startup_cnt <= startup_cnt + 1;
                lcd_reset_n <= 1'b0; // keep internal reset asserted
            end else begin
                startup_done <= 1'b1;
                lcd_reset_n  <= 1'b1; // release internal reset
            end
        end
    end
end

// keep LCD refreshing continuously (even if lux_valid is low)
wire lcd_ready_always = 1'b1;

// -----------------------------------------------------------------------------
// Instantiate I2C_BH1750
// Note: connect debug wires internally so top-level port list stays clean
// read_I2C_SDA / read_I2C_SCLK tied to 0 (not used)
// -----------------------------------------------------------------------------
I2C_ADS1115 i2c_inst (
    .system_clock          (clk),
    .reset_n               (reset),

    .I2C_SCLK              (I2C_SCLK),
    .I2C_SDA               (I2C_SDA),

    .adc_value             (ads_value),
    .adc_valid             (ads_valid),

    .I2C_SCLK_Ref          (I2C_SCLK_Ref),
    .I2C_SCLK_Ref_200k     (I2C_SCLK_Ref_200k),
    .presentState_output   (presentState_output),
    .i2c_clock_cycles_output(i2c_clock_cycles_output),
    .i2c_bit_count_output  (i2c_bit_count_output),
    .sda_out_en_output     (sda_out_en_output),
    .read_I2C_SDA          (1'b0),
    .read_I2C_SCLK         (1'b0),
    .counter_last_output   (counter_last_output)
);

// -----------------------------------------------------------------------------
// Instantiate LCD controller
// - use lcd_reset_n (internal active-low reset) to ensure initial state
// - ready_i tied high so LCD continuously refreshes
// -----------------------------------------------------------------------------
LCD1602_controller #(
    .NUM_COMMANDS      (4),
    .NUM_DATA_ALL      (32),
    .NUM_DATA_PERLINE  (16),
    .DATA_BITS         (8),
    .COUNT_MAX         (800_000)   // tune for your clk frequency if necessary
) lcd_inst (
    .clk    (clk),
    .reset  (lcd_reset_n),       // active-low reset (internal startup)
    .ready_i(lcd_ready_always),  // keep refreshing even without lux_valid
    .number1(ads_value),         // 16-bit lux
    .number2(4'd0),              // unused
    .rs     (rs),
    .rw     (rw),
    .enable (enable),
    .data   (data)
);

// -----------------------------------------------------------------------------
// Notes:
// - I2C core uses the external reset so it can begin operation independently;
//   if you prefer both I2C and LCD to be released together, change
//   the i2c_inst .reset_n connection to lcd_reset_n.
// - STARTUP_MS defaults to 100 ms; adjust SYS_CLK_FREQ and STARTUP_MS to match
//   your system clock and desired boot hold time.
// -----------------------------------------------------------------------------

endmodule
