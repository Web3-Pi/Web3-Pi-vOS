#!/bin/bash
#
# Web3 Pi Control Panel - System Module
#

system_menu() {
    while true; do
        CURRENT_HOSTNAME=$(hostname)
        CHOICE=$(whiptail --title "System" \
            --menu "Hostname: $CURRENT_HOSTNAME" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Change Hostname" \
            "2" "Change ethereum Password" \
            "3" "System Information" \
            "4" "Reboot System" \
            "5" "Shutdown System" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_change_hostname ;;
            2) system_change_password ;;
            3) system_info ;;
            4)
                if yesno_box "Reboot" "Reboot the system now?"; then
                    reboot
                fi
                ;;
            5)
                if yesno_box "Shutdown" "Shutdown the system now?"; then
                    poweroff
                fi
                ;;
            0|"") return ;;
        esac
    done
}

system_change_hostname() {
    CURRENT=$(hostname)
    NEW_HOSTNAME=$(input_box "Change Hostname" "Enter new hostname (current: $CURRENT):" "$CURRENT")

    if [ -z "$NEW_HOSTNAME" ]; then
        return
    fi

    # Validate hostname (RFC 1123: alphanumeric and hyphens, max 63 chars)
    if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        msg_box "Error" "Invalid hostname.\n\nHostname must:\n- Start with a letter or number\n- Contain only letters, numbers, and hyphens\n- Be max 63 characters"
        return
    fi

    if [ "$NEW_HOSTNAME" = "$CURRENT" ]; then
        return
    fi

    if yesno_box "Confirm" "Change hostname from '$CURRENT' to '$NEW_HOSTNAME'?"; then
        # Update hostname
        hostnamectl set-hostname "$NEW_HOSTNAME"

        # Update /etc/hosts
        sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts

        msg_box "Success" "Hostname changed to: $NEW_HOSTNAME\n\nA reboot is recommended for all services to recognize the new hostname."
    fi
}

system_change_password() {
    if yesno_box "Change Password" "Change password for user 'ethereum'?"; then
        clear
        passwd ethereum
        read -p "Press Enter to continue..."
    fi
}

system_info() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    SYSTEM INFORMATION\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Hardware info
    INFO+="▶ HARDWARE\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # RPi model
    RPI_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "Unknown")
    INFO+="  Model: $RPI_MODEL\n"

    # Serial number
    SERIAL=$(cat /proc/cpuinfo 2>/dev/null | grep Serial | awk '{print $3}' || echo "N/A")
    INFO+="  Serial: $SERIAL\n"

    # CPU info
    CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | cut -d: -f2 | xargs || echo "N/A")
    CPU_CORES=$(nproc)
    CPU_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf "%.0f MHz", $1/1000}' || echo "N/A")
    INFO+="  CPU: $CPU_MODEL\n"
    INFO+="  Cores: $CPU_CORES @ $CPU_FREQ\n"

    # RAM (in MB)
    RAM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
    INFO+="  RAM: ${RAM_TOTAL} MB\n"

    # Operating System
    INFO+="\n▶ OPERATING SYSTEM\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # OS info
    if [ -f /etc/os-release ]; then
        OS_NAME=$(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)
    else
        OS_NAME=$(uname -o)
    fi
    INFO+="  OS: $OS_NAME\n"

    # Kernel
    KERNEL=$(uname -r)
    INFO+="  Kernel: $KERNEL\n"

    # Architecture
    ARCH=$(uname -m)
    INFO+="  Architecture: $ARCH\n"

    # Hostname
    INFO+="  Hostname: $(hostname)\n"

    # Uptime
    UPTIME=$(uptime -p)
    INFO+="  Uptime: $UPTIME\n"

    # Firmware
    INFO+="\n▶ FIRMWARE\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # EEPROM version
    if command -v rpi-eeprom-update &>/dev/null; then
        EEPROM_VER=$(rpi-eeprom-update 2>/dev/null | grep "CURRENT" | sed 's/.*CURRENT: //' || echo "N/A")
        INFO+="  EEPROM: $EEPROM_VER\n"
    fi

    # Bootloader
    if [ -f /boot/firmware/config.txt ]; then
        INFO+="  Boot: UEFI/NVMe\n"
    else
        INFO+="  Boot: Legacy\n"
    fi

    # Network
    INFO+="\n▶ NETWORK\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
    MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || cat /sys/class/net/end0/address 2>/dev/null || echo "N/A")
    INFO+="  IP: $IP\n"
    INFO+="  MAC: $MAC\n"

    # Current status
    INFO+="\n▶ CURRENT STATUS\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    # Load
    LOAD=$(cat /proc/loadavg | cut -d' ' -f1-3)
    INFO+="  Load: $LOAD\n"

    # Memory usage
    MEM_PCT=$(free | grep Mem | awk '{printf "%.1f%%", $3/$2 * 100}')
    INFO+="  Memory: $MEM_PCT used\n"

    # Disk usage
    DISK_PCT=$(df / | tail -1 | awk '{print $5}')
    INFO+="  Disk: $DISK_PCT used\n"

    # Temperatures
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    INFO+="  CPU Temp: ${CPU_TEMP}°C\n"

    # GPU temp (RPi specific)
    GPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "N/A")
    if [ "$GPU_TEMP" != "N/A" ]; then
        INFO+="  GPU Temp: ${GPU_TEMP}°C\n"
    fi

    # NVMe temp
    NVME_TEMP=$(cat /sys/class/nvme/nvme0/hwmon*/temp1_input 2>/dev/null | awk '{printf "%.1f", $1/1000}')
    if [ -n "$NVME_TEMP" ]; then
        INFO+="  NVMe Temp: ${NVME_TEMP}°C\n"
    fi

    # Throttling status
    THROTTLE=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "N/A")
    if [ "$THROTTLE" = "0x0" ]; then
        INFO+="  Throttling: None ✓\n"
    elif [ "$THROTTLE" != "N/A" ]; then
        INFO+="  Throttling: Active! ($THROTTLE)\n"
    fi

    whiptail --title "System Information" --scrolltext --msgbox "$INFO" 30 $TERM_WIDTH
}
