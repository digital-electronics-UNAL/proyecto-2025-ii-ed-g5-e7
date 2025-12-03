import serial
import time
import sys

# ==========================================
# CONFIGURACIÓN
# ==========================================
PUERTO  = 'COM8'   # Cambia esto por tu puerto (ej. /dev/ttyUSB0 en Linux)
BAUDIOS = 9600

# IDs definidos en la FPGA
ID_LUX     = 0xAA
ID_HUMEDAD = 0xBB
BYTE_STOP  = 0x0A

def iniciar_monitor():
    try:
        ser = serial.Serial(PUERTO, BAUDIOS, timeout=1)
        print(f"--- Conectado a {PUERTO} a {BAUDIOS} bps ---")
        print("Esperando datos de la FPGA...")
        print("Presiona Ctrl+C para salir.\n")
        
        # Limpiar buffer inicial
        ser.reset_input_buffer()

        while True:
            # 1. Leer UN solo byte buscando un encabezado (Header)
            # Esto es clave para la auto-sincronización.
            byte_header = ser.read(1)
            
            if len(byte_header) < 1:
                continue # No llegó nada, seguimos esperando

            header = byte_header[0]

            # 2. ¿Es un encabezado conocido?
            if header == ID_LUX or header == ID_HUMEDAD:
                
                # Leemos los 3 bytes restantes del paquete: [HIGH] [LOW] [STOP]
                resto = ser.read(3)
                
                if len(resto) == 3:
                    high = resto[0]
                    low  = resto[1]
                    stop = resto[2]

                    # 3. Validar el final de trama
                    if stop == BYTE_STOP:
                        # Reconstruir valor de 16 bits
                        valor = (high << 8) | low
                        
                        # Imprimir resultado
                        if header == ID_LUX:
                            sys.stdout.write(f"\r[LUX]     Luz:     {valor} lx     ")
                        else:
                            sys.stdout.write(f"\r[HUMEDAD] Tierra:  {valor} %      ")
                        
                        sys.stdout.flush()
                    else:
                        # Si falla el stop, no imprimimos error, solo limpiamos
                        # para intentar pescar el siguiente paquete limpio.
                        ser.reset_input_buffer()
            
            # Si el byte no era header, el loop continua y lee el siguiente.
            # Esto descarta automáticamente la "basura" entre paquetes.

    except serial.SerialException:
        print(f"\nError: No se puede abrir el puerto {PUERTO}. ¿Está conectado?")
    except KeyboardInterrupt:
        print("\n\nMonitor finalizado.")
        if 'ser' in locals() and ser.is_open:
            ser.close()

if __name__ == "__main__":
    iniciar_monitor()