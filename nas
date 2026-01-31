#!/usr/bin/env python3
"""
NAS Monitor - Terminal and Web Dashboard with Chromecast Support

Usage:
    nas          - Run terminal dashboard (requires 'rich' library)
    nas web      - Start web server only
    nas cast     - Start web server and cast to Chromecast
    nas stop     - Stop all nas processes
"""

import os
import sys
import time
import json
import socket
import threading
import subprocess
import psutil
from collections import deque
from datetime import datetime

# Configuration
MOUNT_PATH = "/run/media/sean/Expansion"
SHARE_NAME = "Expansion"
PORT = 8765
CHROMECAST_NAME = "CRT Monitor"
REFRESH_RATE = 0.5
SMOOTHING_FACTOR = 0.3
ROLLING_WINDOW = 10

# Shared state for web mode
class NASState:
    def __init__(self):
        self.read_speed = 0
        self.write_speed = 0
        self.total = 0
        self.peak_r = 0
        self.peak_w = 0
        self.read_hist = deque(maxlen=60)
        self.write_hist = deque(maxlen=60)
        self.read_avg_q = deque(maxlen=4)
        self.write_avg_q = deque(maxlen=4)
        # Longer rolling averages (30s and 60s at 0.5s intervals)
        self.read_avg_30s = deque(maxlen=60)
        self.write_avg_30s = deque(maxlen=60)
        self.read_avg_60s = deque(maxlen=120)
        self.write_avg_60s = deque(maxlen=120)
        self.start = time.time()
        self.lock = threading.Lock()
        self.prev_disk_io = psutil.disk_io_counters()
        self.prev_time = time.time()

state = NASState()

def fmt_size(bytes_val):
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024.0:
            return f"{bytes_val:.1f}{unit}"
        bytes_val /= 1024.0
    return f"{bytes_val:.1f}PB"

def fmt_speed(bytes_sec):
    return f"{fmt_size(bytes_sec)}/s"

def get_samba_connections():
    try:
        output = subprocess.check_output(
            "sudo smbstatus -b 2>/dev/null | grep -v 'PID'",
            shell=True
        ).decode()
        conns = []
        for line in output.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                conns.append({"user": parts[1], "ip": parts[3]})
        return conns
    except:
        return []

def update_state():
    global state
    while True:
        try:
            curr_io = psutil.disk_io_counters()
            now = time.time()
            dt = now - state.prev_time

            if dt >= 0.5:
                read_bytes = curr_io.read_bytes - state.prev_disk_io.read_bytes
                write_bytes = curr_io.write_bytes - state.prev_disk_io.write_bytes

                r_speed = read_bytes / dt
                w_speed = write_bytes / dt

                with state.lock:
                    state.read_avg_q.append(r_speed)
                    state.write_avg_q.append(w_speed)
                    state.read_speed = sum(state.read_avg_q) / len(state.read_avg_q)
                    state.write_speed = sum(state.write_avg_q) / len(state.write_avg_q)
                    state.total += read_bytes + write_bytes
                    state.peak_r = max(state.peak_r, state.read_speed)
                    state.peak_w = max(state.peak_w, state.write_speed)
                    state.read_hist.append(state.read_speed)
                    state.write_hist.append(state.write_speed)
                    # Track longer rolling averages
                    state.read_avg_30s.append(r_speed)
                    state.write_avg_30s.append(w_speed)
                    state.read_avg_60s.append(r_speed)
                    state.write_avg_60s.append(w_speed)

                state.prev_disk_io = curr_io
                state.prev_time = now
        except:
            pass
        time.sleep(0.5)

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    except:
        return '127.0.0.1'
    finally:
        s.close()

def get_data_json():
    global state

    try:
        usage = psutil.disk_usage(MOUNT_PATH)
        disk_pct = usage.percent
        disk_used = fmt_size(usage.used)
        disk_total = fmt_size(usage.total)
        disk_free = fmt_size(usage.free)
    except:
        disk_pct = 0
        disk_used = "N/A"
        disk_total = "N/A"
        disk_free = "N/A"

    connections = get_samba_connections()[:3]
    cpu_pct = psutil.cpu_percent()
    mem = psutil.virtual_memory()
    mem_pct = mem.percent

    try:
        net = psutil.net_io_counters()
        net_sent = fmt_size(net.bytes_sent)
        net_recv = fmt_size(net.bytes_recv)
    except:
        net_sent = "N/A"
        net_recv = "N/A"

    try:
        load1, load5, load15 = os.getloadavg()
    except:
        load1 = load5 = load15 = 0

    proc_count = len(psutil.pids())

    with state.lock:
        is_active = state.read_speed > 1024 or state.write_speed > 1024
        up = int(time.time() - state.start)
        h, rem = divmod(up, 3600)
        m, s = divmod(rem, 60)

        max_hist = max(max(state.read_hist, default=1), max(state.write_hist, default=1), 1)
        read_hist = [min(100, int(v / max_hist * 100)) for v in list(state.read_hist)[-30:]]
        write_hist = [min(100, int(v / max_hist * 100)) for v in list(state.write_hist)[-30:]]

        # Calculate rolling averages
        r_avg_30 = sum(state.read_avg_30s) / len(state.read_avg_30s) if state.read_avg_30s else 0
        w_avg_30 = sum(state.write_avg_30s) / len(state.write_avg_30s) if state.write_avg_30s else 0
        r_avg_60 = sum(state.read_avg_60s) / len(state.read_avg_60s) if state.read_avg_60s else 0
        w_avg_60 = sum(state.write_avg_60s) / len(state.write_avg_60s) if state.write_avg_60s else 0

        data = {
            "read_speed": fmt_speed(state.read_speed),
            "write_speed": fmt_speed(state.write_speed),
            "peak_r": fmt_speed(state.peak_r),
            "peak_w": fmt_speed(state.peak_w),
            "read_avg_30": fmt_speed(r_avg_30),
            "write_avg_30": fmt_speed(w_avg_30),
            "read_avg_60": fmt_speed(r_avg_60),
            "write_avg_60": fmt_speed(w_avg_60),
            "total": fmt_size(state.total),
            "uptime": f"{h:02d}:{m:02d}:{s:02d}",
            "read_hist": read_hist,
            "write_hist": write_hist,
            "disk_pct": disk_pct,
            "disk_used": disk_used,
            "disk_total": disk_total,
            "disk_free": disk_free,
            "connections": connections,
            "is_active": is_active,
            "cpu_pct": cpu_pct,
            "mem_pct": mem_pct,
            "net_sent": net_sent,
            "net_recv": net_recv,
            "load1": f"{load1:.2f}",
            "load5": f"{load5:.2f}",
            "load15": f"{load15:.2f}",
            "proc_count": proc_count,
            "timestamp": time.strftime("%H:%M:%S")
        }
    return json.dumps(data)

LOCAL_IP = get_local_ip()

PAGE_HTML = f"""<!DOCTYPE html>
<html>
<head>
    <title>NAS Monitor</title>
    <link href="https://fonts.googleapis.com/css2?family=VT323&display=swap" rel="stylesheet">
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        html, body {{
            height: 100%;
            background: #000;
            color: #fff;
            font-family: 'VT323', monospace;
            font-size: 5vh;
            overflow: hidden;
            cursor: none;
        }}
        .wrapper {{
            padding: 5% 10%;
            height: 100vh;
        }}
        .main {{
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            grid-template-rows: auto 1fr 1fr auto;
            gap: 0.5vh;
            height: 100%;
        }}
        .box {{
            border: 1px solid #666;
            padding: 0.8vh 1vh;
            position: relative;
            background: #0a0a0a;
        }}
        .box-title {{
            position: absolute;
            top: -1.2vh;
            left: 1vh;
            background: #000;
            padding: 0 0.5vh;
            font-weight: bold;
            color: #aaa;
            font-size: 4vh;
            letter-spacing: 1px;
        }}
        .header {{
            grid-column: 1 / -1;
            display: flex;
            justify-content: space-between;
            align-items: center;
            border: 1px solid #666;
            padding: 0.8vh 1.5vh;
            background: #0a0a0a;
        }}
        .header .title {{ font-size: 7vh; letter-spacing: 3px; }}
        .status {{ display: flex; align-items: center; gap: 1.5vh; }}
        .dot {{
            width: 1.8vh; height: 1.8vh;
            border-radius: 50%;
            background: #333;
            box-shadow: 0 0 5px #333;
        }}
        .dot.on {{ background: #fff; box-shadow: 0 0 10px #fff; animation: pulse 0.5s infinite; }}
        @keyframes pulse {{ 50% {{ opacity: 0.5; }} }}
        .graph {{
            display: flex;
            align-items: flex-end;
            height: 5vh;
            gap: 1px;
            background: #111;
            padding: 2px;
            margin-top: 0.5vh;
        }}
        .bar {{
            flex: 1;
            background: #fff;
            min-width: 2px;
            transition: height 0.2s;
        }}
        .bar.w {{ background: #888; }}
        .row {{
            display: flex;
            justify-content: space-between;
            padding: 0.2vh 0;
            border-bottom: 1px dotted #222;
        }}
        .row:last-child {{ border-bottom: none; }}
        .label {{ color: #666; }}
        .val {{ font-weight: bold; }}
        .big {{ font-size: 7vh; }}
        .med {{ font-size: 6vh; }}
        .meter {{
            height: 1.5vh;
            background: #111;
            border: 1px solid #444;
            margin: 0.3vh 0;
        }}
        .meter-fill {{
            height: 100%;
            background: #fff;
            transition: width 0.3s;
        }}
        .footer {{
            grid-column: 1 / -1;
            display: flex;
            justify-content: space-between;
            border: 1px solid #666;
            padding: 0.5vh 1.5vh;
            font-size: 4.5vh;
            color: #666;
            background: #0a0a0a;
        }}
        .blink {{ animation: b 1s step-end infinite; }}
        @keyframes b {{ 50% {{ opacity: 0; }} }}
        .time {{ color: #888; }}
        .spin {{ display: inline-block; }}
        .spin.active {{ animation: spin 1s linear infinite; }}
        @keyframes spin {{ 100% {{ transform: rotate(360deg); }} }}
    </style>
</head>
<body>
<div class="wrapper">
<div class="main">
    <div class="header">
        <span class="title">NAS MONITOR</span>
        <div class="status">
            <span id="time" class="time">00:00:00</span>
            <div id="dot" class="dot"></div>
            <span id="status">IDLE</span>
        </div>
    </div>
    <div class="box" style="grid-row: 2;">
        <span class="box-title">DISK READ</span>
        <div class="row"><span class="label">Speed</span><span id="r-spd" class="val big">0B/s</span></div>
        <div class="row"><span class="label">Peak</span><span id="r-pk" class="val">0B/s</span></div>
        <div class="row"><span class="label">30s Avg</span><span id="r-avg30" class="val">0B/s</span></div>
        <div class="row"><span class="label">60s Avg</span><span id="r-avg60" class="val">0B/s</span></div>
        <div id="r-graph" class="graph"></div>
    </div>
    <div class="box" style="grid-row: 2;">
        <span class="box-title">DISK WRITE</span>
        <div class="row"><span class="label">Speed</span><span id="w-spd" class="val big">0B/s</span></div>
        <div class="row"><span class="label">Peak</span><span id="w-pk" class="val">0B/s</span></div>
        <div class="row"><span class="label">30s Avg</span><span id="w-avg30" class="val">0B/s</span></div>
        <div class="row"><span class="label">60s Avg</span><span id="w-avg60" class="val">0B/s</span></div>
        <div id="w-graph" class="graph"></div>
    </div>
    <div class="box" style="grid-row: 2;">
        <span class="box-title">SYSTEM</span>
        <div class="row"><span class="label">CPU</span><span id="cpu" class="val med">0%</span></div>
        <div class="meter"><div id="cpu-bar" class="meter-fill" style="width:0%"></div></div>
        <div class="row"><span class="label">MEM</span><span id="mem" class="val med">0%</span></div>
        <div class="meter"><div id="mem-bar" class="meter-fill" style="width:0%"></div></div>
        <div class="row"><span class="label">Load</span><span id="load" class="val">0.00</span></div>
    </div>
    <div class="box" style="grid-row: 3;">
        <span class="box-title">STORAGE</span>
        <div class="row"><span class="label">Volume</span><span class="val">{SHARE_NAME}</span></div>
        <div class="meter"><div id="disk-bar" class="meter-fill" style="width:0%"></div></div>
        <div class="row"><span class="label">Used</span><span id="disk-used" class="val">0B</span></div>
        <div class="row"><span class="label">Free</span><span id="disk-free" class="val">0B</span></div>
        <div class="row"><span class="label">Total</span><span id="disk-total" class="val">0B</span></div>
    </div>
    <div class="box" style="grid-row: 3;">
        <span class="box-title">NETWORK</span>
        <div class="row"><span class="label">Sent</span><span id="net-sent" class="val">0B</span></div>
        <div class="row"><span class="label">Recv</span><span id="net-recv" class="val">0B</span></div>
        <div class="row"><span class="label">Conns</span><span id="conn-ct" class="val">0</span></div>
        <div id="conn-list"></div>
    </div>
    <div class="box" style="grid-row: 3;">
        <span class="box-title">SESSION</span>
        <div class="row"><span class="label">Transfer</span><span id="total" class="val med">0B</span></div>
        <div class="row"><span class="label">Uptime</span><span id="uptime" class="val">00:00:00</span></div>
        <div class="row"><span class="label">Procs</span><span id="procs" class="val">0</span></div>
        <div class="row"><span class="label">Share</span><span class="val" style="font-size:4vh;">\\\\{LOCAL_IP}\\{SHARE_NAME}</span></div>
    </div>
    <div class="footer">
        <span><span class="spin" id="spinner">*</span> {LOCAL_IP}:{PORT}</span>
        <span>Load: <span id="load-full">0.00 0.00 0.00</span></span>
        <span class="blink">_</span>
    </div>
</div>
</div>
<script>
function upd(){{
    fetch('/data').then(r=>r.json()).then(d=>{{
        document.getElementById('dot').className='dot'+(d.is_active?' on':'');
        document.getElementById('spinner').className='spin'+(d.is_active?' active':'');
        document.getElementById('status').textContent=d.is_active?'ACTIVE':'IDLE';
        document.getElementById('time').textContent=d.timestamp;
        document.getElementById('r-spd').textContent=d.read_speed;
        document.getElementById('w-spd').textContent=d.write_speed;
        document.getElementById('r-pk').textContent=d.peak_r;
        document.getElementById('w-pk').textContent=d.peak_w;
        document.getElementById('r-avg30').textContent=d.read_avg_30;
        document.getElementById('r-avg60').textContent=d.read_avg_60;
        document.getElementById('w-avg30').textContent=d.write_avg_30;
        document.getElementById('w-avg60').textContent=d.write_avg_60;
        document.getElementById('r-graph').innerHTML=d.read_hist.map(h=>`<div class="bar" style="height:${{Math.max(2,h)}}%"></div>`).join('');
        document.getElementById('w-graph').innerHTML=d.write_hist.map(h=>`<div class="bar w" style="height:${{Math.max(2,h)}}%"></div>`).join('');
        document.getElementById('cpu').textContent=d.cpu_pct+'%';
        document.getElementById('cpu-bar').style.width=d.cpu_pct+'%';
        document.getElementById('mem').textContent=d.mem_pct+'%';
        document.getElementById('mem-bar').style.width=d.mem_pct+'%';
        document.getElementById('load').textContent=d.load1;
        document.getElementById('load-full').textContent=d.load1+' '+d.load5+' '+d.load15;
        document.getElementById('disk-bar').style.width=d.disk_pct+'%';
        document.getElementById('disk-used').textContent=d.disk_used;
        document.getElementById('disk-free').textContent=d.disk_free;
        document.getElementById('disk-total').textContent=d.disk_total;
        document.getElementById('net-sent').textContent=d.net_sent;
        document.getElementById('net-recv').textContent=d.net_recv;
        document.getElementById('conn-ct').textContent=d.connections.length;
        document.getElementById('conn-list').innerHTML=d.connections.slice(0,2).map(c=>`<div class="row"><span class="label">${{c.user}}</span><span class="val">${{c.ip}}</span></div>`).join('');
        document.getElementById('total').textContent=d.total;
        document.getElementById('uptime').textContent=d.uptime;
        document.getElementById('procs').textContent=d.proc_count;
    }});
}}
setInterval(upd,500);upd();
</script>
</body>
</html>
"""

# ============ Web Server ============

from http.server import HTTPServer, BaseHTTPRequestHandler

class DashboardHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            try:
                self.wfile.write(PAGE_HTML.encode())
            except BrokenPipeError:
                pass
        elif self.path == '/data':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(get_data_json().encode())
        else:
            self.send_error(404)

    def log_message(self, format, *args):
        pass

def cast_to_chromecast():
    """Cast dashboard to Chromecast and keep it alive"""
    url = f"http://{LOCAL_IP}:{PORT}"

    # Initial cast
    print(f"Casting to {CHROMECAST_NAME}...")
    subprocess.run(["catt", "-d", CHROMECAST_NAME, "stop"], capture_output=True)
    time.sleep(1)
    subprocess.run(["catt", "-d", CHROMECAST_NAME, "cast_site", url], capture_output=True)
    print(f"Dashboard casting at {url}")

    # Keep-alive loop - check every 5 minutes
    while True:
        time.sleep(300)
        try:
            result = subprocess.run(
                ["catt", "-d", CHROMECAST_NAME, "info"],
                capture_output=True, text=True
            )
            if "DashCast" not in result.stdout:
                print("Chromecast disconnected, recasting...")
                subprocess.run(["catt", "-d", CHROMECAST_NAME, "cast_site", url],
                               capture_output=True)
        except:
            pass

def run_web_server(cast=False):
    """Run the web dashboard server"""
    if not os.path.ismount(MOUNT_PATH):
        print(f"Warning: {MOUNT_PATH} not mounted")

    # Start state updater
    updater = threading.Thread(target=update_state, daemon=True)
    updater.start()

    # Start cast thread if requested
    if cast:
        cast_thread = threading.Thread(target=cast_to_chromecast, daemon=True)
        cast_thread.start()

    # Start web server
    print(f"Starting NAS Monitor web server on port {PORT}...")
    server = HTTPServer(('0.0.0.0', PORT), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        if cast:
            subprocess.run(["catt", "-d", CHROMECAST_NAME, "stop"], capture_output=True)
        server.shutdown()

# ============ Terminal Mode ============

def run_terminal():
    """Run the terminal dashboard using rich library"""
    try:
        from rich.console import Console
        from rich.live import Live
        from rich.panel import Panel
        from rich.table import Table
        from rich.text import Text
        from rich.align import Align
        from rich import box
        import shutil
    except ImportError:
        print("Terminal mode requires 'rich' library.")
        print("Install with: pip install rich")
        print("Or use 'nas web' or 'nas cast' for web mode.")
        sys.exit(1)

    console = Console()
    SPIN = ["◐", "◓", "◑", "◒"]
    DOTS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    class TerminalMonitor:
        def __init__(self):
            self.prev_io = psutil.disk_io_counters()
            self.prev_time = time.time()
            self.raw_read = 0
            self.raw_write = 0
            self.read_speed = 0
            self.write_speed = 0
            self.read_samples = deque([0] * ROLLING_WINDOW, maxlen=ROLLING_WINDOW)
            self.write_samples = deque([0] * ROLLING_WINDOW, maxlen=ROLLING_WINDOW)
            self.read_hist = deque(maxlen=60)
            self.write_hist = deque(maxlen=60)
            self.frame = 0
            self.peak_r = 0
            self.peak_w = 0
            self.total = 0
            self.start = time.time()

        def smooth(self, cur, new):
            if cur == 0:
                return new
            return (SMOOTHING_FACTOR * new) + ((1 - SMOOTHING_FACTOR) * cur)

        def is_active(self):
            return self.raw_read > 1024 or self.raw_write > 1024

        def update(self):
            io = psutil.disk_io_counters()
            now = time.time()
            if io and self.prev_io:
                dt = now - self.prev_time
                if dt > 0:
                    self.raw_read = (io.read_bytes - self.prev_io.read_bytes) / dt
                    self.raw_write = (io.write_bytes - self.prev_io.write_bytes) / dt
                    self.read_samples.append(self.raw_read)
                    self.write_samples.append(self.raw_write)
                    self.read_speed = self.smooth(self.read_speed, sum(self.read_samples) / len(self.read_samples))
                    self.write_speed = self.smooth(self.write_speed, sum(self.write_samples) / len(self.write_samples))
                    self.total += (io.read_bytes - self.prev_io.read_bytes) + (io.write_bytes - self.prev_io.write_bytes)
                    if self.raw_read > self.peak_r:
                        self.peak_r = self.raw_read
                    if self.raw_write > self.peak_w:
                        self.peak_w = self.raw_write
            self.prev_io = io
            self.prev_time = now
            self.read_hist.append(self.read_speed)
            self.write_hist.append(self.write_speed)

        def spark(self, vals, width):
            if not vals or max(vals) == 0:
                return Text("▁" * width, style="dim")
            mx = max(vals)
            blocks = "▁▂▃▄▅▆▇█"
            t = Text()
            for v in list(vals)[-width:]:
                idx = min(int(v / mx * 7), 7) if mx > 0 else 0
                t.append(blocks[idx], style="cyan")
            if len(list(vals)) < width:
                t = Text("▁" * (width - len(list(vals))), style="dim") + t
            return t

        def render(self):
            self.frame += 1
            self.update()

            term_w, term_h = shutil.get_terminal_size((40, 20))
            inner_w = min(term_w - 4, 60)
            bar_w = max(inner_w - 16, 10)
            spark_w = max(inner_w - 12, 8)
            sep_w = inner_w - 2

            try:
                usage = psutil.disk_usage(MOUNT_PATH)
                pct = usage.percent
                used = usage.used
                free = usage.free
                total_disk = usage.total
            except:
                pct = used = free = total_disk = 0

            conns = get_samba_connections()
            lines = []

            spin = SPIN[self.frame % 4] if self.is_active() else "●"
            status = "ACTIVE" if self.is_active() else "IDLE"
            hdr = Text()
            hdr.append(f" {spin} ", style="bold green" if self.is_active() else "dim")
            hdr.append("NAS ", style="bold white")
            hdr.append(datetime.now().strftime("%H:%M:%S"), style="cyan")
            hdr.append(f" [{status}]", style="bold green" if self.is_active() else "dim")
            lines.append(Align.center(hdr))
            lines.append(Text("─" * sep_w, style="dim"))

            filled = int(pct / 100 * bar_w)
            color = "green" if pct < 50 else "yellow" if pct < 80 else "red"
            bar = Text()
            bar.append(" STO ", style=f"bold {color}")
            bar.append("█" * filled, style=color)
            bar.append("░" * (bar_w - filled), style="dim")
            bar.append(f" {pct:.0f}%", style=f"bold {color}")
            lines.append(bar)

            stor = Text()
            stor.append(f"  {fmt_size(used)}", style="white")
            stor.append(f"/{fmt_size(total_disk)}", style="dim")
            stor.append(f"  Free:", style="dim")
            stor.append(f"{fmt_size(free)}", style="green")
            lines.append(stor)
            lines.append(Text("─" * sep_w, style="dim"))

            r_spin = DOTS[self.frame % 10] if self.raw_read > 1024 else "○"
            w_spin = DOTS[self.frame % 10] if self.raw_write > 1024 else "○"

            io_r = Text()
            io_r.append(f" {r_spin} ", style="green" if self.raw_read > 1024 else "dim")
            io_r.append("R ", style="bold green")
            io_r.append(f"{fmt_speed(self.read_speed):>12}", style="bold white")
            io_r.append(f"  pk:{fmt_speed(self.peak_r)}", style="dim")
            lines.append(io_r)

            io_w = Text()
            io_w.append(f" {w_spin} ", style="yellow" if self.raw_write > 1024 else "dim")
            io_w.append("W ", style="bold yellow")
            io_w.append(f"{fmt_speed(self.write_speed):>12}", style="bold white")
            io_w.append(f"  pk:{fmt_speed(self.peak_w)}", style="dim")
            lines.append(io_w)

            lines.append(Text(" R ", style="green") + self.spark(self.read_hist, spark_w))
            lines.append(Text(" W ", style="yellow") + self.spark(self.write_hist, spark_w))
            lines.append(Text("─" * sep_w, style="dim"))

            conn_line = Text()
            conn_line.append(f" CONN:{len(conns)} ", style="bold magenta")
            if conns:
                c = conns[0]
                conn_line.append(f"{c['user']}@{c['ip']}", style="cyan")
            else:
                conn_line.append("none", style="dim")
            lines.append(conn_line)
            lines.append(Text("─" * sep_w, style="dim"))

            net = Text()
            net.append(f" {SHARE_NAME}", style="green")
            lines.append(net)

            sess = Text()
            sess.append(f" Session: ", style="dim")
            sess.append(f"↕{fmt_size(self.total)}", style="cyan")
            up = int(time.time() - self.start)
            m, s = divmod(up, 60)
            h, m = divmod(m, 60)
            sess.append(f"  {h}:{m:02d}:{s:02d}", style="dim")
            lines.append(sess)

            lines.append(Text("─" * sep_w, style="dim"))
            foot = Text()
            foot.append(" Ctrl+C exit", style="dim")
            lines.append(Align.center(foot))

            tbl = Table.grid(expand=True)
            tbl.add_column()
            for line in lines:
                tbl.add_row(line)

            return Panel(
                tbl,
                box=box.ROUNDED,
                border_style="cyan",
                padding=(0, 1),
                title="[bold]NAS[/]",
                subtitle=f"[dim]{SHARE_NAME}[/]"
            )

    if not os.path.ismount(MOUNT_PATH):
        console.print(f"[yellow]Warning:[/] {MOUNT_PATH} not mounted")

    mon = TerminalMonitor()
    try:
        with Live(mon.render(), refresh_per_second=2, console=console, screen=True) as live:
            while True:
                live.update(mon.render())
                time.sleep(REFRESH_RATE)
    except KeyboardInterrupt:
        pass

def stop_all():
    """Stop all nas processes"""
    subprocess.run(["pkill", "-f", "python.*nas.*(web|cast)"], capture_output=True)
    subprocess.run(["catt", "-d", CHROMECAST_NAME, "stop"], capture_output=True)
    print("Stopped all NAS monitor processes")

def main():
    if len(sys.argv) < 2:
        run_terminal()
    elif sys.argv[1] == "web":
        run_web_server(cast=False)
    elif sys.argv[1] == "cast":
        run_web_server(cast=True)
    elif sys.argv[1] == "stop":
        stop_all()
    elif sys.argv[1] in ["-h", "--help", "help"]:
        print(__doc__)
    else:
        print(f"Unknown command: {sys.argv[1]}")
        print(__doc__)
        sys.exit(1)

if __name__ == "__main__":
    main()
