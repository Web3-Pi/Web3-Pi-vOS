#!/bin/bash
#
# Web3 Pi Control Panel - System Module
#

system_menu() {
    while true; do
        CURRENT_HOSTNAME=$(hostname)
        CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "N/A")
        CHOICE=$(whiptail --title "System" \
            --menu "Hostname: $CURRENT_HOSTNAME | TZ: $CURRENT_TZ" \
            $TERM_HEIGHT $TERM_WIDTH 12 \
            "1" "Change Hostname" \
            "2" "Change ethereum Password" \
            "3" "Set Timezone" \
            "4" "Set Keyboard Layout" \
            "5" "Time Sync Status (Chrony)" \
            "6" "System Information" \
            "7" "Reboot System" \
            "8" "Shutdown System" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_change_hostname ;;
            2) system_change_password ;;
            3) system_timezone ;;
            4) system_keyboard ;;
            5) system_time_sync ;;
            6) system_info ;;
            7)
                if yesno_box "Reboot" "Reboot the system now?"; then
                    reboot
                fi
                ;;
            8)
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

system_timezone() {
    # Get current timezone
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

    # Common timezones for Europe (most likely for this project)
    CHOICE=$(whiptail --title "Set Timezone" \
        --menu "Current: $CURRENT_TZ\n\nSelect timezone:" 24 $TERM_WIDTH 14 \
        "Europe/Warsaw" "Poland (CET/CEST)" \
        "Europe/London" "UK (GMT/BST)" \
        "Europe/Berlin" "Germany (CET/CEST)" \
        "Europe/Paris" "France (CET/CEST)" \
        "Europe/Amsterdam" "Netherlands (CET/CEST)" \
        "Europe/Zurich" "Switzerland (CET/CEST)" \
        "Europe/Vienna" "Austria (CET/CEST)" \
        "Europe/Prague" "Czech Republic (CET/CEST)" \
        "America/New_York" "US Eastern (EST/EDT)" \
        "America/Los_Angeles" "US Pacific (PST/PDT)" \
        "Asia/Singapore" "Singapore (SGT)" \
        "Asia/Tokyo" "Japan (JST)" \
        "UTC" "Coordinated Universal Time" \
        "OTHER" "Enter manually..." \
        3>&1 1>&2 2>&3)

    if [ -z "$CHOICE" ]; then
        return
    fi

    if [ "$CHOICE" = "OTHER" ]; then
        # Show available timezones
        CHOICE=$(input_box "Enter Timezone" "Enter timezone (e.g., Europe/Warsaw):\n\nList available: timedatectl list-timezones" "$CURRENT_TZ")
        if [ -z "$CHOICE" ]; then
            return
        fi
    fi

    # Validate timezone exists
    if ! timedatectl list-timezones | grep -qx "$CHOICE"; then
        msg_box "Error" "Invalid timezone: $CHOICE\n\nRun 'timedatectl list-timezones' to see available options."
        return
    fi

    if [ "$CHOICE" = "$CURRENT_TZ" ]; then
        return
    fi

    # Set timezone
    timedatectl set-timezone "$CHOICE"
    msg_box "Success" "Timezone set to: $CHOICE\n\nCurrent time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

system_keyboard() {
    # Get current keyboard layout
    CURRENT_LAYOUT=$(localectl status 2>/dev/null | grep "X11 Layout" | awk '{print $3}')
    [ -z "$CURRENT_LAYOUT" ] && CURRENT_LAYOUT=$(cat /etc/default/keyboard 2>/dev/null | grep XKBLAYOUT | cut -d'"' -f2)
    [ -z "$CURRENT_LAYOUT" ] && CURRENT_LAYOUT="us"

    CHOICE=$(whiptail --title "Set Keyboard Layout" \
        --menu "Current: $CURRENT_LAYOUT\n\nSelect keyboard layout:" 22 $TERM_WIDTH 12 \
        "pl" "Polish" \
        "us" "US English" \
        "uk" "UK English" \
        "de" "German" \
        "fr" "French" \
        "es" "Spanish" \
        "it" "Italian" \
        "pt" "Portuguese" \
        "nl" "Dutch" \
        "cz" "Czech" \
        "OTHER" "Enter manually..." \
        3>&1 1>&2 2>&3)

    if [ -z "$CHOICE" ]; then
        return
    fi

    if [ "$CHOICE" = "OTHER" ]; then
        CHOICE=$(input_box "Enter Layout" "Enter keyboard layout code (e.g., pl, us, de):\n\nList available: localectl list-keymaps" "$CURRENT_LAYOUT")
        if [ -z "$CHOICE" ]; then
            return
        fi
    fi

    if [ "$CHOICE" = "$CURRENT_LAYOUT" ]; then
        return
    fi

    # Set keyboard layout
    localectl set-keymap "$CHOICE" 2>/dev/null
    localectl set-x11-keymap "$CHOICE" 2>/dev/null

    # Also update /etc/default/keyboard for console
    if [ -f /etc/default/keyboard ]; then
        sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$CHOICE\"/" /etc/default/keyboard
    fi

    msg_box "Success" "Keyboard layout set to: $CHOICE\n\nChanges may require a reboot to fully apply."
}

system_time_sync() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                    TIME SYNCHRONIZATION\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    # Current time info
    INFO+="▶ CURRENT TIME\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  Local:    $(date '+%Y-%m-%d %H:%M:%S %Z')\n"
    INFO+="  UTC:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')\n"
    INFO+="  Timezone: $(timedatectl show --property=Timezone --value 2>/dev/null || echo 'N/A')\n"

    # Chrony status
    INFO+="\n▶ CHRONY STATUS\n"
    INFO+="─────────────────────────────────────────────────────────\n"

    if systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
        INFO+="  Service: Running ✓\n"

        # Chrony tracking info
        TRACKING=$(chronyc tracking 2>/dev/null)
        if [ -n "$TRACKING" ]; then
            REF_ID=$(echo "$TRACKING" | grep "Reference ID" | cut -d: -f2 | xargs)
            STRATUM=$(echo "$TRACKING" | grep "Stratum" | awk '{print $3}')
            SYSTEM_TIME=$(echo "$TRACKING" | grep "System time" | cut -d: -f2 | xargs)
            LAST_OFFSET=$(echo "$TRACKING" | grep "Last offset" | cut -d: -f2 | xargs)
            RMS_OFFSET=$(echo "$TRACKING" | grep "RMS offset" | cut -d: -f2 | xargs)

            INFO+="  Reference: $REF_ID\n"
            INFO+="  Stratum:   $STRATUM\n"
            INFO+="  Offset:    $LAST_OFFSET\n"
            INFO+="  RMS:       $RMS_OFFSET\n"
        fi

        # Sync status
        INFO+="\n▶ SYNC SOURCES\n"
        INFO+="─────────────────────────────────────────────────────────\n"
        SOURCES=$(chronyc sources 2>/dev/null | tail -n +3)
        if [ -n "$SOURCES" ]; then
            # Show first few sources
            while IFS= read -r line; do
                # Parse source line: MS Name/IP address Stratum Poll Reach LastRx Last sample
                INFO+="  $line\n"
            done <<< "$(echo "$SOURCES" | head -5)"
        else
            INFO+="  No sources available\n"
        fi

        # NTP synchronized?
        NTP_SYNC=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
        INFO+="\n▶ SYNCHRONIZATION\n"
        INFO+="─────────────────────────────────────────────────────────\n"
        if [ "$NTP_SYNC" = "yes" ]; then
            INFO+="  NTP Synchronized: Yes ✓\n"
        else
            INFO+="  NTP Synchronized: No ✗\n"
            INFO+="  (May take a few minutes after boot)\n"
        fi
    else
        INFO+="  Service: NOT RUNNING ✗\n"
        INFO+="\n  To start: sudo systemctl start chronyd\n"
    fi

    whiptail --title "Time Sync Status (Chrony)" --scrolltext --msgbox "$INFO" 26 $TERM_WIDTH
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
