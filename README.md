[![Open in Visual Studio Code](https://classroom.github.com/assets/open-in-vscode-2e0aaae1b6195c2367325f4f02e2d04e9abb55f0b24a779b69b11b9e10269abc.svg)](https://classroom.github.com/online_ide?assignment_repo_id=21729357&assignment_repo_type=AssignmentRepo)
# Proyecto final - Electrónica Digital 1 - 2025-II

# Integrantes


# Nombre del proyecto


# Documentación
## Descripción de la arquitectura


### Proceso

Se modeló y verificó el controlador maestro (master) para el sensor BH1750 tomando como referencia la hoja de datos y la implementación disponible en el repositorio [-FPGA-I2C-Driver-GY302-BH1750](https://github.com/dac70r/-FPGA-I2C-Driver-GY302-BH1750). El desarrollo siguió un flujo I2C estandarizado, comprobado mediante simulación y pruebas de laboratorio:

- Flujo I2C implementado:
	1. Generación de la condición de START y estabilización de las líneas SDA/SCL.
	2. Envío de la dirección del dispositivo (`0x23`) con el bit R/W en `0` (escritura) para configurar el modo de operación.
	3. El maestro libera la línea (estado Hi-Z); el esclavo responde con `ACK` (baja la línea) si acepta la dirección.
	4. Envío del comando de alta resolución. A continuación, se prepara la lectura enviando la dirección con R/W = `1` (lectura).
	5. El maestro libera la línea (Hi-Z); el esclavo responde con `ACK` y transmite 8 bits de datos.
	6. Repetición de la lectura para obtener MSB y LSB (dos bytes consecutivos).
	7. Generación de la condición de STOP y espera del tiempo de conversión (~180 ms) antes de leer de nuevo.
	8. Cálculo de la iluminancia: LUX = ((MSB << 8) | LSB) / 1.2 (concatenación de MSB y LSB seguida de la constante de calibración indicada en la datasheet).
	9. El proceso se repite periódicamente para mantener la medida actualizada.

- Verificación y simulación:
	- La FSM del controlador I2C fue validada mediante simulación en GTKWave, comprobando transiciones, ACK/NACK y tiempos de conversión.

- Integración con LCD:
	- Se adaptó la arquitectura para incorporar un decodificador BCD que transforma el valor de 16 bits del sensor en hasta 5 caracteres para mostrar el `lux_value` en la pantalla LCD.
	- Antes de conectar el sensor se realizaron pruebas con 8 interruptores y 8 pines de salida para verificar el controlador del LCD; durante estas pruebas se detectó y documentó un pin defectuoso en la FPGA.
	- Tras validar ambos módulos por separado (sensor y LCD), se integraron en el módulo `top`.

- Notas de implementación:
	- En el Pin Planner se especificó el uso de pines a `3.3 V` (LVCMOS) para permitir el comportamiento tri-state requerido por el bus I2C.![alt](images/LVCMOS_Pins.png)
	- Referencia de la implementación usada: `-FPGA-I2C-Driver-GY302-BH1750` (enlace arriba).
 
## Diagramas de la arquitectura


## Simulaciones


## Evidencias de implementación

