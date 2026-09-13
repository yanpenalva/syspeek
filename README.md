# Syspeek

Point-in-time system health snapshot for Linux, written in Bash.

Syspeek collects CPU, memory, swap, disk, network, processes, and temperatures once per run and prints a human-readable report or JSON. No daemon, no root required for normal collection, no automatic package installation.

## Scope and limits

- Linux only. The implementation reads `/proc`, `/proc/net/dev`, `/proc/meminfo`, and uses `ps` and `df` with GNU/Linux semantics.
- Single snapshot per execution. There is no watch mode, history, alerts, GPU, battery, service, or container inventory (future backlog).
- Not portable to macOS/BSD. The name "portable" in older versions meant "single script"; it never meant cross-OS.
- Normal collection does not need root. Installing the optional `lm-sensors` package may need root/sudo (see `--install`).

## Features

- OS, kernel, architecture, date, boot time, uptime
- CPU usage from `/proc/stat` (no `top` parsing), load average from `/proc/loadavg`, logical CPU count
- Memory from `/proc/meminfo`, swap from `/proc/meminfo`
- Disk and inode usage for `/` by default, `--all-mounts` for extra local filesystems
- All non-loopback interfaces by default, exact-match `--interface` filter
- Top processes by CPU and memory with explicit `ps` format (user, PID, %CPU, %MEM, full command), zombie count
- Generic temperature parsing (`Core`, `Package`, `Tctl`, `Tdie`, `Composite`, `Sensor`, `tempN`, comma/dot locales)
- Human output and `--json` output with graceful degradation (`null` + `warnings`, exit stays `0`)

## Requirements

Mandatory (report aborts with exit `3` if missing):

- `bash`
- `awk`, `ps`, `df`, `grep`, `sed`
- Linux `/proc` for most metrics

Optional (missing metrics degrade to warnings, report still succeeds):

- `sensors` (`lm-sensors`) for temperatures
- Any terminal with ANSI support for colors (colors auto-disable otherwise; no `tput` dependency)
- `nproc` or `/proc/cpuinfo` for CPU count (falls back to `getconf`)

No `bc` dependency. All math uses `awk`. All output uses `printf`.

## Quick start

```bash
git clone https://github.com/yanpenalva/syspeek.git
cd syspeek
chmod +x monitor.sh
./monitor.sh
```

JSON mode:

```bash
./monitor.sh --json
```

## Installation of optional dependencies

Manual per distribution (recommended):

```bash
# Debian/Ubuntu
sudo apt install lm-sensors

# Fedora/RHEL
sudo dnf install lm-sensors

# Arch
sudo pacman -S lm_sensors
```

After installing on real hardware you may want:

```bash
sudo sensors-detect
```

## Safe default behavior and `--install`

- Default run never calls a package manager. It only reads the system and reports.
- Dependency auto-installation from older versions was removed.
- `--install` is explicit and only installs the optional temperature stack:

```bash
./monitor.sh --install
```

It detects `apt`, `dnf`, or `pacman` and maps the package name correctly (`lm-sensors` on apt/dnf, `lm_sensors` on Arch). If `sensors` is already present, it does nothing. If no supported manager exists, it prints manual instructions and exits `3`.

## CLI options

| Option | Description |
|---|---|
| `--help` | Show help and exit (`0`) |
| `--version` | Show version and exit (`0`) |
| `--json` | Machine-readable JSON output |
| `--no-color` | Disable color output |
| `--install` | Explicitly install optional `lm-sensors`, then run the report |
| `--interface NAME` | Show only the interface with this exact name (case-sensitive, no substring/prefix matching) |
| `--top N` | Number of processes in top lists, positive integer (default: `10`) |
| `--all-mounts` | Include all local mounts (default: only `/`) |

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Report generated (warnings do not change this) |
| `2` | Invalid arguments |
| `3` | Missing essential dependency, or `--install` cannot proceed |

Examples:

```bash
./monitor.sh --top 5
./monitor.sh --interface enp0s3
./monitor.sh --all-mounts
./monitor.sh --json --no-color
./monitor.sh --json --top 3 --interface wlp2s0
```

## Example output

Human (truncated, `--top 3`):

```
Operating System
================================================================================
Pop!_OS 22.04 LTS

CPU Usage
================================================================================
Usage         : 9.1%

Load Average
================================================================================
Load Averages: 1.68, 1.55, 1.69

Memory Usage
================================================================================
Total Memory    : 31437.7    MB
Used Memory     : 17845.9    MB (56.8%)
Available       : 13591.8    MB

Disk Usage
================================================================================
[/]
  Size          : 459796.26 MB
  Used          : 125453.86 MB (29%)
  Available     : 310914.25 MB
  Inodes        : total=29974528, used=1881817, free=28092711, usage=7%

Top 3 Processes by CPU
================================================================================
USER         PID     %CPU   %MEM   COMMAND
hiyan        260115  46.5   2.7    opencode
...

Network Usage
================================================================================
[enp4s0]
  Received     : 1438.41 MB
  Transmitted  : 99.81 MB
[wlp5s0]
  Received     : 3092.92 MB
  Transmitted  : 134.11 MB

Temperatures
================================================================================
Tctl               +57.6°C
Composite          +33.9°C
```

JSON (truncated, `--json --top 2`):

```json
{
  "schema_version": 1,
  "system": {
    "os_name": "Pop!_OS",
    "os_version": "22.04 LTS",
    "kernel": "7.1.1-76070101-generic",
    "arch": "x86_64",
    "datetime": "2026-09-13 18:28:53",
    "boot_time": "2026-09-12 23:45:42",
    "uptime_seconds": 67391
  },
  "cpu": {
    "usage_percent": 10.8,
    "load_1": 1.62,
    "load_5": 1.54,
    "load_15": 1.68,
    "logical_cpus": 12
  },
  "memory": {
    "total_mb": 31437.7,
    "used_mb": 17835.0,
    "available_mb": 13602.7,
    "used_percent": 56.7
  },
  "swap": {
    "total_mb": 53248.0,
    "used_mb": 1184.8,
    "free_mb": 52063.2
  },
  "disk": [
    {
      "mount": "/",
      "total_bytes": 482131324928,
      "used_bytes": 131547910144,
      "available_bytes": 326017220608,
      "used_percent": 29,
      "inodes_total": 29974528,
      "inodes_used": 1881817,
      "inodes_free": 28092711,
      "inodes_used_percent": 7
    }
  ],
  "network": [
    {"interface": "enp4s0", "rx_bytes": 1508278519, "tx_bytes": 104653351}
  ],
  "processes": {
    "top_cpu": [
      {"user": "hiyan", "pid": 260115, "cpu_percent": 46.6, "mem_percent": 2.7, "command": "opencode"}
    ],
    "top_mem": [],
    "zombies": 0
  },
  "temperatures": [
    {"label": "Tctl", "value": "+58.1°C"}
  ],
  "warnings": []
}
```

JSON contract:

- `schema_version` is currently `1`.
- Numbers stay numbers. Unavailable metrics are `null` (never strings like `"N/A"`).
- Strings are JSON-escaped (process commands included).
- `warnings` is always an array; optional gaps append entries without aborting.

## Metric definitions

- **Available memory**: `MemAvailable` from `/proc/meminfo`. This is the kernel estimate of memory available for new workloads without swapping (not just `MemFree`). On very old kernels without `MemAvailable`, syspeek falls back to `MemFree` and adds a warning. Used = Total − Available.
- **CPU usage**: computed from two `/proc/stat` `cpu` line reads ~0.5s apart: `1 − idle_delta/total_delta`, where idle = idle + iowait. This avoids `top` output format and locale issues.
- **Load average**: first three fields of `/proc/loadavg` (1, 5, 15 minutes).
- **Root disk usage**: `df -B1 -P /` in bytes; percent is the used ratio. `--all-mounts` adds other local filesystems (pseudo filesystems like `tmpfs`, `proc`, `sysfs`, `cgroup*`, `overlay`, `efivarfs`, and remote mounts are skipped).
- **Inodes**: `df -i -P <mount>`. Filesystems without inodes (e.g. FAT `/boot/efi`) report "not available" in human mode and `null` in JSON.
- **Network bytes**: cumulative receive/transmit byte counters from `/proc/net/dev` since interface creation/boot. Human mode shows MB (`bytes/1024/1024`, 2 decimals); JSON keeps raw `rx_bytes`/`tx_bytes`. These are totals, not per-second rates.
- **Processes**: `ps -eo user,pid,pcpu,pmem,args --sort=-%cpu|-%mem`, top `N`. Zombie count counts `ps -eo stat=` lines starting with `Z`.
- **Temperatures**: raw `sensors` lines matching `Core`, `Package`, `Tctl`, `Tdie`, `Composite`, `Sensor`, `tempN` (case-insensitive, dot or comma decimals). No normalization to Celsius numbers; JSON keeps `{label, value}` strings because `sensors` output varies by chip/driver.

## Compatibility

| Distribution | Manager | Temperature package | Notes |
|---|---|---|---|
| Debian/Ubuntu | `apt` | `lm-sensors` | Tested syntax; `--install` uses `apt update && apt install -y` |
| Fedora/RHEL | `dnf` | `lm-sensors` | `--install` uses `dnf install -y` |
| Arch | `pacman` | `lm_sensors` | Note underscore; `--install` uses `pacman -Sy --noconfirm` |

`ps --sort` requires `procps`/`procps-ng` (default on all three families). `df -B1 -P -T -l` assumes GNU coreutils.

## Troubleshooting

- **No temperatures / "sensors command not found"**: install `lm-sensors` (see above), then run `sudo sensors-detect` on bare metal. VMs and containers often expose no sensors; that is expected and only produces a warning.
- **"No valid temperature output"**: `sensors` ran but no recognized lines matched. Check raw `sensors` output; exotic labels may need extending the pattern in `collect_temps`.
- **Permission errors**: normal collection needs no root. If `df` or `ps` fail on hardened systems, those sections degrade with warnings.
- **Interface not found**: default lists all non-loopback interfaces (`enp0s3`, `wlp2s0`, `eth0`, `docker0`, ...). `--interface` is exact-match; `--interface enp` does not match `enp0s3`. Use `--interface lo` explicitly if you really want loopback.
- **No `/proc`**: minimal containers/chroots without `/proc` still exit `0`, but CPU/memory/swap/uptime/network become `null` with warnings. Mount `/proc` or accept degraded output.
- **Missing swap**: `SwapTotal: 0` is valid (reports zeros). Missing `SwapTotal`/`SwapFree` lines report `null` with a warning.

## Colors, non-interactive use, sensitive data

- Colors disable automatically when stdout is not a TTY, when `NO_COLOR` is set (any value), when `TERM=dumb`, or with `--no-color`. JSON output never contains ANSI codes.
- For logs and CI, prefer `./monitor.sh --json --no-color` or pipe stdout (non-TTY disables colors anyway).
- Process commands can contain usernames, paths, arguments, and occasionally secrets passed as CLI flags. Do not paste full reports into public tickets without reviewing `Top ... Processes` and JSON `processes.*.command`.

## Development and validation

```bash
bash -n monitor.sh
# shellcheck if available
shellcheck -S warning monitor.sh
./monitor.sh --help
./monitor.sh --json | python3 -m json.tool
./tests/test_monitor.sh
```

Test suite (`tests/test_monitor.sh`) uses fixtures and `PATH` mocks for `/proc`, `sensors`, `df`, `ps`, and package managers, so it does not depend only on the host it runs on. It checks help/version/exit codes, missing `sensors`/`tput`/swap/interfaces, non-TTY and `--no-color` ANSI absence, modern interface names and exact filtering, multiple mounts, sensor format/locale variants, JSON escaping/`null`/`warnings`, and that a default run never invokes a package manager.

Contributions: keep Linux + Bash scope, keep functions independent with graceful degradation, update `--help`, `README.md`, JSON schema notes, and tests together. Run the validation block above before opening a PR.

## License

MIT
