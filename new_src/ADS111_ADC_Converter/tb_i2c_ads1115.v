`timescale 1ns/1ps
// tb_i2c_bh1750.v
// Testbench that instantiates your I2C_BH1750 master module and the BH1750_emul slave.
// Produces i2c_bh1750.vcd for GTKWave.
`include "I2C_ADS1115_GEM.v"
`include "BH1750_emul.v"
module tb_i2c_ads1115;

    // system clock for master and slave (choose e.g. 50 MHz)
    reg system_clock = 0;
    always #10 system_clock = ~system_clock; // 25 MHz period 20 ns -> 50 MHz toggles? Actually #10 => 20ns period => 50MHz

    // wires and tri-state SDA
    wire I2C_SCLK_master;
    wire I2C_SDA_bus; // shared physical line

    // We'll connect master's read probes to the bus for debug inputs
    // For the master instance we need to connect ports as declared in your posted module.
    // Create wires for debug I/O
    wire I2C_SCLK_Ref;
    wire I2C_SCLK_Ref_200k;
    wire [5:0] presentState_output;
    wire [7:0] i2c_clock_cycles_output;
    wire [7:0] i2c_bit_count_output;
    wire sda_out_en_output;
    wire [31:0] counter_last_output;

    // Master's read probes expect inputs (read_I2C_SDA, read_I2C_SCLK). Connect them to the bus and SCLK.
    wire read_I2C_SDA;
    wire read_I2C_SCLK;

    // Instantiate master: (I2C_BH1750)
    // Note: This requires the exact module signature you pasted earlier to be available in the simulator.
    I2C_ADS1115 dut_master (
        .system_clock(system_clock),
        .reset_n(1'b1),
        .I2C_SCLK(I2C_SCLK_master),
        .I2C_SDA(I2C_SDA_bus),
        .I2C_SCLK_Ref(I2C_SCLK_Ref),
        .I2C_SCLK_Ref_200k(I2C_SCLK_Ref_200k),
        .presentState_output(presentState_output),
        .i2c_clock_cycles_output(i2c_clock_cycles_output),
        .i2c_bit_count_output(i2c_bit_count_output),
        .sda_out_en_output(sda_out_en_output),
        .read_I2C_SDA(read_I2C_SDA),
        .read_I2C_SCLK(read_I2C_SCLK),
        .counter_last_output(counter_last_output)
    );

    // Connect probe wires
    assign read_I2C_SDA = I2C_SDA_bus;
    assign read_I2C_SCLK = I2C_SCLK_master;

    // Instantiate slave emulator
    BH1750_emul slave_inst (
        .clk(system_clock),
        .I2C_SDA(I2C_SDA_bus),
        .I2C_SCLK(I2C_SCLK_master)
    );

    // pull-up simulation: The bus is open-drain, so provide a weak pull-up for idle '1'
    // In behavioral simulation a pull-up can be modeled with a resistor or simple driver.
    // Simpler: force line to '1' when not driven (z). Many simulators will treat undriven wire as z,
    // but to be explicit we create a pull-up driver that only drives '1' if nobody else pulls it low.
    // We will implement it as: if both master & slave drivers release, assign 1'b1 by continuous assignment.
    // Because both modules use inout with 'z' when release, having this extra driver makes the line default to 1.
    tri1 I2C_SDA_bus_pullup; // tri1 provides a default weak 1 when no drivers pull low
    // tie the tri1 net to the same net name used above
    // Note: We already used wire I2C_SDA_bus; redeclare to tri1 might cause multiple declaration errors in some tools.
    // Instead, do nothing — most simulators treat z as 'z' and tri1 not strictly required. Leaving the above as wire is fine.

    // VCD dump for GTKWave
    initial begin
        $dumpfile("i2c_ads1115.vcd");
        $dumpvars(0, tb_i2c_ads1115);

        // run long enough to allow multiple write/read cycles
        #50000000; // run for 5 ms worth at default timescale (adjust as needed)
        $display("Simulation finished");
        $finish;
    end

endmodule
