module top_multi_sensor_lcd_uart (
    input  wire        clk,        // Reloj de 50 MHz
    input  wire        reset,      // Reset activo en bajo (Botón)
    
    // I2C Pines Físicos
    output wire        I2C_SCLK,
    inout  wire        I2C_SDA,    
    
    // LCD Pines Físicos
    output wire        rs,
    output wire        rw,
    output wire        enable,
    output wire [7:0]  data,

    // UART Salida
    output wire        uart_tx_pin // Conectar al RX del FT232RL
);

// =============================================================================
// 1. CONFIGURACIÓN Y PARÁMETROS
// =============================================================================
parameter integer SYS_CLK_FREQ = 50_000_000;

// Configuración UART: 9600 Baudios @ 50MHz
// Cálculo: 50,000,000 / 9600 = 5208
parameter integer UART_CLKS_PER_BIT = 5208;  

// Tiempo de conmutación de sensores (2 Segundos)
parameter integer SWITCH_MS    = 2000;       
localparam integer SWITCH_CYCLES = (SYS_CLK_FREQ / 1000) * SWITCH_MS;

// =============================================================================
// 2. CONTROL DE TIEMPO Y SENSORES
// =============================================================================
reg [31:0] timer_cnt;
reg        active_sensor; // 0 = Humedad (ADS1115), 1 = Luz (BH1750)

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

// Reset individual por sensor (se apagan cuando no están activos)
wire reset_ads = reset & (active_sensor == 1'b0);
wire reset_bh  = reset & (active_sensor == 1'b1);

// Wires internos
wire        sclk_ads, sclk_bh;
wire [15:0] ads_raw_value, lux_raw_value;
wire        ads_valid, lux_valid;
reg  [15:0] latched_humidity, latched_lux;

// Multiplexor de Reloj I2C
assign I2C_SCLK = (active_sensor == 1'b0) ? sclk_ads : sclk_bh;

// =============================================================================
// 3. MATEMÁTICAS (Humedad)
// =============================================================================
reg [15:0] humidity_pct;
reg [15:0] ads_unsigned;
localparam [15:0] VALOR_SECO   = 16'd24000; 
localparam [15:0] VALOR_HUMEDO = 16'd7500;  

always @(*) begin
    // Filtro básico y conversión a porcentaje
    if (ads_raw_value[15] == 1'b1) ads_unsigned = 16'd0;
    else ads_unsigned = ads_raw_value;

    if (ads_unsigned >= VALOR_SECO)        humidity_pct = 16'd0;
    else if (ads_unsigned <= VALOR_HUMEDO) humidity_pct = 16'd100;
    //else humidity_pct = ((VALOR_SECO - ads_unsigned) * 100) / (VALOR_SECO - VALOR_HUMEDO);
	 else humidity_pct = ((VALOR_SECO - ads_unsigned) * 32'd1589) >> 18; // approx (Diff * 100) / 16500
end

// Latch de datos para mostrarlos en LCD sin parpadeos
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
// 4. LÓGICA DE TRANSMISIÓN UART (HANDSHAKE FIXED)
// =============================================================================
reg [15:0] uart_tx_buffer;      
reg        uart_start_signal;   
reg [7:0]  uart_byte_to_send;   
wire       uart_busy;           
reg [7:0]  sensor_id; 

// Contadores y estados para la FSM robusta
reg [15:0] gap_counter;
reg [3:0]  tx_state;
reg [3:0]  return_state; // Memoria para saber a qué paso volver

// Definición de Estados
localparam S_IDLE       = 4'd0;
localparam S_LOAD_ID    = 4'd1;
localparam S_LOAD_HIGH  = 4'd2;
localparam S_LOAD_LOW   = 4'd3;
localparam S_LOAD_NL    = 4'd4;

// Estados de Transmisión (El motor)
localparam S_TRIGGER_TX = 4'd5; // Inicia envío
localparam S_WAIT_BUSY  = 4'd6; // Espera a que UART confirme recepción (Ack)
localparam S_WAIT_DONE  = 4'd7; // Espera a que termine de enviar
localparam S_GAP        = 4'd8; // Pausa de seguridad

// Instancia del módulo UART
uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) uart_inst (
    .clk       (clk),
    .rst_n     (reset),
    .tx_start  (uart_start_signal),
    .tx_data   (uart_byte_to_send),
    .tx_serial (uart_tx_pin),
    .busy      (uart_busy)
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
            // --- DETECCIÓN DE DATOS ---
            S_IDLE: begin
                uart_start_signal <= 0;
                
                // Prioridad 1: Sensor de Luz (ID: 0xAA)
                if (lux_valid) begin
                    uart_tx_buffer <= lux_raw_value;
                    sensor_id      <= 8'hAA; 
                    tx_state       <= S_LOAD_ID;
                end
                // Prioridad 2: Sensor de Humedad (ID: 0xBB)
                else if (ads_valid) begin
                    uart_tx_buffer <= humidity_pct;
                    sensor_id      <= 8'hBB; 
                    tx_state       <= S_LOAD_ID;
                end
            end

            // --- CARGA DE BYTES ---
            
            // 1. Cargar Header
            S_LOAD_ID: begin
                uart_byte_to_send <= sensor_id;
                return_state      <= S_LOAD_HIGH; // Próximo paso: High Byte
                tx_state          <= S_TRIGGER_TX;
            end

            // 2. Cargar Byte Alto
            S_LOAD_HIGH: begin
                uart_byte_to_send <= uart_tx_buffer[15:8];
                return_state      <= S_LOAD_LOW; // Próximo paso: Low Byte
                tx_state          <= S_TRIGGER_TX;
            end

            // 3. Cargar Byte Bajo
            S_LOAD_LOW: begin
                uart_byte_to_send <= uart_tx_buffer[7:0];
                return_state      <= S_LOAD_NL; // Próximo paso: New Line
                tx_state          <= S_TRIGGER_TX;
            end

            // 4. Cargar Salto de Línea (Footer)
            S_LOAD_NL: begin
                uart_byte_to_send <= 8'h0A; 
                return_state      <= S_IDLE; // Próximo paso: Volver a esperar
                tx_state          <= S_TRIGGER_TX;
            end

            // --- MOTOR DE TRANSMISIÓN SEGURO (HANDSHAKE) ---
            
            // Paso A: Iniciar transmisión y asegurar que el UART reaccione
            S_TRIGGER_TX: begin
                uart_start_signal <= 1;
                // Esperamos HASTA que busy suba a 1. 
                // Esto confirma que el UART capturó el dato.
                if (uart_busy == 1) begin
                    tx_state <= S_WAIT_DONE;
                end
            end

            // Paso B: Esperar a que termine la transmisión
            S_WAIT_DONE: begin
                uart_start_signal <= 0; // Bajamos start
                // Esperamos HASTA que busy baje a 0.
                if (uart_busy == 0) begin
                    tx_state <= S_GAP;
                end
            end

            // Paso C: Pausa de seguridad (GAP)
            S_GAP: begin
                // ~40us de pausa (2000 ciclos @ 50MHz)
                if (gap_counter < 2000) begin
                    gap_counter <= gap_counter + 1;
                end else begin
                    gap_counter <= 0;
                    tx_state    <= return_state; // Volvemos al flujo principal
                end
            end
            
            default: tx_state <= S_IDLE;
        endcase
    end
end

// =============================================================================
// 5. INSTANCIAS (Sensores y LCD)
// =============================================================================

I2C_ADS1115 i2c_ads (
    .system_clock(clk), .reset_n(reset_ads), .I2C_SCLK(sclk_ads), .I2C_SDA(I2C_SDA),   
    .adc_value(ads_raw_value), .adc_valid(ads_valid),
    // Puertos debug no conectados
    .I2C_SCLK_Ref(), .I2C_SCLK_Ref_200k(), .presentState_output(), .i2c_clock_cycles_output(), 
    .i2c_bit_count_output(), .sda_out_en_output(), .read_I2C_SDA(1'b0), .read_I2C_SCLK(1'b0), .counter_last_output()
);

I2C_BH1750 i2c_bh (
    .system_clock(clk), .reset_n(reset_bh), .I2C_SCLK(sclk_bh), .I2C_SDA(I2C_SDA),   
    .lux_value(lux_raw_value), .lux_valid(lux_valid),
    // Puertos debug no conectados
    .I2C_SCLK_Ref(), .I2C_SCLK_Ref_200k(), .presentState_output(), .i2c_clock_cycles_output(), 
    .i2c_bit_count_output(), .sda_out_en_output(), .read_I2C_SDA(1'b0), .read_I2C_SCLK(1'b0), .counter_last_output()
);

// Control LCD
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

endmodule