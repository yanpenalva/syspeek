# Syspeek 🖥️

A lightweight and portable Bash script that provides a quick overview of system health, including CPU, memory, disk, swap, inodes, network, and temperature metrics, all presented in a human-readable format. Ideal for terminal-based monitoring.

## Features

- Operating system info
- CPU usage and uptime
- Load average and core count
- Memory and swap usage
- Disk and inode usage
- Network I/O (RX/TX)
- Top processes (CPU and memory)
- Zombie process count
- CPU temperature (via lm-sensors)

## Preview

```
🖥️ Operating System
================================================================================
Ubuntu 22.04.4 LTS

🧮 CPU Usage
================================================================================
Usage         : 14.2%

💾 Memory Usage
================================================================================
Total Memory     : 31441.5   MB
Used Memory      : 12889.5   MB (41.0%)
Available Memory : 18552.1   MB (59.0%)

🗄️ Disk Usage
================================================================================
Disk Size        : 450G      
Used Space       : 119G       (26.40%)
Available Space  : 308G       (68.49%)
```

## Requirements

- bash
- awk, sed, grep, ps, df, top
- lm-sensors
- bc

## Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/your-user/syspeek.git
cd syspeek
chmod +x system_monitor.sh
```

## Usage

Simply run:

```bash
./monitor.sh
```

It will auto-install required dependencies (`lm-sensors`, `bc`) if your system uses apt, dnf or pacman.

## License

MIT
