import serial
import csv
import time
import datetime
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from collections import deque

# ==========================================
# CONFIGURACIÓN
# ==========================================
PUERTO  = 'COM8'   # <--- ¡AJUSTA ESTO!
BAUDIOS = 9600
CSV_FILE = 'datos_sensores.csv'

# Configuración de la gráfica
MAX_PUNTOS = 50   # Cuántos puntos mostrar en la ventana móvil

# IDs de la FPGA
ID_LUX     = 0xAA
ID_HUMEDAD = 0xBB
BYTE_STOP  = 0x0A

# ==========================================
# INICIALIZACIÓN
# ==========================================
# Listas tipo "deque" (cola) para guardar los datos de la gráfica
# Al llenarse, borran automáticamente los datos viejos
x_time = deque(maxlen=MAX_PUNTOS)
y_lux  = deque(maxlen=MAX_PUNTOS)
y_hum  = deque(maxlen=MAX_PUNTOS)

# Inicializar archivo CSV con cabeceras si no existe
try:
    with open(CSV_FILE, 'x', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["Timestamp", "Sensor", "Valor", "Unidad"])
except FileExistsError:
    pass # El archivo ya existe, solo le agregaremos datos (append)

# Conexión Serial
try:
    ser = serial.Serial(PUERTO, BAUDIOS, timeout=0.1)
    ser.reset_input_buffer()
    print(f"Conectado a {PUERTO}. Guardando en {CSV_FILE}...")
    print("Cierra la ventana de la gráfica para terminar.")
except:
    print(f"ERROR: No se pudo abrir {PUERTO}")
    exit()

# Configuración de Matplotlib
fig, ax1 = plt.subplots()
plt.subplots_adjust(bottom=0.3) # Espacio para las fechas abajo

# Eje Izquierdo (LUX)
color_lux = 'tab:orange'
ax1.set_xlabel('Hora')
ax1.set_ylabel('Iluminación (Lux)', color=color_lux)
line_lux, = ax1.plot([], [], color=color_lux, label='Lux', marker='o', markersize=4)
ax1.tick_params(axis='y', labelcolor=color_lux)
ax1.grid(True, linestyle='--', alpha=0.5)

# Eje Derecho (HUMEDAD) - Twin Axis
ax2 = ax1.twinx() 
color_hum = 'tab:blue'
ax2.set_ylabel('Humedad (%)', color=color_hum)
line_hum, = ax2.plot([], [], color=color_hum, label='Humedad', marker='s', markersize=4)
ax2.tick_params(axis='y', labelcolor=color_hum)
ax2.set_ylim(0, 105) # Fijar escala de humedad 0-100%

# Título
plt.title('Monitoreo FPGA en Tiempo Real')

# ==========================================
# FUNCIÓN DE LECTURA Y ACTUALIZACIÓN
# ==========================================
def leer_y_graficar(frame):
    # Leemos todo lo que haya en el buffer para no atrasarnos
    while ser.in_waiting >= 4:
        # 1. Buscar Header (Sincronización)
        byte_header = ser.read(1)
        
        if len(byte_header) < 1: continue
        header = byte_header[0]

        if header == ID_LUX or header == ID_HUMEDAD:
            # Leer resto del paquete
            paquete = ser.read(3)
            if len(paquete) == 3:
                high, low, stop = paquete[0], paquete[1], paquete[2]

                if stop == BYTE_STOP:
                    # --- DATO VÁLIDO ---
                    val = (high << 8) | low
                    timestamp = datetime.datetime.now().strftime('%H:%M:%S')
                    
                    # 1. GUARDAR EN CSV
                    with open(CSV_FILE, 'a', newline='') as f:
                        writer = csv.writer(f)
                        tipo = "LUX" if header == ID_LUX else "HUM"
                        unidad = "lx" if header == ID_LUX else "%"
                        writer.writerow([timestamp, tipo, val, unidad])

                    # 2. ACTUALIZAR DATOS DE GRÁFICA
                    # Solo agregamos tiempo una vez por ciclo de refresco visual para simplificar,
                    # o usamos el tiempo actual.
                    
                    if header == ID_LUX:
                        # Si llega Lux, asumimos que es un nuevo punto temporal
                        # (O podrías hacerlo independiente). 
                        # Aquí actualizamos ambas listas para mantener sincronía visual
                        # (Repetimos el último valor del otro sensor si no ha llegado nuevo)
                        
                        current_hum = y_hum[-1] if len(y_hum) > 0 else 0
                        
                        x_time.append(timestamp)
                        y_lux.append(val)
                        y_hum.append(current_hum) 
                        
                    elif header == ID_HUMEDAD:
                        # Actualizamos el último valor de humedad registrado
                        if len(y_hum) > 0:
                            y_hum[-1] = val # Sobrescribimos el último punto con el dato real
                        else:
                            # Si es el primer dato de todos
                            x_time.append(timestamp)
                            y_lux.append(0)
                            y_hum.append(val)

    # --- REFRESCO VISUAL ---
    # Convertir a listas para matplotlib
    line_lux.set_data(range(len(x_time)), y_lux)
    line_hum.set_data(range(len(x_time)), y_hum)
    
    # Ajustar escalas dinámicamente
    ax1.set_xlim(0, MAX_PUNTOS)
    
    # Ajustar escala vertical de LUX dinámicamente
    if len(y_lux) > 0:
        max_lux = max(y_lux)
        ax1.set_ylim(0, max_lux + (max_lux * 0.2) + 10) # +20% de margen

    # Etiquetas del eje X (Solo mostrar algunas para no saturar)
    ax1.set_xticks(range(len(x_time)))
    ax1.set_xticklabels(x_time, rotation=45, ha='right', fontsize=8)
    
    # Mostrar solo cada N etiquetas en X para que sea legible
    for i, label in enumerate(ax1.xaxis.get_ticklabels()):
        if i % 5 != 0: # Mostrar 1 de cada 5 etiquetas
            label.set_visible(False)

    return line_lux, line_hum

# ==========================================
# LOOP PRINCIPAL
# ==========================================
# interval=100 significa que busca datos cada 100ms
ani = animation.FuncAnimation(fig, leer_y_graficar, interval=100, cache_frame_data=False)

plt.show()

# Al cerrar la ventana:
ser.close()
print("Desconectado.")