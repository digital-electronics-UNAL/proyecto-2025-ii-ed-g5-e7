module motor_driver (
    input  wire       clk,        // Reloj de 50 MHz
    input  wire       reset_n,    // Reset activo bajo
    input  wire       enable,     // 1 = Encender bomba, 0 = Apagar
    input  wire [7:0] speed,      // Velocidad (0 a 255)
    
    // Pines hacia L298N
    output reg        in1,        // Dirección 1
    output reg        in2,        // Dirección 2
    output reg        pwm_out     // Señal PWM (ENA)
);

    // Configuración de PWM
    // Frecuencia deseada: ~2 kHz
    // 50,000,000 / 25,000 = 2 kHz
    localparam integer PWM_PERIOD = 25000; 
    
    reg [15:0] pwm_counter;
    reg [15:0] duty_threshold;

    // Cálculo del ciclo de trabajo (Duty Cycle)
    always @(*) begin
        duty_threshold = (speed * 100); 
    end

    // Generador de PWM
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pwm_counter <= 0;
            pwm_out     <= 0;
        end else begin
            if (pwm_counter < PWM_PERIOD) begin
                pwm_counter <= pwm_counter + 1;
            end else begin
                pwm_counter <= 0;
            end

            // Comparador PWM
            if (pwm_counter < duty_threshold) 
                pwm_out <= 1'b1;
            else 
                pwm_out <= 1'b0;
        end
    end

    // Control de Dirección (Lógica L298N)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            in1 <= 0;
            in2 <= 0;
        end else begin
            if (enable) begin
                in1 <= 1'b1; // Girar en un sentido
                in2 <= 1'b0;
            end else begin
                in1 <= 1'b0; // Parada
                in2 <= 1'b0;
            end
        end
    end

endmodule