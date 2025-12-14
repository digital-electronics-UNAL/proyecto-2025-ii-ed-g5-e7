module top_multi_sensor_lcd_uart (
    input  wire        clk,         // Reloj de 50 MHz
    input  wire        reset,       // Reset activo en bajo (KEY0)
    input  wire        manual_btn,  // (NUEVO) Botón riego manual (KEY1)
    
    // I2C Pines Físicos
    output wire        I2C_SCLK,
    inout  wire        I2C_SDA,     
    
    // LCD Pines Físicos
    output wire        rs,
    output wire        rw,
    output wire        enable,
    output wire [7:0]  data,

    // UART Salida
    output wire        uart_tx_pin, // Conectar al RX del FT232RL

    // MOTOBOMBA (L298N)
    output wire        motor_in1,
    output wire        motor_in2,
    output wire        motor_pwm,    // Conectar a ENA
    
    // LEDs de Estado (Opcional pero recomendado)
    output wire [2:0]  leds         // [0]: Regando, [1]: Cooldown, [2]: Alerta Seco
);

// =============================================================================
// 1. CONFIGURACIÓN Y PARÁMETROS
// =============================================================================
parameter integer SYS_CLK_FREQ = 50_000_000;
parameter integer UART_CLKS_PER_BIT = 5208;  
parameter integer SWITCH_MS    = 2000;       
localparam integer SWITCH_CYCLES = (SYS_CLK_FREQ / 1000) * SWITCH_MS;

// Configuración de Riego
localparam [15:0] HUMIDITY_THRESH = 16'd30;  // Regar si humedad < 30%
localparam integer WATERING_TIME  = 5;       // Segundos regando
localparam integer COOLDOWN_TIME  = 15;      // Segundos esperando absorción

// =============================================================================
// 2. CONTROL DE TIEMPO Y SENSORES
// =============================================================================
reg [31:0] timer_cnt;
reg        active_sensor; 

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        timer_cnt     <= 0;
        active_sensor <= 0;
    end else begin
        if (timer_cnt < SWITCH_CYCLES) begin
            timer_cnt <= timer_cnt + 1;
        end else begin
            timer_cnt     <= 0;
            active_sensor <= ~active_sensor; 
        end
    end
end

wire reset_ads = reset & (active_sensor == 1'b0);
wire reset_bh  = reset & (active_sensor == 1'b1);

wire        sclk_ads, sclk_bh;
wire [15:0] ads_raw_value, lux_raw_value;
wire        ads_valid, lux_valid;
reg  [15:0] latched_humidity, latched_lux;

assign I2C_SCLK = (active_sensor == 1'b0) ? sclk_ads : sclk_bh;

// =============================================================================
// 3. MATEMÁTICAS (Humedad)
// =============================================================================
reg [15:0] humidity_pct;
reg [15:0] ads_unsigned;
localparam [15:0] VALOR_SECO   = 16'd17200; 
localparam [15:0] VALOR_HUMEDO = 16'd9000;  

always @(*) begin
    if (ads_raw_value[15] == 1'b1) ads_unsigned = 16'd0;
    else ads_unsigned = ads_raw_value;

    if (ads_unsigned >= VALOR_SECO)         humidity_pct = 16'd0;
    else if (ads_unsigned <= VALOR_HUMEDO) humidity_pct = 16'd100;
    else humidity_pct = ((VALOR_SECO - ads_unsigned) * 100) / (VALOR_SECO - VALOR_HUMEDO);
end

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        latched_humidity <= 0;
        latched_lux      <= 0;
    end else begin
        if (ads_valid) latched_humidity <= humidity_pct;
        if (lux_valid) latched_lux      <= lux_raw_value;
    end
end

// =============================================================================
// 4. LÓGICA DE TRANSMISIÓN UART 
// =============================================================================
reg [15:0] uart_tx_buffer;      
reg        uart_start_signal;   
reg [7:0]  uart_byte_to_send;   
wire       uart_busy;            
reg [7:0]  sensor_id; 
reg [15:0] gap_counter;
reg [3:0]  tx_state;
reg [3:0]  return_state;

localparam S_IDLE       = 4'd0;
localparam S_LOAD_ID    = 4'd1;
localparam S_LOAD_HIGH  = 4'd2;
localparam S_LOAD_LOW   = 4'd3;
localparam S_LOAD_NL    = 4'd4;
localparam S_TRIGGER_TX = 4'd5;
localparam S_WAIT_BUSY  = 4'd6; 
localparam S_WAIT_DONE  = 4'd7; 
localparam S_GAP        = 4'd8; 

uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) uart_inst (
    .clk(clk), .rst_n(reset), .tx_start(uart_start_signal), .tx_data(uart_byte_to_send),
    .tx_serial(uart_tx_pin), .busy(uart_busy)
);

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        tx_state          <= S_IDLE;
        uart_start_signal <= 0;
        uart_byte_to_send <= 0;
        uart_tx_buffer    <= 0;
        sensor_id         <= 0;
        gap_counter       <= 0;
        return_state      <= S_IDLE;
    end else begin
        case (tx_state)
            S_IDLE: begin
                uart_start_signal <= 0;
                if (lux_valid) begin
                    uart_tx_buffer <= lux_raw_value;
                    sensor_id      <= 8'hAA; 
                    tx_state       <= S_LOAD_ID;
                end
                else if (ads_valid) begin
                    uart_tx_buffer <= humidity_pct;
                    sensor_id      <= 8'hBB; 
                    tx_state       <= S_LOAD_ID;
                end
            end
            S_LOAD_ID: begin
                uart_byte_to_send <= sensor_id;
                return_state      <= S_LOAD_HIGH;
                tx_state          <= S_TRIGGER_TX;
            end
            S_LOAD_HIGH: begin
                uart_byte_to_send <= uart_tx_buffer[15:8];
                return_state      <= S_LOAD_LOW;
                tx_state          <= S_TRIGGER_TX;
            end
            S_LOAD_LOW: begin
                uart_byte_to_send <= uart_tx_buffer[7:0];
                return_state      <= S_LOAD_NL;
                tx_state          <= S_TRIGGER_TX;
            end
            S_LOAD_NL: begin
                uart_byte_to_send <= 8'h0A; 
                return_state      <= S_IDLE;
                tx_state          <= S_TRIGGER_TX;
            end
            S_TRIGGER_TX: begin
                uart_start_signal <= 1;
                if (uart_busy == 1) tx_state <= S_WAIT_DONE;
            end
            S_WAIT_DONE: begin
                uart_start_signal <= 0;
                if (uart_busy == 0) tx_state <= S_GAP;
            end
            S_GAP: begin
                if (gap_counter < 2000) gap_counter <= gap_counter + 1;
                else begin
                    gap_counter <= 0;
                    tx_state    <= return_state;
                end
            end
            default: tx_state <= S_IDLE;
        endcase
    end
end

// =============================================================================
// 5. INSTANCIAS I2C y LCD
// =============================================================================
I2C_ADS1115 i2c_ads (
    .system_clock(clk), .reset_n(reset_ads), .I2C_SCLK(sclk_ads), .I2C_SDA(I2C_SDA),    
    .adc_value(ads_raw_value), .adc_valid(ads_valid),
    .I2C_SCLK_Ref(), .I2C_SCLK_Ref_200k(), .presentState_output(), .i2c_clock_cycles_output(), 
    .i2c_bit_count_output(), .sda_out_en_output(), .read_I2C_SDA(1'b0), .read_I2C_SCLK(1'b0), .counter_last_output()
);

I2C_BH1750 i2c_bh (
    .system_clock(clk), .reset_n(reset_bh), .I2C_SCLK(sclk_bh), .I2C_SDA(I2C_SDA),    
    .lux_value(lux_raw_value), .lux_valid(lux_valid),
    .I2C_SCLK_Ref(), .I2C_SCLK_Ref_200k(), .presentState_output(), .i2c_clock_cycles_output(), 
    .i2c_bit_count_output(), .sda_out_en_output(), .read_I2C_SDA(1'b0), .read_I2C_SCLK(1'b0), .counter_last_output()
);

reg [31:0] lcd_startup_cnt;
reg        lcd_reset_n;
always @(posedge clk or negedge reset) begin
    if (!reset) begin
        lcd_startup_cnt <= 0;
        lcd_reset_n     <= 0;
    end else if (lcd_startup_cnt < (SYS_CLK_FREQ/10)) begin 
        lcd_startup_cnt <= lcd_startup_cnt + 1;
        lcd_reset_n     <= 0;
    end else begin
        lcd_reset_n     <= 1;
    end
end

LCD1602_controller #(
    .NUM_COMMANDS(4), .NUM_DATA_ALL(32), .NUM_DATA_PERLINE(16), .DATA_BITS(8), .COUNT_MAX(800_000)
) lcd_inst (
    .clk(clk), .reset(lcd_reset_n), .ready_i(1'b1), 
    .number1(latched_humidity), .number2(latched_lux), 
    .rs(rs), .rw(rw), .enable(enable), .data(data)
);

// =============================================================================
// 6. CONTROL MOTOBOMBA INTELIGENTE (SMART WATERING)
// =============================================================================
localparam ST_IDLE     = 2'd0;
localparam ST_PUMPING  = 2'd1;
localparam ST_COOLDOWN = 2'd2;

reg [1:0]  water_state;
reg [31:0] pump_timer;
reg        pump_enable_req;
reg [7:0]  pump_speed_req;

// Botón Manual (asumiendo Pull-Up, se activa con 0)
wire manual_trigger = ~manual_btn; 

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        water_state     <= ST_IDLE;
        pump_timer      <= 0;
        pump_enable_req <= 0;
        pump_speed_req  <= 0;
    end else begin
        case (water_state)
            ST_IDLE: begin
                pump_enable_req <= 0;
                pump_speed_req  <= 0;
                pump_timer      <= 0;
                
                // CONDICIÓN DE DISPARO:
                // 1. Humedad baja (< 30%) Y sensor válido (>0)
                // 2. O Botón manual presionado
                if (manual_trigger || (latched_humidity < HUMIDITY_THRESH && latched_humidity > 0)) begin
                    water_state <= ST_PUMPING;
                end
            end

            ST_PUMPING: begin
                pump_enable_req <= 1;
                // Efecto rampa suave de encendido (opcional)
                if (pump_speed_req < 250) pump_speed_req <= pump_speed_req + 1;
                
                if (pump_timer < (SYS_CLK_FREQ * WATERING_TIME)) begin
                    pump_timer <= pump_timer + 1;
                end else begin
                    pump_timer  <= 0;
                    water_state <= ST_COOLDOWN;
                end
            end

            ST_COOLDOWN: begin
                pump_enable_req <= 0; // Apagar bomba
                pump_speed_req  <= 0;
                
                // Tiempo de espera para que la tierra absorba el agua
                // antes de volver a chequear el sensor
                if (pump_timer < (SYS_CLK_FREQ * COOLDOWN_TIME)) begin
                    pump_timer <= pump_timer + 1;
                end else begin
                    pump_timer  <= 0;
                    water_state <= ST_IDLE;
                end
            end
        endcase
    end
end

// Instancia del Driver
motor_driver motor_inst (
    .clk(clk),
    .reset_n(reset),
    .enable(pump_enable_req), 
    .speed(pump_speed_req),      // Velocidad controlada por la máquina de estados
    .in1(motor_in1),
    .in2(motor_in2),
    .pwm_out(motor_pwm)
);

// Asignación de LEDs para debug visual
assign leds[0] = pump_enable_req;            // LED encendido = Bomba prendida-Logica negada
assign leds[1] = (water_state == ST_COOLDOWN); // LED encendido = Esperando absorción - Logica negada
assign leds[2] = (latched_humidity < HUMIDITY_THRESH); // Alerta visual (Tierra seca) - Logica negada

endmodule