#!/usr/bin/env bash
#
# syspeek - point-in-time system health snapshot for Linux.
#
# Single-run diagnostic: CPU, memory, swap, disk, network, processes,
# temperatures. No root required for normal collection. No automatic
# package installation (see --install).

set -u
set -o pipefail

VERSION="1.0.0"
SCHEMA_VERSION=1

# Testability hooks (fixtures/mocks can override these).
PROC_ROOT="${SYSPEEK_PROCROOT:-/proc}"
OS_RELEASE_FILE="${SYSPEEK_OS_RELEASE:-/etc/os-release}"

OUTPUT_JSON=0
NO_COLOR_FLAG=0
DO_INSTALL=0
INTERFACE_FILTER=""
TOP_N=10
ALL_MOUNTS=0

WARNINGS=()

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

warn_add() {
    WARNINGS+=("$1")
}

usage() {
    cat <<'EOF'
Usage: monitor.sh [OPTIONS]

Point-in-time system health snapshot for Linux.

Options:
  --help              Show this help and exit
  --version           Show version and exit
  --json              Machine-readable JSON output
  --no-color          Disable color output
  --install           Explicitly install optional dependencies (lm-sensors)
  --interface NAME    Show only the network interface with this exact name
  --top N             Number of processes in top lists (default: 10)
  --all-mounts        Show all local mounts (default: only /)

Exit codes:
  0  Report generated (warnings do not change this)
  2  Invalid arguments
  3  Missing essential dependency

Examples:
  ./monitor.sh
  ./monitor.sh --json
  ./monitor.sh --interface enp0s3 --top 5
  ./monitor.sh --all-mounts
  ./monitor.sh --install
EOF
}

version_out() {
    printf 'syspeek %s\n' "$VERSION"
}

fail_args() {
    printf 'Error: %s\n' "$1" >&2
    printf 'Try: ./monitor.sh --help\n' >&2
    exit 2
}

fail_missing_dep() {
    printf 'Error: missing essential dependency: %s\n' "$1" >&2
    exit 3
}

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --help)
                usage
                exit 0
                ;;
            --version)
                version_out
                exit 0
                ;;
            --json)
                OUTPUT_JSON=1
                shift
                ;;
            --no-color)
                NO_COLOR_FLAG=1
                shift
                ;;
            --install)
                DO_INSTALL=1
                shift
                ;;
            --interface)
                [[ $# -ge 2 ]] || fail_args "--interface requires a value"
                [[ -n "$2" ]] || fail_args "--interface requires a non-empty value"
                INTERFACE_FILTER="$2"
                shift 2
                ;;
            --interface=*)
                INTERFACE_FILTER="${1#--interface=}"
                [[ -n "$INTERFACE_FILTER" ]] || fail_args "--interface requires a non-empty value"
                shift
                ;;
            --top)
                [[ $# -ge 2 ]] || fail_args "--top requires a value"
                if ! is_uint "$2" || [[ "$2" -le 0 ]]; then
                    fail_args "--top must be a positive integer (got: $2)"
                fi
                TOP_N="$2"
                shift 2
                ;;
            --top=*)
                local v="${1#--top=}"
                if ! is_uint "$v" || [[ "$v" -le 0 ]]; then
                    fail_args "--top must be a positive integer (got: $v)"
                fi
                TOP_N="$v"
                shift
                ;;
            --all-mounts)
                ALL_MOUNTS=1
                shift
                ;;
            --)
                shift
                [[ $# -eq 0 ]] || fail_args "unexpected argument: $1"
                break
                ;;
            --*)
                fail_args "unknown option: $1"
                ;;
            -*)
                fail_args "unknown option: $1"
                ;;
            *)
                fail_args "unexpected argument: $1"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# color (no tput dependency, honors NO_COLOR and non-TTY)
# ---------------------------------------------------------------------------

C_GREEN=""
C_YELLOW=""
C_CYAN=""
C_BOLD=""
C_RESET=""

setup_colors() {
    if ((NO_COLOR_FLAG == 1)); then
        return 0
    fi
    if [[ -n "${NO_COLOR:-}" ]]; then
        return 0
    fi
    if [[ "${TERM:-}" == "dumb" ]]; then
        return 0
    fi
    if [[ ! -t 1 ]] && ((OUTPUT_JSON == 0)); then
        # Non-interactive stdout: no colors. (JSON never uses colors anyway.)
        return 0
    fi
    if ((OUTPUT_JSON == 1)); then
        return 0
    fi
    # ANSI escape sequences must be interpreted here. Plain single-quoted
    # values would print the literal text "\\033" in the terminal.
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[1;36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
}

# ---------------------------------------------------------------------------
# essential deps (never installs anything implicitly)
# ---------------------------------------------------------------------------

check_essential_deps() {
    local cmd
    for cmd in awk ps df grep sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fail_missing_dep "$cmd"
        fi
    done
}

# ---------------------------------------------------------------------------
# --install (explicit only)
# ---------------------------------------------------------------------------

run_install() {
    if command -v sensors >/dev/null 2>&1; then
        printf 'Optional dependencies already present (sensors found).\n'
        return 0
    fi

    local -a priv=( )
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            priv=(sudo)
        else
            printf 'Error: root privileges required to install lm-sensors (sudo not found).\n' >&2
            return 3
        fi
    fi

    if command -v apt >/dev/null 2>&1; then
        "${priv[@]}" apt update && "${priv[@]}" apt install -y lm-sensors
        return $?
    elif command -v dnf >/dev/null 2>&1; then
        "${priv[@]}" dnf install -y lm-sensors
        return $?
    elif command -v pacman >/dev/null 2>&1; then
        "${priv[@]}" pacman -Sy --noconfirm lm_sensors
        return $?
    else
        printf 'Error: unsupported package manager. Install lm-sensors manually.\n' >&2
        printf '  Debian/Ubuntu: sudo apt install lm-sensors\n' >&2
        printf '  Fedora/RHEL:   sudo dnf install lm-sensors\n' >&2
        printf '  Arch:          sudo pacman -S lm_sensors\n' >&2
        return 3
    fi
}

# ---------------------------------------------------------------------------
# collected data (globals; empty string means unavailable -> null in JSON)
# ---------------------------------------------------------------------------

OS_NAME=""
OS_VERSION_STR=""
KERNEL=""
ARCH=""
DATETIME=""
BOOT_TIME=""
UPTIME_SECONDS=""

CPU_USAGE=""
LOAD1=""
LOAD5=""
LOAD15=""
LOGICAL_CPUS=""

MEM_TOTAL_MB=""
MEM_USED_MB=""
MEM_AVAIL_MB=""
MEM_USED_PCT=""

SWAP_TOTAL_MB=""
SWAP_USED_MB=""
SWAP_FREE_MB=""

# disk arrays
DISK_MOUNT=()
DISK_TOTAL_B=()
DISK_USED_B=()
DISK_AVAIL_B=()
DISK_USED_PCT=()
DISK_ITOTAL=()
DISK_IUSED=()
DISK_IFREE=()
DISK_IUSE_PCT=()

# network arrays
NET_IFACE=()
NET_RX_B=()
NET_TX_B=()

# processes: each entry "user|pid|cpu|mem|command"
TOP_CPU_ENTRIES=()
TOP_MEM_ENTRIES=()
ZOMBIES=""

# temperatures: each entry "label|value"
TEMP_ENTRIES=()

# ---------------------------------------------------------------------------
# collectors (each degrades gracefully, never aborts the report)
# ---------------------------------------------------------------------------

collect_system() {
    if [[ -f "$OS_RELEASE_FILE" ]]; then
        # shellcheck disable=SC1090
        OS_NAME=$(awk -F= '/^NAME=/{gsub(/"/,"",$2); print $2}' "$OS_RELEASE_FILE" 2>/dev/null || true)
        OS_VERSION_STR=$(awk -F= '/^VERSION=/{gsub(/"/,"",$2); print $2}' "$OS_RELEASE_FILE" 2>/dev/null || true)
        if [[ -z "$OS_NAME" ]]; then
            OS_NAME=$(uname -s 2>/dev/null || true)
        fi
    else
        OS_NAME=$(uname -s 2>/dev/null || true)
        if [[ -z "$OS_NAME" ]]; then
            warn_add "OS information not available ($OS_RELEASE_FILE missing and uname failed)"
        else
            warn_add "OS release file not available ($OS_RELEASE_FILE missing)"
        fi
    fi

    KERNEL=$(uname -r 2>/dev/null || true)
    [[ -n "$KERNEL" ]] || warn_add "Kernel version not available (uname failed)"

    ARCH=$(uname -m 2>/dev/null || true)
    [[ -n "$ARCH" ]] || warn_add "Architecture not available (uname failed)"

    DATETIME=$(date +'%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
    [[ -n "$DATETIME" ]] || warn_add "System date not available (date failed)"

    if [[ -f "$PROC_ROOT/stat" ]]; then
        BOOT_TIME=$(awk '/^btime /{ print strftime("%Y-%m-%d %H:%M:%S", $2) }' "$PROC_ROOT/stat" 2>/dev/null || true)
        [[ -n "$BOOT_TIME" ]] || warn_add "Boot time not available (btime missing in $PROC_ROOT/stat)"
    else
        warn_add "Boot time not available ($PROC_ROOT/stat missing)"
    fi

    if [[ -f "$PROC_ROOT/uptime" ]]; then
        UPTIME_SECONDS=$(awk '{ printf "%d", $1 }' "$PROC_ROOT/uptime" 2>/dev/null || true)
        [[ -n "$UPTIME_SECONDS" ]] || warn_add "Uptime not available (cannot parse $PROC_ROOT/uptime)"
    else
        warn_add "Uptime not available ($PROC_ROOT/uptime missing)"
    fi
}

cpu_snapshot() {
    awk '/^cpu /{ print $2, $3, $4, $5, $6, $7, $8, $9 }' "$PROC_ROOT/stat" 2>/dev/null || true
}

collect_cpu() {
    local snap1 snap2
    snap1=$(cpu_snapshot)
    if [[ -z "$snap1" ]]; then
        warn_add "CPU usage not available (cannot read cpu line from $PROC_ROOT/stat)"
    else
        sleep 0.5
        snap2=$(cpu_snapshot)
        if [[ -z "$snap2" ]]; then
            warn_add "CPU usage not available (second $PROC_ROOT/stat read failed)"
        else
            CPU_USAGE=$(awk -v a="$snap1" -v b="$snap2" 'BEGIN {
                n1 = split(a, x, " "); n2 = split(b, y, " ");
                if (n1 < 8 || n2 < 8) exit 1;
                t1 = x[1]+x[2]+x[3]+x[4]+x[5]+x[6]+x[7]+x[8];
                t2 = y[1]+y[2]+y[3]+y[4]+y[5]+y[6]+y[7]+y[8];
                i1 = x[4]+x[5]; i2 = y[4]+y[5];
                dt = t2-t1; di = i2-i1;
                if (dt <= 0) exit 1;
                printf "%.1f", (1 - di/dt) * 100;
            }' 2>/dev/null || true)
            if [[ -z "$CPU_USAGE" ]]; then
                warn_add "CPU usage not available (cannot compute delta from $PROC_ROOT/stat)"
            fi
        fi
    fi

    if [[ -f "$PROC_ROOT/loadavg" ]]; then
        local l1="" l5="" l15=""
        read -r l1 l5 l15 _ <"$PROC_ROOT/loadavg" 2>/dev/null || true
        if [[ -n "$l1" && -n "$l5" && -n "$l15" ]]; then
            LOAD1="$l1"; LOAD5="$l5"; LOAD15="$l15"
        else
            warn_add "Load average not available (cannot parse $PROC_ROOT/loadavg)"
        fi
    else
        warn_add "Load average not available ($PROC_ROOT/loadavg missing)"
    fi

    if command -v nproc >/dev/null 2>&1; then
        LOGICAL_CPUS=$(nproc 2>/dev/null || true)
    elif [[ -f "$PROC_ROOT/cpuinfo" ]]; then
        LOGICAL_CPUS=$(grep -c '^processor' "$PROC_ROOT/cpuinfo" 2>/dev/null || true)
        [[ "$LOGICAL_CPUS" == "0" ]] && LOGICAL_CPUS=""
    else
        LOGICAL_CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    fi
    if [[ -z "$LOGICAL_CPUS" ]]; then
        warn_add "Logical CPU count not available (nproc/cpuinfo/getconf failed)"
    fi
}

collect_memory() {
    local meminfo="$PROC_ROOT/meminfo"
    if [[ ! -f "$meminfo" ]]; then
        warn_add "Memory metrics not available ($meminfo missing)"
        return 0
    fi
    local total_kb="" avail_kb="" free_kb=""
    total_kb=$(awk '/^MemTotal:/{print $2}' "$meminfo" 2>/dev/null || true)
    avail_kb=$(awk '/^MemAvailable:/{print $2}' "$meminfo" 2>/dev/null || true)
    if [[ -z "$avail_kb" ]]; then
        free_kb=$(awk '/^MemFree:/{print $2}' "$meminfo" 2>/dev/null || true)
        if [[ -n "$free_kb" ]]; then
            avail_kb="$free_kb"
            warn_add "MemAvailable missing; fell back to MemFree (values may differ)"
        fi
    fi
    if [[ -z "$total_kb" || -z "$avail_kb" ]]; then
        warn_add "Memory metrics not available (cannot parse $meminfo)"
        return 0
    fi
    MEM_TOTAL_MB=$(awk -v t="$total_kb" 'BEGIN{ printf "%.1f", t/1024 }')
    MEM_AVAIL_MB=$(awk -v a="$avail_kb" 'BEGIN{ printf "%.1f", a/1024 }')
    MEM_USED_MB=$(awk -v t="$total_kb" -v a="$avail_kb" 'BEGIN{ printf "%.1f", (t-a)/1024 }')
    MEM_USED_PCT=$(awk -v t="$total_kb" -v a="$avail_kb" 'BEGIN{ if (t>0) printf "%.1f", ((t-a)/t)*100 }')
}

collect_swap() {
    local meminfo="$PROC_ROOT/meminfo"
    if [[ ! -f "$meminfo" ]]; then
        warn_add "Swap metrics not available ($meminfo missing)"
        return 0
    fi
    local stotal="" sfree=""
    stotal=$(awk '/^SwapTotal:/{print $2}' "$meminfo" 2>/dev/null || true)
    sfree=$(awk '/^SwapFree:/{print $2}' "$meminfo" 2>/dev/null || true)
    if [[ -z "$stotal" || -z "$sfree" ]]; then
        warn_add "Swap metrics not available (cannot parse SwapTotal/SwapFree)"
        return 0
    fi
    SWAP_TOTAL_MB=$(awk -v t="$stotal" 'BEGIN{ printf "%.1f", t/1024 }')
    SWAP_FREE_MB=$(awk -v f="$sfree" 'BEGIN{ printf "%.1f", f/1024 }')
    SWAP_USED_MB=$(awk -v t="$stotal" -v f="$sfree" 'BEGIN{ printf "%.1f", (t-f)/1024 }')
}

collect_one_disk() {
    local mount="$1"
    local df_out df_inode total used avail pct itotal iused ifree iuse
    if ! df_out=$(df -B1 -P "$mount" 2>/dev/null); then
        warn_add "Disk metrics not available for $mount (df failed)"
        return 1
    fi
    # NR==2: $2 total $3 used $4 avail $5 use%
    read -r total used avail pct <<<"$(printf '%s\n' "$df_out" | awk 'NR==2{print $2, $3, $4, $5}')"
    if [[ -z "$total" ]]; then
        warn_add "Disk metrics not available for $mount (cannot parse df output)"
        return 1
    fi
    pct=${pct%\%}
    if ! df_inode=$(df -i -P "$mount" 2>/dev/null); then
        warn_add "Inode metrics not available for $mount (df -i failed)"
        itotal=""; iused=""; ifree=""; iuse=""
    else
        read -r itotal iused ifree iuse <<<"$(printf '%s\n' "$df_inode" | awk 'NR==2{print $2, $3, $4, $5}')"
        iuse=${iuse%\%}
        iuse=${iuse#-}
        [[ "$iuse" == "" ]] && iuse=""
    fi
    DISK_MOUNT+=("$mount")
    DISK_TOTAL_B+=("$total")
    DISK_USED_B+=("$used")
    DISK_AVAIL_B+=("$avail")
    DISK_USED_PCT+=("$pct")
    DISK_ITOTAL+=("${itotal:-}")
    DISK_IUSED+=("${iused:-}")
    DISK_IFREE+=("${ifree:-}")
    DISK_IUSE_PCT+=("${iuse:-}")
    return 0
}

collect_disk() {
    local mounts=()
    if ((ALL_MOUNTS == 1)); then
        local df_all
        if df_all=$(df -B1 -PT -l 2>/dev/null); then
            # Filesystem Type ... Mounted on (mount = field 7 onwards)
            while IFS= read -r line; do
                [[ "$line" == Filesystem* ]] && continue
                local fstype mountpoint
                fstype=$(printf '%s' "$line" | awk '{print $2}')
                mountpoint=$(printf '%s' "$line" | awk '{for (i=7;i<=NF;i++){printf "%s%s", $i, (i<NF?" ":"")}; print ""}')
                case "$fstype" in
                    tmpfs|devtmpfs|devpts|sysfs|proc|cgroup|cgroup2|pstore|bpf|tracefs|configfs|fusectl|mqueue|shm|overlay|squashfs|iso9660|autofs|nsfs|debugfs|securityfs|hugetlbfs|efivarfs|fuse.*|cifs|nfs|nfs4|smbfs) continue ;;
                esac
                [[ -z "$mountpoint" ]] && continue
                mounts+=("$mountpoint")
            done <<<"$df_all"
        else
            warn_add "Cannot list local filesystems (df -PT -l failed); falling back to /"
        fi
        # Always include / first, deduplicated.
        local merged=("/") m seen_root=0
        for m in "${mounts[@]}"; do
            [[ "$m" == "/" ]] && { seen_root=1; continue; }
            merged+=("$m")
        done
        if ((${#merged[@]} == 1)) && ((seen_root == 1 || ${#mounts[@]} == 0)); then
            mounts=("/")
        else
            mounts=("${merged[@]}")
        fi
        if ((${#mounts[@]} == 0)); then
            mounts=("/")
        fi
    else
        mounts=("/")
    fi

    local m ok=0
    for m in "${mounts[@]}"; do
        if collect_one_disk "$m"; then
            ok=1
        fi
    done
    if ((ok == 0)); then
        warn_add "No disk metrics collected"
    fi
}

collect_processes() {
    local ps_out
    if ps_out=$(ps -eo user:32,pid,pcpu,pmem,args --sort=-%cpu 2>/dev/null); then
        local count=0
        while IFS= read -r line; do
            ((count++))
            ((count == 1)) && continue  # header
            ((count > TOP_N + 1)) && break
            local user pid cpu mem cmd
            user=$(printf '%s' "$line" | awk '{print $1}')
            pid=$(printf '%s' "$line" | awk '{print $2}')
            cpu=$(printf '%s' "$line" | awk '{print $3}')
            mem=$(printf '%s' "$line" | awk '{print $4}')
            cmd=$(printf '%s' "$line" | awk '{for (i=5;i<=NF;i++){printf "%s%s",$i,(i<NF?" ":"")}; print ""}')
            [[ -z "$user$pid" ]] && continue
            TOP_CPU_ENTRIES+=("$user|$pid|$cpu|$mem|$cmd")
        done <<<"$ps_out"
        ((${#TOP_CPU_ENTRIES[@]} > 0)) || warn_add "Top-CPU process list is empty"
    else
        warn_add "Process list (CPU) not available (ps failed)"
    fi

    if ps_out=$(ps -eo user:32,pid,pcpu,pmem,args --sort=-%mem 2>/dev/null); then
        local count=0
        while IFS= read -r line; do
            ((count++))
            ((count == 1)) && continue
            ((count > TOP_N + 1)) && break
            local user pid cpu mem cmd
            user=$(printf '%s' "$line" | awk '{print $1}')
            pid=$(printf '%s' "$line" | awk '{print $2}')
            cpu=$(printf '%s' "$line" | awk '{print $3}')
            mem=$(printf '%s' "$line" | awk '{print $4}')
            cmd=$(printf '%s' "$line" | awk '{for (i=5;i<=NF;i++){printf "%s%s",$i,(i<NF?" ":"")}; print ""}')
            [[ -z "$user$pid" ]] && continue
            TOP_MEM_ENTRIES+=("$user|$pid|$cpu|$mem|$cmd")
        done <<<"$ps_out"
        ((${#TOP_MEM_ENTRIES[@]} > 0)) || warn_add "Top-memory process list is empty"
    else
        warn_add "Process list (memory) not available (ps failed)"
    fi

    local z
    if z=$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^Z/{c++} END{print c+0}'); then
        ZOMBIES="$z"
    else
        warn_add "Zombie count not available (ps failed)"
    fi
}

collect_network() {
    local netdev="$PROC_ROOT/net/dev"
    if [[ ! -f "$netdev" ]]; then
        warn_add "Network metrics not available ($netdev missing)"
        return 0
    fi
    while IFS='|' read -r iface rx tx; do
        [[ -z "$iface" ]] && continue
        if [[ -n "$INTERFACE_FILTER" ]]; then
            [[ "$iface" == "$INTERFACE_FILTER" ]] || continue
        else
            [[ "$iface" == "lo" ]] && continue
        fi
        NET_IFACE+=("$iface")
        NET_RX_B+=("$rx")
        NET_TX_B+=("$tx")
    done < <(awk -F: 'NR>2{
        iface=$1; gsub(/^[ \t]+|[ \t]+$/, "", iface);
        n=split($2, a, " ");
        # a[1] is "" when leading spaces; find first two numeric groups robustly:
        # receive bytes = first field, transmit bytes = 9th field of $2
        print iface "|" a[1] "|" a[9];
    }' "$netdev" 2>/dev/null)

    if [[ -n "$INTERFACE_FILTER" ]] && ((${#NET_IFACE[@]} == 0)); then
        warn_add "Network interface '$INTERFACE_FILTER' not found"
    elif ((${#NET_IFACE[@]} == 0)); then
        warn_add "No non-loopback network interfaces found"
    fi
}

collect_temps() {
    if ! command -v sensors >/dev/null 2>&1; then
        warn_add "Temperature metrics not available (sensors command not found; install lm-sensors)"
        return 0
    fi
    local out
    out=$(sensors 2>/dev/null || true)
    if [[ -z "$out" ]]; then
        warn_add "Temperature metrics not available (sensors produced no output)"
        return 0
    fi
    local matched
    matched=$(printf '%s\n' "$out" | grep -iE '^[[:space:]]*(core|package|tctl|t[ _-]?die|composite|sensor|temp)[^:]*:[[:space:]]*\+?[0-9]+([.,][0-9]+)?' || true)
    if [[ -z "$matched" ]]; then
        warn_add "No valid temperature output (no recognized sensor lines)"
        return 0
    fi
    while IFS= read -r line; do
        local label value rest
        label=$(printf '%s' "$line" | cut -d: -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        rest=$(printf '%s' "$line" | cut -d: -f2-)
        value=$(printf '%s' "$rest" | grep -oE '\+[0-9]+([.,][0-9]+)?°C|\+?[0-9]+([.,][0-9]+)? ?°C|[0-9]+([.,][0-9]+)?°C' | head -n1 || true)
        if [[ -z "$value" ]]; then
            value=$(printf '%s' "$rest" | awk '{print $1}')
        fi
        [[ -z "$label" ]] && label="sensor"
        [[ -z "$value" ]] && value="unknown"
        TEMP_ENTRIES+=("$label|$value")
    done <<<"$matched"
}

collect_all() {
    collect_system
    collect_cpu
    collect_memory
    collect_swap
    collect_disk
    collect_processes
    collect_network
    collect_temps
}

# ---------------------------------------------------------------------------
# human output
# ---------------------------------------------------------------------------

separator="================================================================================"

print_header() {
    printf '\n%s%s%s%s\n' "$C_CYAN" "$C_BOLD" "$1" "$C_RESET"
    printf '%s\n' "$separator"
}

fmt_uptime() {
    local total="${UPTIME_SECONDS:-}"
    if [[ -z "$total" ]]; then
        printf '%sN/A (uptime unavailable)%s\n' "$C_YELLOW" "$C_RESET"
        return 0
    fi
    local days hours minutes seconds
    days=$((total / 86400))
    hours=$(((total % 86400) / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))
    local parts=()
    ((days > 0)) && parts+=("$days days")
    ((hours > 0)) && parts+=("$hours hours")
    ((minutes > 0)) && parts+=("$minutes minutes")
    if ((seconds > 0 || ${#parts[@]} == 0)); then
        parts+=("$seconds seconds")
    fi
    printf '%s%s%s\n' "$C_GREEN" "$(IFS=', '; echo "${parts[*]}")" "$C_RESET"
}

mb_to_human() {
    awk -v v="$1" 'BEGIN{ printf "%.1f", v }'
}

bytes_to_mb() {
    awk -v b="$1" 'BEGIN{ printf "%.2f", b/1024/1024 }'
}

render_human() {
    print_header "Operating System"
    if [[ -n "$OS_NAME" ]]; then
        if [[ -n "$OS_VERSION_STR" ]]; then
            printf '%s%s %s%s\n' "$C_GREEN" "$OS_NAME" "$OS_VERSION_STR" "$C_RESET"
        else
            printf '%s%s%s\n' "$C_GREEN" "$OS_NAME" "$C_RESET"
        fi
    else
        printf '%sN/A%s\n' "$C_YELLOW" "$C_RESET"
    fi

    print_header "Kernel Version"
    if [[ -n "$KERNEL" ]]; then printf '%s%s%s\n' "$C_GREEN" "$KERNEL" "$C_RESET"; else printf '%sN/A%s\n' "$C_YELLOW" "$C_RESET"; fi

    print_header "Architecture"
    if [[ -n "$ARCH" ]]; then printf '%s%s%s\n' "$C_GREEN" "$ARCH" "$C_RESET"; else printf '%sN/A%s\n' "$C_YELLOW" "$C_RESET"; fi

    print_header "System Date and Time"
    if [[ -n "$DATETIME" ]]; then printf '%s%s%s\n' "$C_GREEN" "$DATETIME" "$C_RESET"; else printf '%sN/A%s\n' "$C_YELLOW" "$C_RESET"; fi

    print_header "System Boot Time"
    if [[ -n "$BOOT_TIME" ]]; then printf '%s%s%s\n' "$C_GREEN" "$BOOT_TIME" "$C_RESET"; else printf '%sBoot time information not available.%s\n' "$C_YELLOW" "$C_RESET"; fi

    print_header "CPU Uptime"
    fmt_uptime

    print_header "CPU Usage"
    if [[ -n "$CPU_USAGE" ]]; then
        printf 'Usage         : %s%s%%%s\n' "$C_GREEN" "$CPU_USAGE" "$C_RESET"
    else
        printf '%sCPU usage not available.%s\n' "$C_YELLOW" "$C_RESET"
    fi

    print_header "Load Average"
    if [[ -n "$LOAD1" ]]; then
        printf 'Load Averages: %s%s, %s, %s%s\n' "$C_GREEN" "$LOAD1" "$LOAD5" "$LOAD15" "$C_RESET"
    else
        printf '%sLoad average not available.%s\n' "$C_YELLOW" "$C_RESET"
    fi

    print_header "Logical CPUs"
    if [[ -n "$LOGICAL_CPUS" ]]; then printf '%s%s%s\n' "$C_GREEN" "$LOGICAL_CPUS" "$C_RESET"; else printf '%sN/A%s\n' "$C_YELLOW" "$C_RESET"; fi

    print_header "Memory Usage"
    if [[ -n "$MEM_TOTAL_MB" ]]; then
        printf 'Total Memory    : %s%-10s MB%s\n' "$C_YELLOW" "$MEM_TOTAL_MB" "$C_RESET"
        printf 'Used Memory     : %s%-10s MB%s (%s%%)\n' "$C_YELLOW" "$MEM_USED_MB" "$C_RESET" "${MEM_USED_PCT:-?}"
        printf 'Available       : %s%-10s MB%s\n' "$C_YELLOW" "$MEM_AVAIL_MB" "$C_RESET"
    else
        printf '%sMemory metrics not available.%s\n' "$C_YELLOW" "$C_RESET"
    fi

    print_header "Swap Usage"
    if [[ -n "$SWAP_TOTAL_MB" ]]; then
        printf 'Total Swap     : %s%s MB%s\n' "$C_GREEN" "$SWAP_TOTAL_MB" "$C_RESET"
        printf 'Used Swap      : %s%s MB%s\n' "$C_YELLOW" "$SWAP_USED_MB" "$C_RESET"
        printf 'Free Swap      : %s%s MB%s\n' "$C_GREEN" "$SWAP_FREE_MB" "$C_RESET"
    else
        printf '%sSwap metrics not available.%s\n' "$C_YELLOW" "$C_RESET"
    fi

    print_header "Disk Usage"
    if ((${#DISK_MOUNT[@]} == 0)); then
        printf '%sDisk metrics not available.%s\n' "$C_YELLOW" "$C_RESET"
    else
        local i
        for i in "${!DISK_MOUNT[@]}"; do
            local total_mb used_mb avail_mb
            total_mb=$(bytes_to_mb "${DISK_TOTAL_B[$i]}")
            used_mb=$(bytes_to_mb "${DISK_USED_B[$i]}")
            avail_mb=$(bytes_to_mb "${DISK_AVAIL_B[$i]}")
            printf '[%s]\n' "${DISK_MOUNT[$i]}"
            printf '  Size          : %s%s MB%s\n' "$C_YELLOW" "$total_mb" "$C_RESET"
            if [[ -n "${DISK_USED_PCT[$i]:-}" ]]; then
                printf '  Used          : %s%s MB%s (%s%%)\n' "$C_YELLOW" "$used_mb" "$C_RESET" "${DISK_USED_PCT[$i]}"
            else
                printf '  Used          : %s%s MB%s (N/A)\n' "$C_YELLOW" "$used_mb" "$C_RESET"
            fi
            printf '  Available     : %s%s MB%s\n' "$C_YELLOW" "$avail_mb" "$C_RESET"
            if [[ -n "${DISK_ITOTAL[$i]:-}" && "${DISK_ITOTAL[$i]}" != "0" ]]; then
                local iuse_disp="N/A"
                [[ -n "${DISK_IUSE_PCT[$i]:-}" ]] && iuse_disp="${DISK_IUSE_PCT[$i]}%"
                printf '  Inodes        : total=%s, used=%s, free=%s, usage=%s\n' \
                    "${DISK_ITOTAL[$i]}" "${DISK_IUSED[$i]}" "${DISK_IFREE[$i]}" "$iuse_disp"
            else
                printf '  Inodes        : %snot available%s\n' "$C_YELLOW" "$C_RESET"
            fi
        done
    fi

    print_header "Top $TOP_N Processes by CPU"
    if ((${#TOP_CPU_ENTRIES[@]} == 0)); then
        printf '%sProcess list not available.%s\n' "$C_YELLOW" "$C_RESET"
    else
        printf '%-12s %-7s %-6s %-6s %s\n' "USER" "PID" "%CPU" "%MEM" "COMMAND"
        local e user pid cpu mem cmd
        for e in "${TOP_CPU_ENTRIES[@]}"; do
            IFS='|' read -r user pid cpu mem cmd <<<"$e"
            printf '%-12s %-7s %-6s %-6s %s\n' "$user" "$pid" "$cpu" "$mem" "${cmd:0:120}"
        done
    fi

    print_header "Top $TOP_N Processes by Memory"
    if ((${#TOP_MEM_ENTRIES[@]} == 0)); then
        printf '%sProcess list not available.%s\n' "$C_YELLOW" "$C_RESET"
    else
        printf '%-12s %-7s %-6s %-6s %s\n' "USER" "PID" "%CPU" "%MEM" "COMMAND"
        local e user pid cpu mem cmd
        for e in "${TOP_MEM_ENTRIES[@]}"; do
            IFS='|' read -r user pid cpu mem cmd <<<"$e"
            printf '%-12s %-7s %-6s %-6s %s\n' "$user" "$pid" "$cpu" "$mem" "${cmd:0:120}"
        done
    fi

    print_header "Zombie Processes"
    if [[ -n "$ZOMBIES" ]]; then
        local color="$C_GREEN"
        ((ZOMBIES > 0)) && color="$C_YELLOW"
        printf 'Total zombie processes: %s%s%s\n' "$color" "$ZOMBIES" "$C_RESET"
    else
        printf '%sZombie count not available.%s\n' "$C_YELLOW" "$C_RESET"
    fi

    if [[ -n "$INTERFACE_FILTER" ]]; then
        print_header "Network Usage ($INTERFACE_FILTER)"
    else
        print_header "Network Usage"
    fi
    if ((${#NET_IFACE[@]} == 0)); then
        printf '%sNo network data (interface missing or /proc unavailable).%s\n' "$C_YELLOW" "$C_RESET"
    else
        local i rx_mb tx_mb
        for i in "${!NET_IFACE[@]}"; do
            rx_mb=$(bytes_to_mb "${NET_RX_B[$i]}")
            tx_mb=$(bytes_to_mb "${NET_TX_B[$i]}")
            printf '[%s]\n' "${NET_IFACE[$i]}"
            printf '  Received     : %s%s MB%s\n' "$C_GREEN" "$rx_mb" "$C_RESET"
            printf '  Transmitted  : %s%s MB%s\n' "$C_YELLOW" "$tx_mb" "$C_RESET"
        done
    fi

    print_header "Temperatures"
    if ((${#TEMP_ENTRIES[@]} == 0)); then
        printf '%sNo valid temperature output.%s\n' "$C_YELLOW" "$C_RESET"
    else
        local e label value
        for e in "${TEMP_ENTRIES[@]}"; do
            IFS='|' read -r label value <<<"$e"
            printf '%s%-18s%s %s\n' "$C_CYAN" "$label" "$C_RESET" "$value"
        done
    fi

    if ((${#WARNINGS[@]} > 0)); then
        print_header "Warnings"
        local w
        for w in "${WARNINGS[@]}"; do
            printf '%s- %s%s\n' "$C_YELLOW" "$w" "$C_RESET"
        done
    fi
}

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

json_str_or_null() {
    if [[ -z "$1" ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi
}

json_num_or_null() {
    local v="$1"
    if [[ -z "$v" ]]; then
        printf 'null'
    elif [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$v"
    else
        printf '"%s"' "$(json_escape "$v")"
    fi
}

json_int_or_null() {
    local v="$1"
    if [[ -z "$v" ]]; then
        printf 'null'
    elif [[ "$v" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$v"
    elif [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$(awk -v x="$v" 'BEGIN{printf "%d", x}')"
    else
        printf 'null'
    fi
}

render_json() {
    printf '{\n'
    printf '  "schema_version": %s,\n' "$SCHEMA_VERSION"

    printf '  "system": {\n'
    printf '    "os_name": %s,\n' "$(json_str_or_null "$OS_NAME")"
    printf '    "os_version": %s,\n' "$(json_str_or_null "$OS_VERSION_STR")"
    printf '    "kernel": %s,\n' "$(json_str_or_null "$KERNEL")"
    printf '    "arch": %s,\n' "$(json_str_or_null "$ARCH")"
    printf '    "datetime": %s,\n' "$(json_str_or_null "$DATETIME")"
    printf '    "boot_time": %s,\n' "$(json_str_or_null "$BOOT_TIME")"
    printf '    "uptime_seconds": %s\n' "$(json_int_or_null "$UPTIME_SECONDS")"
    printf '  },\n'

    printf '  "cpu": {\n'
    printf '    "usage_percent": %s,\n' "$(json_num_or_null "$CPU_USAGE")"
    printf '    "load_1": %s,\n' "$(json_num_or_null "$LOAD1")"
    printf '    "load_5": %s,\n' "$(json_num_or_null "$LOAD5")"
    printf '    "load_15": %s,\n' "$(json_num_or_null "$LOAD15")"
    printf '    "logical_cpus": %s\n' "$(json_int_or_null "$LOGICAL_CPUS")"
    printf '  },\n'

    printf '  "memory": {\n'
    printf '    "total_mb": %s,\n' "$(json_num_or_null "$MEM_TOTAL_MB")"
    printf '    "used_mb": %s,\n' "$(json_num_or_null "$MEM_USED_MB")"
    printf '    "available_mb": %s,\n' "$(json_num_or_null "$MEM_AVAIL_MB")"
    printf '    "used_percent": %s\n' "$(json_num_or_null "$MEM_USED_PCT")"
    printf '  },\n'

    printf '  "swap": {\n'
    printf '    "total_mb": %s,\n' "$(json_num_or_null "$SWAP_TOTAL_MB")"
    printf '    "used_mb": %s,\n' "$(json_num_or_null "$SWAP_USED_MB")"
    printf '    "free_mb": %s\n' "$(json_num_or_null "$SWAP_FREE_MB")"
    printf '  },\n'

    printf '  "disk": [\n'
    local i
    for i in "${!DISK_MOUNT[@]}"; do
        printf '    {\n'
        printf '      "mount": "%s",\n' "$(json_escape "${DISK_MOUNT[$i]}")"
        printf '      "total_bytes": %s,\n' "$(json_int_or_null "${DISK_TOTAL_B[$i]}")"
        printf '      "used_bytes": %s,\n' "$(json_int_or_null "${DISK_USED_B[$i]}")"
        printf '      "available_bytes": %s,\n' "$(json_int_or_null "${DISK_AVAIL_B[$i]}")"
        printf '      "used_percent": %s,\n' "$(json_num_or_null "${DISK_USED_PCT[$i]}")"
        printf '      "inodes_total": %s,\n' "$(json_int_or_null "${DISK_ITOTAL[$i]:-}")"
        printf '      "inodes_used": %s,\n' "$(json_int_or_null "${DISK_IUSED[$i]:-}")"
        printf '      "inodes_free": %s,\n' "$(json_int_or_null "${DISK_IFREE[$i]:-}")"
        printf '      "inodes_used_percent": %s\n' "$(json_num_or_null "${DISK_IUSE_PCT[$i]:-}")"
        if ((i < ${#DISK_MOUNT[@]} - 1)); then printf '    },\n'; else printf '    }\n'; fi
    done
    printf '  ],\n'

    printf '  "network": [\n'
    for i in "${!NET_IFACE[@]}"; do
        printf '    {"interface": "%s", "rx_bytes": %s, "tx_bytes": %s}' \
            "$(json_escape "${NET_IFACE[$i]}")" \
            "$(json_int_or_null "${NET_RX_B[$i]}")" \
            "$(json_int_or_null "${NET_TX_B[$i]}")"
        if ((i < ${#NET_IFACE[@]} - 1)); then printf ',\n'; else printf '\n'; fi
    done
    printf '  ],\n'

    render_json_processes
    render_json_temps

    printf '  "warnings": ['
    local w first=1
    for w in "${WARNINGS[@]}"; do
        if ((first == 1)); then first=0; else printf ', '; fi
        printf '"%s"' "$(json_escape "$w")"
    done
    printf ']\n'
    printf '}\n'
}

render_json_processes() {
    printf '  "processes": {\n'
    printf '    "top_cpu": [\n'
    local idx e user pid cpu mem cmd
    idx=0
    for e in "${TOP_CPU_ENTRIES[@]}"; do
        IFS='|' read -r user pid cpu mem cmd <<<"$e"
        printf '      {"user": "%s", "pid": %s, "cpu_percent": %s, "mem_percent": %s, "command": "%s"}' \
            "$(json_escape "$user")" "$(json_int_or_null "$pid")" \
            "$(json_num_or_null "$cpu")" "$(json_num_or_null "$mem")" "$(json_escape "$cmd")"
        ((idx < ${#TOP_CPU_ENTRIES[@]} - 1)) && printf ','
        printf '\n'
        ((idx++)) || true
    done
    printf '    ],\n'
    printf '    "top_mem": [\n'
    idx=0
    for e in "${TOP_MEM_ENTRIES[@]}"; do
        IFS='|' read -r user pid cpu mem cmd <<<"$e"
        printf '      {"user": "%s", "pid": %s, "cpu_percent": %s, "mem_percent": %s, "command": "%s"}' \
            "$(json_escape "$user")" "$(json_int_or_null "$pid")" \
            "$(json_num_or_null "$cpu")" "$(json_num_or_null "$mem")" "$(json_escape "$cmd")"
        ((idx < ${#TOP_MEM_ENTRIES[@]} - 1)) && printf ','
        printf '\n'
        ((idx++)) || true
    done
    printf '    ],\n'
    printf '    "zombies": %s\n' "$(json_int_or_null "$ZOMBIES")"
    printf '  },\n'
}

render_json_temps() {
    printf '  "temperatures": ['
    local idx=0 e label value
    if ((${#TEMP_ENTRIES[@]} > 0)); then printf '\n'; fi
    for e in "${TEMP_ENTRIES[@]}"; do
        IFS='|' read -r label value <<<"$e"
        printf '    {"label": "%s", "value": "%s"}' "$(json_escape "$label")" "$(json_escape "$value")"
        if ((idx < ${#TEMP_ENTRIES[@]} - 1)); then printf ',\n'; else printf '\n'; fi
        ((idx++)) || true
    done
    if ((${#TEMP_ENTRIES[@]} > 0)); then printf '  ],\n'; else printf '],\n'; fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    setup_colors
    check_essential_deps

    if ((DO_INSTALL == 1)); then
        if ! run_install; then
            exit 3
        fi
    fi

    if [[ ! -d "$PROC_ROOT" ]]; then
        warn_add "Process filesystem not available ($PROC_ROOT missing); most metrics will be null"
    fi

    collect_all

    if ((OUTPUT_JSON == 1)); then
        render_json
    else
        render_human
    fi
    return 0
}

main "$@"
