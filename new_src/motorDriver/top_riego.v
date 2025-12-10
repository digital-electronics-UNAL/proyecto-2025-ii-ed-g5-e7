module top_riego_plantas (
    input  wire       clk,        // Reloj 50MHz
    input  wire       rst_n,      // Reset (Botón KEY0)
    input  wire       start_btn,  // Botón de inicio (KEY1)
    
    // Salidas al L298N
    output wire       motor_in1,
    output wire       motor_in2,
    output wire       motor_ena,
    
    // LEDs visuales
    output wire [3:0] leds        // LED0=PWM, LED1=En Ciclo, LED2=Fin
);

    // --- 1. Detección del Botón (Debounce simple / Detector de Flanco) ---
    // Detectamos cuando el botón BAJA (se presiona) para activar solo una vez
    reg btn_prev;
    wire btn_pressed_pulse;
    
    always @(posedge clk) begin
        btn_prev <= start_btn;
    end
    
    // El pulso es verdadero si antes estaba en 1 (no pulsado) y ahora en 0 (pulsado)
    // Asumiendo botones con resistencia pull-up (común en FPGAs Altera)
    assign btn_pressed_pulse = (btn_prev == 1'b1 && start_btn == 1'b0);

    // --- 2. Máquina de Estados del Riego ---
    // Estados
    localparam S_IDLE = 1'b0;
    localparam S_RUN  = 1'b1;
    
    reg state;
    reg [7:0] current_speed;
    
    // Timer para controlar la velocidad de la rampa (qué tan rápido sube)
    // 50MHz reloj. Si queremos ir de 0 a 255 en ~5 segundos:
    // 5 seg / 255 pasos = ~0.02s por paso (20ms)
    // 20ms * 50MHz = 1,000,000 ciclos
    localparam RAMP_DELAY = 1000000; 
    
    reg [31:0] timer_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            current_speed <= 0;
            timer_cnt <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    current_speed <= 0;
                    timer_cnt <= 0;
                    
                    // Si detectamos el pulsado, iniciamos el ciclo
                    if (btn_pressed_pulse) begin
                        state <= S_RUN;
                    end
                end
                
                S_RUN: begin
                    // Gestión del tiempo
                    if (timer_cnt < RAMP_DELAY) begin
                        timer_cnt <= timer_cnt + 1;
                    end else begin
                        // Pasó el tiempo, incrementamos velocidad
                        timer_cnt <= 0;
                        
                        if (current_speed < 255) begin
                            current_speed <= current_speed + 1;
                        end else begin
                            // Llegamos al 100% (255), fin del ciclo
                            state <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end

    // --- 3. Instancia del Driver (Tu módulo corregido) ---
    motor_driver u_pump (
        .clk       (clk),
        .reset_n   (rst_n),
        .enable    (state == S_RUN), // Solo habilitado durante el ciclo
        .speed     (current_speed),
        .in1       (motor_in1),
        .in2       (motor_in2),
        .pwm_out   (motor_ena)
    );

    // --- 4. Visualización ---
    assign leds[0] = motor_ena;       // Brillo sube con la velocidad
    assign leds[1] = (state == S_RUN);// Encendido mientras riega
    assign leds[2] = !rst_n;          // Luz de reset
    assign leds[3] = ~start_btn;      // Luz cuando tocas el botón

endmodule