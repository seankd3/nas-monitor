# NAS Monitor

A responsive terminal dashboard for monitoring Samba NAS shares.

![Python](https://img.shields.io/badge/python-3.8+-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## Features

- Real-time read/write speed monitoring with smoothed rolling averages
- Storage usage visualization
- Active Samba connections display
- Open files tracking
- Responsive layout adapts to terminal size
- Animated activity indicators
- Sparkline graphs for I/O history
- Peak speed tracking
- Session transfer totals

## Screenshot

```
╭──────────────────NAS──────────────────╮
│      ◐ NAS 12:34:56 [ACTIVE]          │
│───────────────────────────────────────│
│ STO ████████████░░░░░░░░░░░░░░░░ 39%  │
│   7.0T/18.2T  Free:11.2T              │
│───────────────────────────────────────│
│ ⠋ R    120M/s  pk:150M/s              │
│ ⠋ W     45M/s  pk:85M/s               │
│ R ▁▂▃▄▅▆▇█▇▆▅▄▃▂▁▂▃▄▅▆▇█▇▆▅▄▃▂       │
│ W ▁▁▂▃▄▅▆▇▆▅▄▃▂▁▁▂▃▄▅▆▇▆▅▄▃▂▁▁       │
│───────────────────────────────────────│
│ CONN:1 sean@192.168.1.68              │
│ FILE:3 video.mp4[W]                   │
│───────────────────────────────────────│
│ \\192.168.1.72\Expansion              │
│ Session: ↕1.2G  0:05:23               │
│───────────────────────────────────────│
│           Ctrl+C exit                 │
╰────────────Expansion──────────────────╯
```

## Requirements

- Python 3.8+
- `psutil` - System monitoring
- `rich` - Terminal UI

### Arch Linux

```bash
sudo pacman -S python-psutil python-rich
```

### pip

```bash
pip install psutil rich
```

## Installation

```bash
# Clone the repo
git clone https://github.com/seankd01/nas-monitor.git

# Make executable and add to path
chmod +x nas-monitor/nas
cp nas-monitor/nas ~/.local/bin/

# For Samba status without password prompts (optional)
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/smbstatus" | sudo tee /etc/sudoers.d/smbstatus
```

## Configuration

Edit the script to set your mount path and share name:

```python
MOUNT_PATH = "/run/media/sean/Expansion"
SHARE_NAME = "Expansion"
```

## Usage

```bash
nas
```

Press `Ctrl+C` to exit.

## License

MIT
