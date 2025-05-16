#!/usr/bin/env bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'
BOLD=$(tput bold)
NORMAL=$(tput sgr0)

separator="================================================================================"

print_header() {
    echo -e "\n${CYAN}${BOLD}$1${RESET}"
    echo "$separator"
}


for pkg in lm-sensors bc; do
    if ! dpkg -s "$pkg" &>/dev/null && ! rpm -q "$pkg" &>/dev/null && ! pacman -Qi "$pkg" &>/dev/null; then
        echo -e "${YELLOW}Installing $pkg...${RESET}"
        if command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y "$pkg"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            sudo pacman -Sy --noconfirm "$pkg"
        else
            echo "Unsupported package manager. Please install $pkg manually."
        fi
    fi
done

print_header "🖥️ Operating System"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "${GREEN}${NAME} ${VERSION}${RESET}"
else
    uname -a
fi

print_header "⏱️ CPU Uptime"
read system_uptime _ </proc/uptime
total_seconds=${system_uptime%.*}
fractional_part=${system_uptime#*.}
days=$((total_seconds / 86400))
hours=$(((total_seconds % 86400) / 3600))
minutes=$(((total_seconds % 3600) / 60))
seconds=$((total_seconds % 60))
[[ $days -gt 0 ]] && echo "$days days"
[[ $hours -gt 0 ]] && echo "$hours hours"
[[ $minutes -gt 0 ]] && echo "$minutes minutes"
[[ $seconds -gt 0 || $fractional_part -ne 0 ]] && echo "$seconds.${fractional_part} seconds"

top_output=$(top -bn1)
cpu_idle=$(echo "$top_output" | grep "Cpu(s)" | sed 's/.*, *\([0-9.]*\)%* id.*/\1/')
cpu_usage=$(awk -v idle="$cpu_idle" 'BEGIN { printf("%.1f", 100 - idle) }')

print_header "🧮 CPU Usage"
echo -e "Usage         : ${GREEN}${cpu_usage}%${RESET}"

print_header "📊 Load Average"
uptime | awk -F'load average:' '{ print "Load Averages:" $2 }'

print_header "🧩 Logical CPUs"
nproc

read total_memory available_memory <<<$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {print t, a}' /proc/meminfo)
used_memory=$((total_memory - available_memory))
used_memory_percent=$(awk -v u=$used_memory -v t=$total_memory 'BEGIN { printf("%.1f", (u / t) * 100) }')
free_memory_percent=$(awk -v a=$available_memory -v t=$total_memory 'BEGIN { printf("%.1f", (a / t) * 100) }')
total_memory_mb=$(awk -v t=$total_memory 'BEGIN { printf("%.1f", t/1024) }')
used_memory_mb=$(awk -v u=$used_memory 'BEGIN { printf("%.1f", u/1024) }')
available_memory_mb=$(awk -v a=$available_memory 'BEGIN { printf("%.1f", a/1024) }')

print_header "💾 Memory Usage"
printf "Total Memory    : ${YELLOW}%-10s MB${RESET}\n" "$total_memory_mb"
printf "Used Memory     : ${YELLOW}%-10s MB${RESET} (%s%%)\n" "$used_memory_mb" "$used_memory_percent"
printf "Free/Available  : ${YELLOW}%-10s MB${RESET} (%s%%)\n" "$available_memory_mb" "$free_memory_percent"

print_header "💤 Swap Usage"
free -m | awk -v g="$GREEN" -v y="$YELLOW" -v r="$RESET" '/Swap:/ {
    total=$2; used=$3; free=$4;
    printf "Total Swap     : %s%d MB%s\n", g, total, r;
    printf "Used Swap      : %s%d MB%s\n", y, used, r;
    printf "Free Swap      : %s%d MB%s\n", g, free, r;
}'

df_output=$(df -h /)
size_disk=$(echo "$df_output" | awk 'NR==2 {printf $2}')
read used_disk available_disk <<<$(echo "$df_output" | awk 'NR==2 {print $3, $4}')
df_output_raw=$(df /)
read size_disk_kb used_disk_kb available_disk_kb <<<$(echo "$df_output_raw" | awk 'NR==2 {print $2, $3, $4}')
used_disk_percent=$(echo "scale=2; $used_disk_kb * 100 / $size_disk_kb" | bc)
available_disk_percent=$(echo "scale=2; $available_disk_kb * 100 / $size_disk_kb" | bc)

print_header "🗄️ Disk Usage"
printf "Disk Size       : ${YELLOW}%-10s${RESET}\n" "$size_disk"
printf "Used Space      : ${YELLOW}%-10s${RESET} (%s%%)\n" "$used_disk" "$used_disk_percent"
printf "Available Space : ${YELLOW}%-10s${RESET} (%s%%)\n" "$available_disk" "$available_disk_percent"

print_header "📁 Inode Usage"
df -i / | awk 'NR==2 { printf "Inodes: total=%s, used=%s, free=%s, usage=%s\n", $2, $3, $4, $5 }'

print_header "🔥 Top 10 Processes by CPU"
ps aux --sort=-%cpu | awk 'NR==1 || NR<=11 { printf "%-10s %-6s %-5s %-5s %s\n", $1, $2, $3, $4, $11 }'

print_header "🧠 Top 10 Processes by Memory"
ps aux --sort=-%mem | awk 'NR==1 || NR<=11 { printf "%-10s %-6s %-5s %-5s %s\n", $1, $2, $3, $4, $11 }'

print_header "🧟 Zombie Processes"
zombies=$(ps aux | awk '$8 ~ /Z/ { count++ } END { print count+0 }')
color=$([ "$zombies" -eq 0 ] && echo "$GREEN" || echo "$YELLOW")
echo -e "Total zombie processes: ${color}${zombies}${RESET}"

print_header "🌐 Network Usage (eth0)"
interface="eth0"
if grep -q "$interface" /proc/net/dev; then
    awk -v iface="$interface" -v g="$GREEN" -v y="$YELLOW" -v r="$RESET" '$0 ~ iface {
            rx=$2/1024/1024; tx=$10/1024/1024;
            printf "Received     : %s%.2f MB%s\n", g, rx, r;
            printf "Transmitted  : %s%.2f MB%s\n", y, tx, r;
        }' /proc/net/dev
else
    echo -e "${YELLOW}Interface $interface not found.${RESET}"
fi

print_header "🌡️ CPU Temperatures"
temps=$(sensors 2>/dev/null | grep -E 'Core|Package|Tdie|temp1' | grep -v 'ERROR')
if [[ -z "$temps" ]]; then
    echo -e "${YELLOW}No valid temperature output.${RESET}"
else
    echo "$temps" | awk -v c="$CYAN" -v r="$RESET" '{ printf "%s%-15s%s %s\n", c, $1, r, $2 }'
fi
