import serial
import csv
import time
import datetime
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from matplotlib.gridspec import GridSpec
from collections import deque

# ==========================================
# 1. CONFIGURATION
# ==========================================
PUERTO = '/dev/ttyUSB1'  # <--- Ensure this matches your FT232 port
BAUDIOS = 9600
CSV_FILE = 'sensor_pump_data.csv'

# Graph Config
MAX_POINTS_WINDOW = 50   # Points for the "Zoomed in" top plot

# FPGA IDs
ID_LUX     = 0xAA
ID_HUMEDAD = 0xBB
BYTE_STOP  = 0x0A

# IRRIGATION PUMP SETTINGS (HYSTERESIS)
HUMIDITY_LOW_TRIGGER  = 30.0  # Pump turns ON if humidity < 30%
HUMIDITY_HIGH_RESET   = 35.0  # Pump turns OFF if humidity > 35%
current_pump_state    = False # False = OFF, True = ON

# ==========================================
# 2. DATA STORAGE
# ==========================================
# --- Real-time Window (Deque) ---
rt_time = deque(maxlen=MAX_POINTS_WINDOW)
rt_lux  = deque(maxlen=MAX_POINTS_WINDOW)
rt_hum  = deque(maxlen=MAX_POINTS_WINDOW)

# --- Full History (Lists for long-term study) ---
hist_time_idx = [] 
hist_hum      = []
hist_lux      = [] 
hist_pump     = [] 
global_counter = 0

# Initialize CSV
try:
    with open(CSV_FILE, 'x', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["Timestamp", "Sensor", "Value", "Unit", "Pump_State"])
except FileExistsError:
    pass

# Serial Connection
try:
    ser = serial.Serial(PUERTO, BAUDIOS, timeout=0.1)
    ser.reset_input_buffer()
    print(f"Connected to {PUERTO}.")
except Exception as e:
    print(f"ERROR: Could not open {PUERTO}")
    print(f"Details: {e}")
    # We do not exit here so the graph still opens (empty) for debugging

# ==========================================
# 3. LAYOUT SETUP (GridSpec)
# ==========================================
fig = plt.figure(figsize=(10, 10)) 
gs = GridSpec(4, 1, height_ratios=[2, 2, 2, 1], hspace=0.5)

# --- PLOT 1: Real Time Window (Top) ---
ax_rt_lux = fig.add_subplot(gs[0])
ax_rt_hum = ax_rt_lux.twinx()
ax_rt_lux.set_title('Real-Time Monitor (Last 50 points)')
ax_rt_lux.set_ylabel('Lux', color='tab:orange')
ax_rt_hum.set_ylabel('Humidity %', color='tab:blue')
ax_rt_hum.set_ylim(0, 100)

line_rt_lux, = ax_rt_lux.plot([], [], 'o-', color='tab:orange', markersize=3, label='Lux')
line_rt_hum, = ax_rt_hum.plot([], [], 's-', color='tab:blue', markersize=3, label='Humidity')

# --- PLOT 2: Historical Humidity (Middle 1) ---
ax_hist_hum = fig.add_subplot(gs[1])
ax_hist_hum.set_title('History: Humidity & Pump Cycles')
ax_hist_hum.set_ylabel('Humidity (%)')
ax_hist_hum.set_ylim(0, 100)
ax_hist_hum.grid(True, alpha=0.3)

line_hist_hum, = ax_hist_hum.plot([], [], color='tab:blue', linewidth=1.5)

# --- PLOT 3: Historical Lux (Middle 2) ---
ax_hist_lux = fig.add_subplot(gs[2], sharex=ax_hist_hum) 
ax_hist_lux.set_title('History: Light Intensity')
ax_hist_lux.set_ylabel('Lux')
ax_hist_lux.grid(True, alpha=0.3)

line_hist_lux, = ax_hist_lux.plot([], [], color='tab:orange', linewidth=1.5)

# --- TABLE: Hysteresis Info (Bottom) ---
ax_table = fig.add_subplot(gs[3])
ax_table.axis('off')
table_data = [
    ["Parameter", "Value", "Description"],
    ["Current Humidity", "0 %", "-"],
    ["Pump Status", "OFF", "Active if < 30%"],
    ["Lower Threshold", f"{HUMIDITY_LOW_TRIGGER}%", "Turn ON"],
    ["Upper Threshold", f"{HUMIDITY_HIGH_RESET}%", "Turn OFF"]
]
the_table = ax_table.table(cellText=table_data, loc='center', cellLoc='center')
the_table.auto_set_font_size(False)
the_table.set_fontsize(10)
the_table.scale(1, 1.5)

# ==========================================
# 4. LOGIC & UPDATE FUNCTION
# ==========================================
def control_pump_hysteresis(current_humidity):
    global current_pump_state
    if current_humidity < HUMIDITY_LOW_TRIGGER:
        current_pump_state = True
    elif current_humidity > HUMIDITY_HIGH_RESET:
        current_pump_state = False
    return current_pump_state

def update_plot(frame):
    global global_counter
    
    # Read from Serial
    if 'ser' in globals() and ser.is_open:
        while ser.in_waiting >= 4:
            byte_header = ser.read(1)
            if len(byte_header) < 1: continue
            header = byte_header[0]

            if header == ID_LUX or header == ID_HUMEDAD:
                paquete = ser.read(3)
                if len(paquete) == 3:
                    high, low, stop = paquete[0], paquete[1], paquete[2]
                    
                    if stop == BYTE_STOP:
                        val = (high << 8) | low
                        timestamp = datetime.datetime.now().strftime('%H:%M:%S')

                        # --- UPDATE LISTS ---
                        if header == ID_LUX:
                            rt_time.append(timestamp)
                            rt_lux.append(val)
                            last_h = rt_hum[-1] if len(rt_hum) > 0 else 0
                            rt_hum.append(last_h)
                            
                        elif header == ID_HUMEDAD:
                            is_pump_on = control_pump_hysteresis(val)
                            
                            if len(rt_hum) > 0:
                                rt_hum[-1] = val
                            else:
                                rt_hum.append(val)
                                rt_lux.append(0)
                                rt_time.append(timestamp)
                            
                            global_counter += 1
                            hist_time_idx.append(global_counter)
                            hist_hum.append(val)
                            
                            current_lux = rt_lux[-1] if len(rt_lux) > 0 else 0
                            hist_lux.append(current_lux)
                            
                            hist_pump.append(100 if is_pump_on else 0)

                            # Log to CSV
                            with open(CSV_FILE, 'a', newline='') as f:
                                writer = csv.writer(f)
                                writer.writerow([timestamp, "HUM", val, "%", "ON" if is_pump_on else "OFF"])

    # --- REFRESH GRAPHICS ---
    
    # 1. Real Time Plot
    line_rt_lux.set_data(range(len(rt_time)), rt_lux)
    line_rt_hum.set_data(range(len(rt_time)), rt_hum)
    ax_rt_lux.set_xlim(0, MAX_POINTS_WINDOW)
    
    if len(rt_lux) > 0: 
        max_val_lux = max(rt_lux)
        ax_rt_lux.set_ylim(0, max_val_lux * 1.2 + 10)
    
    ax_rt_lux.set_xticks(range(len(rt_time)))
    ax_rt_lux.set_xticklabels(rt_time, rotation=45, ha='right', fontsize=8)
    for i, label in enumerate(ax_rt_lux.xaxis.get_ticklabels()):
        if i % 5 != 0: label.set_visible(False)

    # 2. Historical Humidity Plot
    if len(hist_time_idx) > 0:
        line_hist_hum.set_data(hist_time_idx, hist_hum)
        ax_hist_hum.set_xlim(0, max(hist_time_idx) + 10)
        
        # --- FIXED SECTION START ---
        # Clear previous green zones safely
        for collection in list(ax_hist_hum.collections):
            collection.remove()

        # Draw new green zones
        ax_hist_hum.fill_between(hist_time_idx, 0, 100, 
                             where=[p > 0 for p in hist_pump], 
                             facecolor='green', alpha=0.3, transform=ax_hist_hum.get_xaxis_transform())
        # --- FIXED SECTION END ---

    # 3. Historical Lux Plot
    if len(hist_time_idx) > 0:
        line_hist_lux.set_data(hist_time_idx, hist_lux)
        if len(hist_lux) > 0:
            current_max = max(hist_lux)
            ax_hist_lux.set_ylim(0, current_max * 1.1 + 10)

    # 4. Table Updates
    current_h_val = rt_hum[-1] if len(rt_hum) > 0 else 0
    pump_str = "ON (PUMPING)" if current_pump_state else "OFF"
    pump_color = [(0.5, 1, 0.5)] if current_pump_state else [(1, 1, 1)]
    
    the_table[1, 1].get_text().set_text(f"{current_h_val} %")
    cell_pump = the_table[2, 1]
    cell_pump.get_text().set_text(pump_str)
    cell_pump.set_facecolor(pump_color[0])

ani = animation.FuncAnimation(fig, update_plot, interval=100, cache_frame_data=False)
plt.show()

if 'ser' in locals() and ser.is_open:
    ser.close()