#!/usr/bin/env python3
"""
NAS Monitor - Responsive CRT-optimized dashboard
"""

import os
import sys
import time
import subprocess
from datetime import datetime
from collections import deque
import shutil

import psutil
from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text
from rich.align import Align
from rich import box

# Configuration
MOUNT_PATH = "/run/media/sean/Expansion"
SHARE_NAME = "Expansion"
DEVICE = "/dev/sde2"
REFRESH_RATE = 0.5
SMOOTHING_FACTOR = 0.3
ROLLING_WINDOW = 10

console = Console()

# Animation frames
SPIN = ["◐", "◓", "◑", "◒"]
DOTS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]


def get_term_size():
    """Get terminal dimensions."""
    size = shutil.get_terminal_size((40, 20))
    return size.columns, size.lines


def get_disk_device():
    try:
        for part in psutil.disk_partitions(all=True):
            if part.mountpoint == MOUNT_PATH:
                return part.device
    except:
        pass
    return DEVICE


def fmt_size(b, short=False):
    for u in ['B', 'K', 'M', 'G', 'T']:
        if abs(b) < 1024.0:
            if short:
                return f"{b:.0f}{u}"
            return f"{b:.1f}{u}"
        b /= 1024.0
    return f"{b:.1f}P"


def fmt_speed(b):
    for u in ['B/s', 'K/s', 'M/s', 'G/s']:
        if abs(b) < 1024.0:
            return f"{b:.0f}{u}"
        b /= 1024.0
    return f"{b:.0f}T/s"


def get_disk_io():
    try:
        device_name = get_disk_device().replace('/dev/', '')
        counters = psutil.disk_io_counters(perdisk=True)
        if device_name in counters:
            return counters[device_name]
        base = ''.join(c for c in device_name if not c.isdigit())
        if base in counters:
            return counters[base]
    except:
        pass
    return None


def get_samba_connections():
    conns = []
    try:
        r = subprocess.run(['sudo', 'smbstatus', '-b'],
                          capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            lines = r.stdout.strip().split('\n')
            in_data = False
            for line in lines:
                if '----' in line:
                    in_data = True
                    continue
                if in_data and line.strip():
                    parts = line.split()
                    if len(parts) >= 4:
                        conns.append({'user': parts[1], 'ip': parts[3]})
    except:
        pass
    return conns


def get_open_files():
    files = []
    try:
        r = subprocess.run(['sudo', 'smbstatus', '-L'],
                          capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            lines = r.stdout.strip().split('\n')
            in_data = False
            for line in lines:
                if '----' in line:
                    in_data = True
                    continue
                if in_data and line.strip():
                    parts = line.split()
                    if len(parts) >= 8:
                        for i, p in enumerate(parts):
                            if p.startswith('/run/media'):
                                name_parts = []
                                for j in range(i + 1, len(parts)):
                                    if parts[j] in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']:
                                        break
                                    name_parts.append(parts[j])
                                name = ' '.join(name_parts) if name_parts else '.'
                                rw = parts[4] if len(parts) > 4 else 'RD'
                                if '.' in name.split('/')[-1]:
                                    files.append({'name': name, 'rw': rw})
                                break
    except:
        pass
    return files


class NASMonitor:
    def __init__(self):
        self.prev_io = get_disk_io()
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
        io = get_disk_io()
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
        """Mini sparkline."""
        if not vals or max(vals) == 0:
            return Text("▁" * width, style="dim")
        mx = max(vals)
        blocks = "▁▂▃▄▅▆▇█"
        t = Text()
        for v in list(vals)[-width:]:
            idx = min(int(v / mx * 7), 7) if mx > 0 else 0
            t.append(blocks[idx], style="cyan")
        # Pad if not enough history
        if len(list(vals)) < width:
            t = Text("▁" * (width - len(list(vals))), style="dim") + t
        return t

    def render(self):
        self.frame += 1
        self.update()

        # Get terminal size for responsive layout
        term_w, term_h = get_term_size()

        # Calculate widths (account for panel border + padding)
        inner_w = min(term_w - 4, 60)  # Max 60, leave room for borders
        bar_w = max(inner_w - 16, 10)  # Storage bar width
        spark_w = max(inner_w - 12, 8)  # Sparkline width
        sep_w = inner_w - 2  # Separator width

        # Get data
        try:
            usage = psutil.disk_usage(MOUNT_PATH)
            pct = usage.percent
            used = usage.used
            free = usage.free
            total_disk = usage.total
        except:
            pct = used = free = total_disk = 0

        conns = get_samba_connections()
        files = get_open_files()

        lines = []

        # === Header ===
        spin = SPIN[self.frame % 4] if self.is_active() else "●"
        status = "ACTIVE" if self.is_active() else "IDLE"
        hdr = Text()
        hdr.append(f" {spin} ", style="bold green" if self.is_active() else "dim")
        hdr.append("NAS ", style="bold white")
        hdr.append(datetime.now().strftime("%H:%M:%S"), style="cyan")
        hdr.append(f" [{status}]", style="bold green" if self.is_active() else "dim")
        lines.append(Align.center(hdr))
        lines.append(Text("─" * sep_w, style="dim"))

        # === Storage bar ===
        filled = int(pct / 100 * bar_w)
        color = "green" if pct < 50 else "yellow" if pct < 80 else "red"
        bar = Text()
        bar.append(" STO ", style=f"bold {color}")
        bar.append("█" * filled, style=color)
        bar.append("░" * (bar_w - filled), style="dim")
        bar.append(f" {pct:.0f}%", style=f"bold {color}")
        lines.append(bar)

        # Storage details
        stor = Text()
        stor.append(f"  {fmt_size(used)}", style="white")
        stor.append(f"/{fmt_size(total_disk)}", style="dim")
        stor.append(f"  Free:", style="dim")
        stor.append(f"{fmt_size(free)}", style="green")
        lines.append(stor)

        lines.append(Text("─" * sep_w, style="dim"))

        # === I/O speeds ===
        r_spin = DOTS[self.frame % 10] if self.raw_read > 1024 else "○"
        w_spin = DOTS[self.frame % 10] if self.raw_write > 1024 else "○"

        io_r = Text()
        io_r.append(f" {r_spin} ", style="green" if self.raw_read > 1024 else "dim")
        io_r.append("R ", style="bold green")
        io_r.append(f"{fmt_speed(self.read_speed):>8}", style="bold white")
        io_r.append(f"  pk:{fmt_speed(self.peak_r)}", style="dim")
        lines.append(io_r)

        io_w = Text()
        io_w.append(f" {w_spin} ", style="yellow" if self.raw_write > 1024 else "dim")
        io_w.append("W ", style="bold yellow")
        io_w.append(f"{fmt_speed(self.write_speed):>8}", style="bold white")
        io_w.append(f"  pk:{fmt_speed(self.peak_w)}", style="dim")
        lines.append(io_w)

        # Sparklines
        lines.append(Text(" R ", style="green") + self.spark(self.read_hist, spark_w))
        lines.append(Text(" W ", style="yellow") + self.spark(self.write_hist, spark_w))

        lines.append(Text("─" * sep_w, style="dim"))

        # === Connections ===
        conn_line = Text()
        conn_line.append(f" CONN:{len(conns)} ", style="bold magenta")
        if conns:
            c = conns[0]
            conn_line.append(f"{c['user']}@{c['ip']}", style="cyan")
        else:
            conn_line.append("none", style="dim")
        lines.append(conn_line)

        # === Files ===
        file_w = inner_w - 12  # Width for filename
        file_line = Text()
        file_line.append(f" FILE:{len(files)} ", style="bold yellow")
        if files:
            f = files[0]
            name = f['name'].split('/')[-1]
            if len(name) > file_w:
                name = name[:file_w - 3] + "..."
            rw = "W" if "RDWR" in f['rw'] else "R"
            file_line.append(f"{name}[{rw}]", style="white")
        else:
            file_line.append("none", style="dim")
        lines.append(file_line)

        lines.append(Text("─" * sep_w, style="dim"))

        # === Network & session ===
        net = Text()
        net.append(" \\\\192.168.1.72\\Expansion", style="green")
        lines.append(net)

        sess = Text()
        sess.append(f" Session: ", style="dim")
        sess.append(f"↕{fmt_size(self.total)}", style="cyan")
        up = int(time.time() - self.start)
        m, s = divmod(up, 60)
        h, m = divmod(m, 60)
        sess.append(f"  {h}:{m:02d}:{s:02d}", style="dim")
        lines.append(sess)

        # === Footer ===
        lines.append(Text("─" * sep_w, style="dim"))
        foot = Text()
        foot.append(" Ctrl+C exit", style="dim")
        lines.append(Align.center(foot))

        # Combine into table
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

    def run(self):
        try:
            with Live(self.render(), refresh_per_second=2, console=console, screen=True) as live:
                while True:
                    live.update(self.render())
                    time.sleep(REFRESH_RATE)
        except KeyboardInterrupt:
            pass


def main():
    if not os.path.ismount(MOUNT_PATH):
        console.print(f"[red]Error:[/] {MOUNT_PATH} not mounted")
        sys.exit(1)
    NASMonitor().run()


if __name__ == "__main__":
    main()
