`timescale 1ns/1ps
// BH1750_emul.v
// Simple I2C slave emulating BH1750 (address 0x23).
// - Supports write of command 0x11 (one-time high-res measurement)
// - After command, produces a 16-bit result which is returned on master read
// Notes: This is an educational/simulation model (not cycle-accurate silicon).
module BH1750_emul(
    input  wire clk,          // system clock for internal timing (from testbench)
    inout  wire I2C_SDA,      // shared I2C SDA (open-drain)
    input  wire I2C_SCLK      // I2C SCL line (from master)
);

    // 7-bit address for BH1750 (0x23)
    localparam SLAVE_ADDR = 7'b0100011; // 0x23

    // Internal registers
    reg sda_out_en = 1'b0;   // drive SDA when 1 (active low drive)
    reg sda_drive   = 1'b1;  // value to drive on SDA when sda_out_en=1 (0 => pull low)
    wire sda_line;           // actual wire (for reading)
    assign sda_line = I2C_SDA; // read the shared line

    // tri-state driver on SDA: drive 0 when sda_out_en==1 and sda_drive==0; else release (z)
    // To model open-drain: only drive '0' or 'z'
    assign I2C_SDA = (sda_out_en && (sda_drive==1'b0)) ? 1'b0 : 1'bz;

    // Edge detection
    reg scl_d = 1'b1, sda_d = 1'b1;
    always @(posedge clk) begin
        scl_d <= I2C_SCLK;
        sda_d <= sda_line;
    end
    wire scl_rising  = (I2C_SCLK == 1'b1) && (scl_d == 1'b0);
    wire scl_falling = (I2C_SCLK == 1'b0) && (scl_d == 1'b1);
    wire sda_falling = (sda_line == 1'b0) && (sda_d == 1'b1);
    wire sda_rising  = (sda_line == 1'b1) && (sda_d == 1'b0);

    // Detect START and STOP
    reg start_detected = 1'b0;
    reg stop_detected  = 1'b0;
    always @(posedge clk) begin
        start_detected <= 1'b0;
        stop_detected  <= 1'b0;
        // START: SDA falls while SCL high
        if (sda_falling && I2C_SCLK) start_detected <= 1'b1;
        // STOP: SDA rises while SCL high
        if (sda_rising && I2C_SCLK)  stop_detected  <= 1'b1;
    end

    // I2C byte shift registers and state machine
    reg [7:0] shift_reg;
    reg [3:0] bit_count;
    reg [1:0] rw_flag; // 0 = write (master->slave), 1 = read (master reads)
    reg addressed = 1'b0;
    reg address_rw = 1'b0; // 0 write, 1 read
    reg in_transmit = 1'b0; // slave is currently driving data to master

    // Measurement buffer: 16-bit result to return on read
    reg [15:0] measurement = 16'h06A0; // default: arbitrary measurement (changeable)
    reg measurement_ready = 1'b1; // ready immediately in this emulation
    // You could set measurement_ready=0 after write 0x11 and then set later.

    // Received command register (last written command)
    reg [7:0] last_cmd;

    // Simple internal counter for simulating measurement delay after 0x11
    reg [31:0] meas_delay;
    localparam MEAS_DELAY_CYCLES = 1000; // arbitrary cycles of clk (tunable)

    // State machine: on START we begin receiving address
    reg receiving_addr;
    reg receiving_data;

    always @(posedge clk) begin
        // default: do not drive SDA (release)
        if (!in_transmit) begin
            sda_out_en <= 1'b0;
            sda_drive  <= 1'b1;
        end

        if (start_detected) begin
            // New transaction: prepare to receive address byte
            receiving_addr <= 1'b1;
            receiving_data <= 1'b0;
            addressed <= 1'b0;
            bit_count <= 4'd0;
            shift_reg <= 8'd0;
            in_transmit <= 1'b0;
        end

        // If we detect a stop, reset state machine
        if (stop_detected) begin
            receiving_addr <= 1'b0;
            receiving_data <= 1'b0;
            addressed <= 1'b0;
            in_transmit <= 1'b0;
            sda_out_en <= 1'b0;
            sda_drive  <= 1'b1;
        end

        // Sample SDA on SCL rising edges (I2C standard)
        if (scl_rising) begin
            // shift in bits while receiving
            if (receiving_addr || receiving_data) begin
                shift_reg <= {shift_reg[6:0], sda_line}; // MSB first when reading 8 bits
                bit_count <= bit_count + 1'b1;
            end
        end

        // On SCL falling we may prepare to drive ACK or prepare transmit bits
        if (scl_falling) begin
            // If we just finished receiving 8 bits (bit_count == 8), prepare ACK or take action
            if ((receiving_addr || receiving_data) && (bit_count == 4'd8)) begin
                // finished byte in shift_reg
                if (receiving_addr) begin
                    // address + R/W
                    // Master sends 8 bits: [7:1] slave address, [0] R/W
                    if (shift_reg[7:1] == SLAVE_ADDR) begin
                        addressed <= 1'b1;
                        address_rw <= shift_reg[0];
                        // drive ACK low during next ACK bit (SDA low)
                        sda_out_en <= 1'b1;
                        sda_drive  <= 1'b0; // pull low to ack
                        // after ack we will move into either receiving_data (for write)
                        // or prepare transmit (for read) AFTER the ACK bit completes
                    end else begin
                        // not addressed: do not ack; release SDA
                        addressed <= 1'b0;
                        sda_out_en <= 1'b0;
                    end
                    // clear counters for next byte
                    receiving_addr <= 1'b0;
                    receiving_data <= 1'b1; // next bytes are data if master is writing
                    bit_count <= 4'd0;
                end else if (receiving_data) begin
                    // We received a data byte from master (write)
                    // ACK the byte if we are addressed and write mode
                    if (addressed && (address_rw == 1'b0)) begin
                        sda_out_en <= 1'b1; sda_drive <= 1'b0; // ACK
                        last_cmd <= shift_reg;
                        // If the command is 0x11 (one-time high res), emulate measurement delay
                        if (shift_reg == 8'h11) begin
                            // reset measurement delay; in this simple model we make measurement_ready after some cycles
                            measurement_ready <= 1'b0;
                            meas_delay <= 0;
                        end
                    end else begin
                        sda_out_en <= 1'b0; // NACK / release
                    end
                    bit_count <= 4'd0;
                end
            end else begin
                // If we are in transmit mode (master reading), prepare next bit on SDA when SCL is low
                // Master samples SDA on rising edge; slave should change SDA while SCL low
                if (in_transmit && addressed && (address_rw == 1'b1)) begin
                    // determine which bit to output based on tx_byte and tx_bit_index
                    // tx_bit_idx counts down from 7..0
                end
            end
        end

        // Advance measurement delay (simulate conversion time)
        if (!measurement_ready) begin
            if (meas_delay >= MEAS_DELAY_CYCLES) begin
                measurement_ready <= 1'b1;
                // optionally change measurement value here (e.g., random or deterministic)
                // keep current measurement unless you change it
            end else begin
                meas_delay <= meas_delay + 1;
            end
        end
    end // always

    // TRANSMIT logic: implement a more explicit small FSM for read-phase transmission
    reg [1:0] state; // 0=IDLE/WAIT, 1=TX_BYTE0 (MSB), 2=TX_BYTE1 (LSB), 3=ACK_CHECK
    reg [7:0] tx_byte;
    reg [2:0] tx_bit_idx;

    // We'll sample START/STOP and SCL edges in separate small always block
    always @(posedge clk) begin
        // default release SDA unless we want to drive (ACK or data)
        if (state == 0) begin
            // not driving except for ACKs handled earlier
            // ensure release
            if (!((receiving_addr || receiving_data) && (bit_count == 0))) begin
                sda_out_en <= 1'b0;
                sda_drive <= 1'b1;
            end
        end
    end

    // Manage the transition into transmit state when master requests read
    // We detect the scenario: addressed == 1 and address_rw==1 and the ACK phase has passed
    // For simplicity we start transmit when we detect the ACK after the address byte (master will now clock data)
    // We'll use a small hand-off: after we acked address earlier (sda_out_en pulled low),
    // On next SCL falling we release the ACK and prepare first transmit byte.
    reg ack_pending_release;
    always @(posedge clk) begin
        if (scl_falling) begin
            // If we just ACKed the address (sda_out_en==1 && addressed && address_rw==1), prepare to transmit
            if (addressed && (address_rw==1'b1) && sda_out_en) begin
                // we had ACKed the address; now prepare transmit of MSB
                // Only start transmit if measurement is ready; if not ready we will return 0x00 0x00
                if (measurement_ready) tx_byte <= measurement[15:8];
                else tx_byte <= 8'h00;
                tx_bit_idx <= 3'd7;
                state <= 1; // TX_BYTE0
                in_transmit <= 1'b1;
                // release ACK soon (we were ACKing now)
                ack_pending_release <= 1'b1;
            end
            // If in transmit and we've finished a byte and master is ACKing, handle next steps
            if (state == 1 && in_transmit && (tx_bit_idx == 3'd7) && ack_pending_release) begin
                // We just released the ack and will drive MSB bits now (we set bits on SCL falling below)
                ack_pending_release <= 1'b0;
            end
        end
    end

    // Drive data bits on SDA while transmitting - change SDA while SCL is low (we use scl_falling event to set next bit)
    always @(posedge clk) begin
        if (scl_falling) begin
            if (state == 1) begin
                // drive the current bit of tx_byte
                sda_out_en <= 1'b1;
                sda_drive  <= (tx_byte[tx_bit_idx] == 1'b0) ? 1'b0 : 1'b1; // we can only drive low; to drive 1 we release (z)
                if (tx_byte[tx_bit_idx] == 1'b1) begin
                    // to put a logic 1 on the line we must release SDA (open-drain)
                    sda_out_en <= 1'b0;
                end
                // prepare for next bit on next falling edge
                if (tx_bit_idx == 0) begin
                    // byte finished; next rising edge master will sample and then will drive ACK bit
                    // Move to ACK handling state (master drives SDA)
                    state <= 3;
                    // release SDA so master can ack
                    sda_out_en <= 1'b0;
                end else begin
                    tx_bit_idx <= tx_bit_idx - 1;
                end
            end else if (state == 3) begin
                // We are waiting for ACK from master: master will drive SDA during ACK bit (on 9th SCL cycle)
                // On SCL rising we sampled ACK earlier in different block; handle transition after ACK observed.
                // We'll detect ACK by sampling SDA on SCL rising elsewhere.
            end else if (state == 0) begin
                // no-op
            end else if (state == 2) begin
                // second byte (LSB)
                sda_out_en <= 1'b1;
                sda_drive  <= (tx_byte[tx_bit_idx] == 1'b0) ? 1'b0 : 1'b1;
                if (tx_byte[tx_bit_idx] == 1'b1) sda_out_en <= 1'b0;
                if (tx_bit_idx == 0) begin
                    // finished second byte; next will be ACK/NACK from master (we expect NACK to end)
                    state <= 3;
                    sda_out_en <= 1'b0;
                end else begin
                    tx_bit_idx <= tx_bit_idx - 1;
                end
            end
        end

        // On SCL rising we sample master's ACK bits to move between bytes
        if (scl_rising) begin
            if (state == 3) begin
                // sample ACK (SDA pulled low by master means ACK)
                if (sda_line == 1'b0) begin
                    // master ACK'd; if we were in TX_BYTE0, move to TX_BYTE1
                    if (tx_byte == measurement[15:8]) begin
                        // move to LSB
                        tx_byte <= measurement[7:0];
                        tx_bit_idx <= 3'd7;
                        state <= 2; // TX_BYTE1
                        // master will continue clocking; on SCL falling we'll begin driving bits
                    end else begin
                        // we just finished second byte and master acked (rare) - continue (stay or finish)
                        // We'll simply go IDLE
                        state <= 0;
                        in_transmit <= 1'b0;
                    end
                end else begin
                    // master NACK'd: end of read (expected after last byte)
                    state <= 0;
                    in_transmit <= 1'b0;
                end
            end
        end
    end

    // initialize state
    initial begin
        sda_out_en = 1'b0;
        sda_drive  = 1'b1;
        receiving_addr = 1'b0;
        receiving_data = 1'b0;
        addressed = 1'b0;
        bit_count = 0;
        last_cmd = 8'h00;
        measurement = 16'h06A0;
        measurement_ready = 1'b1;
        state = 0;
        in_transmit = 1'b0;
    end

endmodule
