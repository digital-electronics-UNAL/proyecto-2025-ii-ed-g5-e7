[![Open in Visual Studio Code](https://classroom.github.com/assets/open-in-vscode-2e0aaae1b6195c2367325f4f02e2d04e9abb55f0b24a779b69b11b9e10269abc.svg)](https://classroom.github.com/online_ide?assignment_repo_id=21729357&assignment_repo_type=AssignmentRepo)
# Proyecto final - Electrónica Digital 1 - 2025-II

# Integrantes


# Nombre del proyecto


# Documentación
## Descripción de la arquitectura

### Proceso
Primero se modeló el controlador maestro (master) para el sensor BH1750 siguiendo la hoja de datos (datasheet). Se verificó que el intercambio I2C siguiera el siguiente flujo:

1. Se genera la condición de START y se espera a que la línea SDA/SCL se estabilice.
2. El maestro envía la dirección del dispositivo (0x23) junto con el bit R/W en modo escritura para configurar el modo de resolución.
3. El maestro libera la línea (estado Hi-Z) y el esclavo responde con ACK (baja la línea) para confirmar la recepción.
4. El maestro envía el comando de alta resolución; a continuación se envía la dirección con el bit R/W en modo lectura (R/W = 1) para solicitar datos.
5. El maestro vuelve a liberar la línea (Hi-Z). El esclavo emite ACK seguido de los 8 bits de datos.
6. Se repite la lectura para obtener primero el MSB y luego el LSB.
7. Se genera la condición de STOP y se espera el tiempo de conversión (≈180 ms).
8. Se calcula el valor de iluminancia (lux) concatenando MSB y LSB y aplicando la constante de calibración: LUX = ((MSB << 8) | LSB) / 1.2.
9. El proceso se repite periódicamente para actualizar la medida.

La simulación en GTKWave corroboró el correcto funcionamiento de la máquina de estados (FSM) del controlador I2C.

Para la pantalla LCD se adaptó la arquitectura anterior incorporando un decodificador BCD que transforma el valor de 16 bits del sensor en los caracteres necesarios (hasta 5 dígitos) para mostrar el `lux_value`.

Antes de conectar el sensor, se verificó el controlador del LCD con pruebas manuales usando 8 interruptores y 8 pines de salida; durante estas pruebas se detectó y documentó un pin defectuoso en la FPGA.

Una vez validados por separado el módulo del sensor y el controlador del LCD, se integraron ambos en el módulo `top`.

Nota: en el Pin Planner se especificó el uso de pines a 3.3 V (LVCMOS) para permitir el comportamiento tri-state requerido por el bus I2C. ![alt text](images/LVCMOS_Pins.png)
 
## Diagramas de la arquitectura


## Simulaciones


## Evidencias de implementación

