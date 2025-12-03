import serial
import time

# Configura tu puerto aquí (ej. 'COM3' en Windows, '/dev/ttyUSB0' en Linux)
PUERTO = 'COM8' 
BAUDIOS = 9600

try:
    ser = serial.Serial(PUERTO, BAUDIOS, timeout=1)
    print(f"Conectado a {PUERTO}. Presiona Ctrl+C para salir.")
    
    # Limpiar buffers por si hay basura vieja
    ser.reset_input_buffer()

    while True:
        # Tu FPGA envía: [High Byte] [Low Byte] [0x0A]
        # Leemos 3 bytes de golpe
        paquete = ser.read(3)

        if len(paquete) == 3:
            byte_alto = paquete[0]
            byte_bajo = paquete[1]
            byte_stop = paquete[2]

            # Verificamos que el tercer byte sea el salto de linea (0x0A = 10)
            # Esto nos ayuda a saber que estamos sincronizados
            if byte_stop == 0x0A:
                # Reconstruimos el valor de 16 bits
                # Desplazamos el alto 8 posiciones y sumamos el bajo
                valor_lux = (byte_alto << 8) | byte_bajo
                
                print(f"Lux Raw: {valor_lux}")
            else:
                print("Error de sincronización (byte de stop no encontrado)")
                ser.read(1) # Leemos un byte extra para intentar realinearnos
        
except serial.SerialException:
    print("Error: No se pudo abrir el puerto. ¿Está conectado el USB?")
except KeyboardInterrupt:
    print("\nSaliendo...")
    ser.close()