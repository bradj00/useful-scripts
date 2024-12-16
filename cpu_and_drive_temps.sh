#!/bin/bash

# Colors for temperature thresholds
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Colors for different drive types/sizes
CYAN='\033[0;36m'
ORANGE='\033[38;5;208m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
PURPLE='\033[0;35m'  # For CPU temps

# Special formatting for hostname, uptime, and time
CYAN_BG='\033[46m'
YELLOW_BG='\033[43m'
GREEN_BG='\033[42m'  # For time
BLACK_FG='\033[30m'
UNDERLINE='\033[4m'

# Function to get formatted hostname
get_hostname_header() {
    local hostname=$(hostname)
    printf "${UNDERLINE}${CYAN_BG}${BLACK_FG}[ %s ]${NC}\n" "$hostname"
}

# Function to get formatted system uptime
get_system_uptime() {
    local uptime_text=$(uptime -p)
    printf "${YELLOW_BG}${BLACK_FG}%s${NC}\n" "$uptime_text"
}

# Function to get formatted current time
get_current_time() {
    local current_time=$(date +"%I:%M:%S %p %Z")
    printf "${GREEN_BG}${BLACK_FG}%s${NC}\n\n" "$current_time"
}

# Function to format CPU temperature lines
format_cpu_temps() {
    sensors | grep "Core" | while read -r line; do
        # Extract core number and the first temperature value (actual temp)
        if [[ $line =~ Core[[:space:]]+([0-9]+):[[:space:]]*\+([0-9]+)\.[0-9]°C ]]; then
            core="${BASH_REMATCH[1]}"
            temp="${BASH_REMATCH[2]}"
            
            # Format the core info string with proper padding
            printf "${PURPLE}[Core %-11s]${NC} " "$core"
            
            # Color code based on temperature
            if [ "$temp" -lt 45 ]; then
                printf "${GREEN}%d°C${NC}\n" "$temp"
            elif [ "$temp" -lt 75 ]; then
                printf "${YELLOW}%d°C${NC}\n" "$temp"
            else
                printf "${RED}%d°C${NC}\n" "$temp"
            fi
        fi
    done
}

# Function to detect and return all physical drives
get_physical_drives() {
    local drive_type=$1
    if [ "$drive_type" = "nvme" ]; then
        lsblk -d -n -o NAME | grep "nvme" | sort
    else
        lsblk -d -n -o NAME | grep "^sd" | sort
    fi
}

# Function to get drive size
get_drive_size() {
    local drive=$1
    local size=$(lsblk -b -d -n -o SIZE "/dev/$drive" | numfmt --to=iec)
    echo "$size"
}

# Function to get drive color based on type and size
get_drive_color() {
    local drive=$1
    local size=$(get_drive_size $drive)
    
    case $drive in
        nvme*)
            echo $CYAN
            ;;
        sd*)
            if [ "$size" \> "10T" ]; then
                echo $ORANGE
            else
                echo $MAGENTA
            fi
            ;;
        *)
            echo $WHITE
            ;;
    esac
}

# Function to format a single temperature line for drives
format_temp_line() {
    local drive=$1
    local type=$2
    local drive_color=$(get_drive_color $drive)
    local size=$(get_drive_size $drive)
    
    if [ "$type" = "nvme" ]; then
        temp=$(smartctl -A "/dev/$drive" 2>/dev/null | grep "Temperature:" | awk '{print $2}')
    else
        temp=$(smartctl -A "/dev/$drive" 2>/dev/null | grep "Temperature_Celsius" | awk '{print $10}')
    fi
    
    if [ ! -z "$temp" ]; then
        local drive_info="$drive - $size"
        if [ $temp -lt 45 ]; then
            printf "${drive_color}[%-16s]${NC} ${GREEN}%d°C${NC}\n" "$drive_info" "$temp"
        elif [ $temp -lt 60 ]; then
            printf "${drive_color}[%-16s]${NC} ${YELLOW}%d°C${NC}\n" "$drive_info" "$temp"
        else
            printf "${drive_color}[%-16s]${NC} ${RED}%d°C${NC}\n" "$drive_info" "$temp"
        fi
    fi
}

# Check if required tools are installed
if ! command -v smartctl &> /dev/null; then
    echo "smartctl is not installed. Please install smartmontools:"
    echo "sudo apt install smartmontools"
    exit 1
fi

if ! command -v sensors &> /dev/null; then
    echo "lm-sensors is not installed. Please install it:"
    echo "sudo apt install lm-sensors"
    echo "Then run 'sudo sensors-detect' and follow the prompts."
    exit 1
fi

# Temporary file for output buffering
TMPFILE=$(mktemp)

# Function to generate the entire display
generate_display() {
    # Clear the temporary file
    > "$TMPFILE"
    
    # Write hostname header and uptime
    get_hostname_header > "$TMPFILE"
    get_system_uptime >> "$TMPFILE"
    get_current_time >> "$TMPFILE"
    
    # Write to temporary file
    echo "System Temperature Monitor" >> "$TMPFILE"
    echo "------------------------" >> "$TMPFILE"
    echo "" >> "$TMPFILE"
    
    # CPU section
    echo "CPU Temperatures:" >> "$TMPFILE"
    format_cpu_temps >> "$TMPFILE"
    echo "" >> "$TMPFILE"
    
    # NVMe section
    local nvme_drives=$(get_physical_drives "nvme")
    if [ ! -z "$nvme_drives" ]; then
        echo "NVMe Drives:" >> "$TMPFILE"
        while read -r drive; do
            format_temp_line "$drive" "nvme" >> "$TMPFILE"
        done <<< "$nvme_drives"
        echo "" >> "$TMPFILE"
    fi
    
    # SATA section
    local sata_drives=$(get_physical_drives "sata")
    if [ ! -z "$sata_drives" ]; then
        echo "SATA Drives:" >> "$TMPFILE"
        while read -r drive; do
            format_temp_line "$drive" "sata" >> "$TMPFILE"
        done <<< "$sata_drives"
    fi
    
    # Clear screen and display everything at once
    tput clear
    cat "$TMPFILE"
}

# Hide cursor
tput civis

# Cleanup on exit
trap 'tput cnorm; rm -f "$TMPFILE"' EXIT

# Main loop
while true; do
    generate_display
    sleep 2
done