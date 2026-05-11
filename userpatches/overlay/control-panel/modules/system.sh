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
            $TERM_HEIGHT $TERM_WIDTH 14 \
            "1" "Change Hostname" \
            "2" "Change ethereum Password" \
            "3" "Set Timezone" \
            "4" "Set Keyboard Layout" \
            "5" "Time Sync Status (Chrony)" \
            "6" "Edit Boot Config (config.txt)" \
            "7" "System Information" \
            "8" "Update Firmware (EEPROM)" \
            "B" "OC (Pi-Under-Pressure)" \
            "C" "Web3 Pi UPS" \
            "D" "Auto OC Detection" \
            "9" "Reboot System" \
            "A" "Shutdown System" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_change_hostname ;;
            2) system_change_password ;;
            3) system_timezone ;;
            4) system_keyboard ;;
            5) system_time_sync ;;
            6) system_edit_config ;;
            7) system_info ;;
            8) system_firmware_update ;;
            B) system_oc_menu ;;
            C) system_ups_menu ;;
            D) system_auto_oc_menu ;;
            9)
                if yesno_box "Reboot" "Reboot the system now?"; then
                    reboot
                fi
                ;;
            A)
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

system_edit_config() {
    CONFIG_FILE="/boot/firmware/config.txt"

    if [ ! -f "$CONFIG_FILE" ]; then
        msg_box "Error" "File not found: $CONFIG_FILE"
        return
    fi

    if yesno_box "Edit Boot Config" "Edit $CONFIG_FILE?\n\nChanges require a reboot to take effect.\n\nEditor: nano (Ctrl+X to exit)"; then
        clear
        nano "$CONFIG_FILE"
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

system_firmware_update() {
    # Check if rpi-eeprom-update is available
    if ! command -v rpi-eeprom-update &>/dev/null; then
        msg_box "Error" "rpi-eeprom-update not found.\n\nThis tool is only available on Raspberry Pi."
        return
    fi

    # Get current firmware status
    EEPROM_OUTPUT=$(rpi-eeprom-update 2>&1)
    CURRENT=$(echo "$EEPROM_OUTPUT" | grep "CURRENT" | sed 's/.*CURRENT: //')

    while true; do
        CHOICE=$(whiptail --title "Update Firmware (EEPROM)" \
            --menu "Current: $CURRENT\n\nSelect firmware branch:" \
            $TERM_HEIGHT $TERM_WIDTH 6 \
            "1" "Release (stable, recommended)" \
            "2" "Latest (beta, from GitHub master)" \
            "3" "View Current Status" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_firmware_update_release ;;
            2) system_firmware_update_latest ;;
            3) system_firmware_status ;;
            0|"") return ;;
        esac
    done
}

system_firmware_status() {
    INFO="═══════════════════════════════════════════════════════════\n"
    INFO+="                  RASPBERRY PI FIRMWARE\n"
    INFO+="═══════════════════════════════════════════════════════════\n\n"

    EEPROM_OUTPUT=$(rpi-eeprom-update 2>&1)

    CURRENT=$(echo "$EEPROM_OUTPUT" | grep "CURRENT" | sed 's/.*CURRENT: //')
    LATEST=$(echo "$EEPROM_OUTPUT" | grep "LATEST" | sed 's/.*LATEST: //')

    INFO+="▶ BOOTLOADER EEPROM\n"
    INFO+="─────────────────────────────────────────────────────────\n"
    INFO+="  Current: $CURRENT\n"
    INFO+="  Latest (release): $LATEST\n\n"

    if echo "$EEPROM_OUTPUT" | grep -q "BOOTLOADER: up to date"; then
        INFO+="  Status: Up to date ✓\n"
    else
        INFO+="  Status: Update available\n"
    fi

    msg_box "Firmware Status" "$INFO"
}

system_firmware_update_release() {
    EEPROM_OUTPUT=$(rpi-eeprom-update 2>&1)

    # Check if update is needed
    if echo "$EEPROM_OUTPUT" | grep -q "BOOTLOADER: up to date"; then
        msg_box "Firmware Status" "Bootloader is already up to date (release branch)."
        return
    fi

    CURRENT=$(echo "$EEPROM_OUTPUT" | grep "CURRENT" | sed 's/.*CURRENT: //')
    LATEST=$(echo "$EEPROM_OUTPUT" | grep "LATEST" | sed 's/.*LATEST: //')

    if ! yesno_box "Update Firmware (Release)" "Current: $CURRENT\nLatest:  $LATEST\n\nApply release firmware update?\n\nA reboot will be required after the update."; then
        return
    fi

    clear
    echo "═══════════════════════════════════════════════════════════"
    echo "         UPDATING FIRMWARE (RELEASE BRANCH)"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    if rpi-eeprom-update -a; then
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Firmware update staged successfully."
        echo "  Reboot required to apply the update."
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        read -p "Press Enter to continue..."

        if yesno_box "Reboot Now?" "Firmware update staged.\n\nReboot now to apply the update?"; then
            reboot
        fi
    else
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Firmware update failed. Check the output above."
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        read -p "Press Enter to continue..."
    fi
}

system_firmware_update_latest() {
    if ! yesno_box "Update Firmware (Latest/Beta)" "This will install the LATEST firmware from GitHub master branch.\n\nThis is BETA firmware and may be unstable.\n\nA reboot will be required after the update.\n\nContinue?"; then
        return
    fi

    # Check for git
    if ! command -v git &>/dev/null; then
        msg_box "Error" "git is not installed.\n\nInstall with: apt install git"
        return
    fi

    clear
    echo "═══════════════════════════════════════════════════════════"
    echo "         UPDATING FIRMWARE (LATEST/BETA BRANCH)"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Cloning rpi-eeprom repository from GitHub..."
    echo ""

    # Clone/update the repository
    EEPROM_DIR="/opt/web3pi/rpi-eeprom"

    if [ -d "$EEPROM_DIR" ]; then
        echo "Updating existing repository..."
        cd "$EEPROM_DIR" && git fetch --all && git reset --hard origin/master
    else
        echo "Cloning repository..."
        mkdir -p /opt/web3pi
        git clone -b master https://github.com/raspberrypi/rpi-eeprom "$EEPROM_DIR"
    fi

    if [ $? -ne 0 ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Failed to clone/update repository."
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "Installing latest firmware..."
    echo ""

    if "$EEPROM_DIR/test/install" -b; then
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Latest firmware installed successfully."
        echo "  Reboot required to apply the update."
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        read -p "Press Enter to continue..."

        if yesno_box "Reboot Now?" "Latest firmware installed.\n\nReboot now to apply the update?"; then
            reboot
        fi
    else
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Firmware installation failed. Check the output above."
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        read -p "Press Enter to continue..."
    fi
}

system_oc_menu() {
    # Check if pi-under-pressure is installed
    local INSTALLED="No"
    if command -v pi-under-pressure &>/dev/null; then
        INSTALLED="Yes"
    fi

    while true; do
        CHOICE=$(whiptail --title "OC (Pi-Under-Pressure)" \
            --menu "Stress testing tool for Raspberry Pi\nInstalled: $INSTALLED" \
            $TERM_HEIGHT $TERM_WIDTH 6 \
            "1" "Install Pi-Under-Pressure" \
            "2" "Run Stress Test (5 min)" \
            "3" "About" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_oc_install ;;
            2) system_oc_run ;;
            3) system_oc_about ;;
            0|"") return ;;
        esac

        # Refresh installed status
        if command -v pi-under-pressure &>/dev/null; then
            INSTALLED="Yes"
        fi
    done
}

system_oc_install() {
    if command -v pi-under-pressure &>/dev/null; then
        if ! yesno_box "Already Installed" "Pi-Under-Pressure is already installed.\n\nReinstall?"; then
            return
        fi
    fi

    if ! yesno_box "Install Pi-Under-Pressure" "This will install Pi-Under-Pressure stress testing tool from GitHub.\n\nSource: github.com/cmd0s/Pi-Under-Pressure\n\nContinue?"; then
        return
    fi

    clear
    echo "==============================================================="
    echo "         INSTALLING PI-UNDER-PRESSURE"
    echo "==============================================================="
    echo ""

    if curl -sSL https://raw.githubusercontent.com/cmd0s/Pi-Under-Pressure/main/install.sh | bash; then
        echo ""
        echo "==============================================================="
        echo "  Pi-Under-Pressure installed successfully."
        echo "==============================================================="
        echo ""
    else
        echo ""
        echo "==============================================================="
        echo "  Installation failed. Check the output above."
        echo "==============================================================="
        echo ""
    fi

    read -p "Press Enter to continue..."
}

system_oc_run() {
    if ! command -v pi-under-pressure &>/dev/null; then
        msg_box "Not Installed" "Pi-Under-Pressure is not installed.\n\nPlease install it first using option 1."
        return
    fi

    if ! yesno_box "Run Stress Test" "This will run a 5-minute stress test with extended monitoring.\n\nCommand: pi-under-pressure -d 5m -e\n\nThis will stress CPU, RAM, and monitor temperatures.\n\nContinue?"; then
        return
    fi

    clear
    echo "==============================================================="
    echo "         PI-UNDER-PRESSURE STRESS TEST"
    echo "==============================================================="
    echo ""
    echo "Running: pi-under-pressure -d 5m -e"
    echo ""

    pi-under-pressure -d 5m -e

    echo ""
    echo "==============================================================="
    echo "  Stress test completed."
    echo "==============================================================="
    echo ""

    read -p "Press Enter to continue..."
}

system_oc_about() {
    INFO="===============================================================\n"
    INFO+="               PI-UNDER-PRESSURE\n"
    INFO+="===============================================================\n\n"
    INFO+="A stress testing tool for Raspberry Pi to verify system\n"
    INFO+="stability under load, especially useful for testing\n"
    INFO+="overclocking configurations.\n\n"
    INFO+="Features:\n"
    INFO+="  - CPU stress testing\n"
    INFO+="  - Memory stress testing\n"
    INFO+="  - Temperature monitoring\n"
    INFO+="  - Throttling detection\n\n"
    INFO+="Source: github.com/cmd0s/Pi-Under-Pressure\n"

    msg_box "About Pi-Under-Pressure" "$INFO"
}

# =============================================================================
# Web3 Pi UPS Functions
# =============================================================================

system_ups_menu() {
    while true; do
        # Check installation and service status
        local INSTALLED="No"
        local SERVICE_STATUS="N/A"
        local ENABLED_STATUS="N/A"

        if [ -f /usr/local/bin/w3p-ups ]; then
            INSTALLED="Yes"
            SERVICE_STATUS=$(systemctl is-active w3p-ups 2>/dev/null || echo "inactive")
            ENABLED_STATUS=$(systemctl is-enabled w3p-ups 2>/dev/null || echo "disabled")
        fi

        CHOICE=$(whiptail --title "Web3 Pi UPS" \
            --menu "Installed: $INSTALLED | Service: $SERVICE_STATUS | Boot: $ENABLED_STATUS" \
            $TERM_HEIGHT $TERM_WIDTH 9 \
            "1" "Install / Update" \
            "2" "Uninstall" \
            "3" "Service Control" \
            "4" "Configure" \
            "5" "View Logs" \
            "6" "Live UPS data" \
            "7" "About" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_ups_install ;;
            2) system_ups_uninstall ;;
            3) system_ups_service_control ;;
            4) system_ups_configure ;;
            5) system_ups_logs ;;
            6) system_ups_live_data ;;
            7) system_ups_about ;;
            0|"") return ;;
        esac
    done
}

system_ups_live_data() {
    if [ ! -f /usr/local/bin/w3p-ups ]; then
        msg_box "Not Installed" "Web3 Pi UPS is not installed."
        return
    fi
    if ! systemctl is-active w3p-ups &>/dev/null; then
        msg_box "Service Inactive" "The w3p-ups service is not running.\nStart it from 'Service Control' first."
        return
    fi
    clear
    echo "==============================================================="
    echo "  LIVE UPS DATA — press Ctrl-C to return to the menu"
    echo "==============================================================="
    echo ""
    /usr/local/bin/w3p-ups watch || true
    echo ""
    read -p "Press Enter to return to the menu..."
}

system_ups_install() {
    if [ -f /usr/local/bin/w3p-ups ]; then
        if ! yesno_box "Already Installed" "Web3 Pi UPS is already installed.\n\nReinstall?"; then
            return
        fi
    fi

    if ! yesno_box "Install Web3 Pi UPS" "This will install Web3 Pi UPS Service from GitHub.\n\nSource: github.com/Web3-Pi/Web3-Pi-UPS-Service\n\nThe service provides:\n- Battery monitoring\n- Automatic safe shutdown\n- Configurable thresholds\n\nContinue?"; then
        return
    fi

    clear
    echo "==============================================================="
    echo "            INSTALLING WEB3 PI UPS SERVICE"
    echo "==============================================================="
    echo ""

    if curl -fsSL https://raw.githubusercontent.com/Web3-Pi/Web3-Pi-UPS-Service/main/install.sh | bash; then
        echo ""
        echo "==============================================================="
        echo "  Web3 Pi UPS Service installed successfully."
        echo "==============================================================="
        echo ""
    else
        echo ""
        echo "==============================================================="
        echo "  Installation failed. Check the output above."
        echo "==============================================================="
        echo ""
    fi

    read -p "Press Enter to continue..."
}

system_ups_uninstall() {
    if [ ! -f /usr/local/bin/w3p-ups ]; then
        msg_box "Not Installed" "Web3 Pi UPS is not installed."
        return
    fi

    if ! yesno_box "Uninstall Web3 Pi UPS" "This will remove Web3 Pi UPS Service.\n\nConfiguration will be preserved in /etc/w3p-ups/\n\nContinue?"; then
        return
    fi

    clear
    echo "==============================================================="
    echo "           UNINSTALLING WEB3 PI UPS SERVICE"
    echo "==============================================================="
    echo ""

    if curl -fsSL https://raw.githubusercontent.com/Web3-Pi/Web3-Pi-UPS-Service/main/install.sh | bash -s -- --uninstall; then
        echo ""
        echo "==============================================================="
        echo "  Web3 Pi UPS Service uninstalled successfully."
        echo "==============================================================="
        echo ""
    else
        echo ""
        echo "==============================================================="
        echo "  Uninstallation failed. Check the output above."
        echo "==============================================================="
        echo ""
    fi

    read -p "Press Enter to continue..."
}

system_ups_service_control() {
    if [ ! -f /usr/local/bin/w3p-ups ]; then
        msg_box "Not Installed" "Web3 Pi UPS is not installed.\n\nPlease install it first."
        return
    fi

    while true; do
        STATUS=$(systemctl is-active w3p-ups 2>/dev/null || echo "inactive")
        ENABLED=$(systemctl is-enabled w3p-ups 2>/dev/null || echo "disabled")

        CHOICE=$(whiptail --title "Web3 Pi UPS Service Control" \
            --menu "Status: $STATUS | Boot: $ENABLED" \
            $TERM_HEIGHT $TERM_WIDTH 8 \
            "1" "Start Service" \
            "2" "Stop Service" \
            "3" "Restart Service" \
            "4" "Enable (start on boot)" \
            "5" "Disable (don't start on boot)" \
            "6" "View Service Status" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) systemctl start w3p-ups && msg_box "Success" "Service started." ;;
            2) systemctl stop w3p-ups && msg_box "Success" "Service stopped." ;;
            3) systemctl restart w3p-ups && msg_box "Success" "Service restarted." ;;
            4) systemctl enable w3p-ups && msg_box "Success" "Service enabled." ;;
            5) systemctl disable w3p-ups && msg_box "Success" "Service disabled." ;;
            6)
                STATUS_OUT=$(systemctl status w3p-ups 2>&1 | head -25)
                whiptail --title "Web3 Pi UPS Service Status" --scrolltext --msgbox "$STATUS_OUT" $TERM_HEIGHT $TERM_WIDTH
                ;;
            0|"") return ;;
        esac
    done
}

# Helper function to read TOML values
system_ups_toml_get() {
    local file="$1"
    local section="$2"
    local key="$3"

    # Simple TOML parser - reads value from [section] key = value
    awk -v section="$section" -v key="$key" '
        /^\[.*\]$/ { current_section = substr($0, 2, length($0)-2) }
        current_section == section && $1 == key {
            gsub(/.*= */, "");
            gsub(/^"/, "");
            gsub(/"$/, "");
            print;
            exit
        }
    ' "$file"
}

# Helper function to write TOML values
system_ups_toml_set() {
    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local is_string="$5"  # "true" if value should be quoted

    local temp_file=$(mktemp)
    local in_section=0
    local current_section=""

    while IFS= read -r line || [ -n "$line" ]; do
        # Check for section header
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            current_section="${line:1:${#line}-2}"
            if [ "$current_section" = "$section" ]; then
                in_section=1
            else
                in_section=0
            fi
            echo "$line" >> "$temp_file"
        # Check for key in correct section
        elif [ $in_section -eq 1 ] && [[ "$line" =~ ^$key[[:space:]]*= ]]; then
            if [ "$is_string" = "true" ]; then
                echo "$key = \"$value\"" >> "$temp_file"
            else
                echo "$key = $value" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$file"

    mv "$temp_file" "$file"

    # Restart service if running to apply changes
    if systemctl is-active w3p-ups &>/dev/null; then
        systemctl restart w3p-ups
    fi
}

system_ups_configure() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"

    if [ ! -f "$CONFIG_FILE" ]; then
        msg_box "Not Installed" "Configuration file not found.\n\nPlease install Web3 Pi UPS Service first."
        return
    fi

    while true; do
        # Read current values from config
        local CURRENT_SHUTDOWN=$(system_ups_toml_get "$CONFIG_FILE" "battery" "shutdown_threshold")
        local CURRENT_LOG=$(system_ups_toml_get "$CONFIG_FILE" "logging" "level")

        CHOICE=$(whiptail --title "Web3 Pi UPS Configuration" \
            --menu "Shutdown Threshold: ${CURRENT_SHUTDOWN}% | Log: $CURRENT_LOG" \
            $TERM_HEIGHT $TERM_WIDTH 6 \
            "1" "Shutdown Threshold ($CURRENT_SHUTDOWN%)" \
            "2" "Log Level ($CURRENT_LOG)" \
            "3" "Edit Shutdown Script" \
            "4" "Edit Config File (nano)" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_ups_config_shutdown_threshold ;;
            2) system_ups_config_log_level ;;
            3) system_ups_config_shutdown_script ;;
            4) system_ups_config_edit_raw ;;
            0|"") return ;;
        esac
    done
}

system_ups_config_serial_port() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "serial" "port")

    NEW_VALUE=$(input_box "Serial Port" "Enter serial port for UPS communication:\n\nCommon values:\n  /dev/ttyACM0 (USB CDC)\n  /dev/ttyUSB0 (USB serial)" "$CURRENT")

    if [ -n "$NEW_VALUE" ] && [ "$NEW_VALUE" != "$CURRENT" ]; then
        system_ups_toml_set "$CONFIG_FILE" "serial" "port" "$NEW_VALUE" "true"
        msg_box "Success" "Serial port set to: $NEW_VALUE\n\nService will restart if running."
    fi
}

system_ups_config_baud_rate() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "serial" "baud_rate")

    NEW_VALUE=$(whiptail --title "Baud Rate" \
        --menu "Current: $CURRENT\n\nSelect baud rate:" 18 $TERM_WIDTH 6 \
        "9600" "9600 baud" \
        "19200" "19200 baud" \
        "38400" "38400 baud" \
        "57600" "57600 baud" \
        "115200" "115200 baud (default)" \
        "230400" "230400 baud" \
        3>&1 1>&2 2>&3)

    if [ -n "$NEW_VALUE" ] && [ "$NEW_VALUE" != "$CURRENT" ]; then
        system_ups_toml_set "$CONFIG_FILE" "serial" "baud_rate" "$NEW_VALUE" "false"
        msg_box "Success" "Baud rate set to: $NEW_VALUE"
    fi
}

system_ups_config_shutdown_threshold() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "battery" "shutdown_threshold")

    NEW_VALUE=$(input_box "Shutdown Threshold" "Enter battery percentage to trigger shutdown (0-100):\n\nWhen battery drops below this level, system will initiate safe shutdown.\n\nRecommended: 10-20%" "$CURRENT")

    if [ -n "$NEW_VALUE" ]; then
        # Validate numeric input 0-100
        if [[ "$NEW_VALUE" =~ ^[0-9]+$ ]] && [ "$NEW_VALUE" -ge 0 ] && [ "$NEW_VALUE" -le 100 ]; then
            if [ "$NEW_VALUE" != "$CURRENT" ]; then
                system_ups_toml_set "$CONFIG_FILE" "battery" "shutdown_threshold" "$NEW_VALUE" "false"
                msg_box "Success" "Shutdown threshold set to: ${NEW_VALUE}%"
            fi
        else
            msg_box "Error" "Invalid value. Enter a number between 0 and 100."
        fi
    fi
}

system_ups_config_shutdown_margin() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "battery" "shutdown_cancel_margin")

    NEW_VALUE=$(input_box "Shutdown Cancel Margin" "Enter margin to cancel pending shutdown (0-50%):\n\nIf battery rises above (threshold + margin), shutdown is cancelled.\n\nExample: threshold=10, margin=5 -> cancel at 15%\n\nDefault: 5%" "$CURRENT")

    if [ -n "$NEW_VALUE" ]; then
        if [[ "$NEW_VALUE" =~ ^[0-9]+$ ]] && [ "$NEW_VALUE" -ge 0 ] && [ "$NEW_VALUE" -le 50 ]; then
            if [ "$NEW_VALUE" != "$CURRENT" ]; then
                system_ups_toml_set "$CONFIG_FILE" "battery" "shutdown_cancel_margin" "$NEW_VALUE" "false"
                msg_box "Success" "Shutdown cancel margin set to: ${NEW_VALUE}%"
            fi
        else
            msg_box "Error" "Invalid value. Enter a number between 0 and 50."
        fi
    fi
}

system_ups_config_min_voltage() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "battery" "min_valid_voltage")

    NEW_VALUE=$(input_box "Minimum Valid Voltage" "Enter minimum valid voltage in millivolts:\n\nVoltage readings below this value are ignored as invalid.\n\nDefault: 8000 (8V)" "$CURRENT")

    if [ -n "$NEW_VALUE" ]; then
        if [[ "$NEW_VALUE" =~ ^[0-9]+$ ]]; then
            if [ "$NEW_VALUE" != "$CURRENT" ]; then
                system_ups_toml_set "$CONFIG_FILE" "battery" "min_valid_voltage" "$NEW_VALUE" "false"
                msg_box "Success" "Minimum valid voltage set to: ${NEW_VALUE} mV"
            fi
        else
            msg_box "Error" "Invalid value. Enter a positive number."
        fi
    fi
}

system_ups_config_max_voltage() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "battery" "max_valid_voltage")

    NEW_VALUE=$(input_box "Maximum Valid Voltage" "Enter maximum valid voltage in millivolts:\n\nVoltage readings above this value are ignored as invalid.\n\nDefault: 26000 (26V)" "$CURRENT")

    if [ -n "$NEW_VALUE" ]; then
        if [[ "$NEW_VALUE" =~ ^[0-9]+$ ]]; then
            if [ "$NEW_VALUE" != "$CURRENT" ]; then
                system_ups_toml_set "$CONFIG_FILE" "battery" "max_valid_voltage" "$NEW_VALUE" "false"
                msg_box "Success" "Maximum valid voltage set to: ${NEW_VALUE} mV"
            fi
        else
            msg_box "Error" "Invalid value. Enter a positive number."
        fi
    fi
}

system_ups_config_shutdown_delay() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "shutdown" "delay_seconds")

    NEW_VALUE=$(input_box "Shutdown Delay" "Enter delay before shutdown in seconds:\n\nAfter battery drops below threshold, system waits this long before shutdown.\n\nDefault: 30 seconds" "$CURRENT")

    if [ -n "$NEW_VALUE" ]; then
        if [[ "$NEW_VALUE" =~ ^[0-9]+$ ]] && [ "$NEW_VALUE" -ge 0 ]; then
            if [ "$NEW_VALUE" != "$CURRENT" ]; then
                system_ups_toml_set "$CONFIG_FILE" "shutdown" "delay_seconds" "$NEW_VALUE" "false"
                msg_box "Success" "Shutdown delay set to: ${NEW_VALUE} seconds"
            fi
        else
            msg_box "Error" "Invalid value. Enter a non-negative number."
        fi
    fi
}

system_ups_config_log_level() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local CURRENT=$(system_ups_toml_get "$CONFIG_FILE" "logging" "level")

    NEW_VALUE=$(whiptail --title "Log Level" \
        --menu "Current: $CURRENT\n\nSelect logging level:" 16 $TERM_WIDTH 5 \
        "error" "Errors only" \
        "warn" "Warnings and errors" \
        "info" "Info, warnings, and errors (default)" \
        "debug" "Debug (verbose)" \
        "trace" "Trace (very verbose)" \
        3>&1 1>&2 2>&3)

    if [ -n "$NEW_VALUE" ] && [ "$NEW_VALUE" != "$CURRENT" ]; then
        system_ups_toml_set "$CONFIG_FILE" "logging" "level" "$NEW_VALUE" "true"
        msg_box "Success" "Log level set to: $NEW_VALUE"
    fi
}

system_ups_config_shutdown_script() {
    local SCRIPT_FILE="/etc/w3p-ups/shutdown.sh"

    if [ ! -f "$SCRIPT_FILE" ]; then
        msg_box "Not Found" "Shutdown script not found:\n$SCRIPT_FILE\n\nPlease install Web3 Pi UPS first."
        return
    fi

    if yesno_box "Edit Shutdown Script" "Edit the shutdown script?\n\nThis script is executed when battery reaches shutdown threshold.\n\nFile: $SCRIPT_FILE\n\nEditor: nano (Ctrl+X to exit)"; then
        clear
        nano "$SCRIPT_FILE"
    fi
}

system_ups_config_edit_raw() {
    local CONFIG_FILE="/etc/w3p-ups/config.toml"

    if [ ! -f "$CONFIG_FILE" ]; then
        msg_box "Not Found" "Configuration file not found:\n$CONFIG_FILE"
        return
    fi

    if yesno_box "Edit Configuration" "Edit the raw configuration file?\n\nFile: $CONFIG_FILE\n\nEditor: nano (Ctrl+X to exit)\n\nService will restart after editing."; then
        clear
        nano "$CONFIG_FILE"

        # Restart service if running
        if systemctl is-active w3p-ups &>/dev/null; then
            systemctl restart w3p-ups
            msg_box "Service Restarted" "Configuration saved and service restarted."
        fi
    fi
}

system_ups_status() {
    if [ ! -f /usr/local/bin/w3p-ups ]; then
        msg_box "Not Installed" "Web3 Pi UPS is not installed."
        return
    fi

    local CONFIG_FILE="/etc/w3p-ups/config.toml"
    local SERVICE_STATUS=$(systemctl is-active w3p-ups 2>/dev/null || echo "inactive")

    # Get latest status from logs
    local LATEST_LOG=$(journalctl -u w3p-ups -n 50 --no-pager 2>/dev/null)

    # Parse battery info from logs (look for status line)
    local BATTERY_SOC=$(echo "$LATEST_LOG" | grep -oP 'soc[=:]\s*\K[0-9]+' | tail -1)
    local INPUT_VOLTAGE=$(echo "$LATEST_LOG" | grep -oP 'vi[=:]\s*\K[0-9]+' | tail -1)
    local BATTERY_VOLTAGE=$(echo "$LATEST_LOG" | grep -oP 'bv[=:]\s*\K[0-9]+' | tail -1)
    local BATTERY_CURRENT=$(echo "$LATEST_LOG" | grep -oP 'ba[=:]\s*\K-?[0-9]+' | tail -1)

    # Determine power source
    local POWER_SOURCE="Unknown"
    local MIN_VOLTAGE=$(system_ups_toml_get "$CONFIG_FILE" "battery" "min_valid_voltage")
    if [ -n "$INPUT_VOLTAGE" ] && [ -n "$MIN_VOLTAGE" ]; then
        if [ "$INPUT_VOLTAGE" -ge "$MIN_VOLTAGE" ]; then
            POWER_SOURCE="Grid Power"
        else
            POWER_SOURCE="Battery"
        fi
    fi

    INFO="===============================================================\n"
    INFO+="                  WEB3 PI UPS STATUS\n"
    INFO+="===============================================================\n\n"

    # Battery status (most important - at top)
    INFO+="  BATTERY\n"
    INFO+="---------------------------------------------------------------\n"
    if [ -n "$BATTERY_SOC" ]; then
        INFO+="  Charge Level:     ${BATTERY_SOC}%\n"
    else
        INFO+="  Charge Level:     N/A\n"
    fi
    INFO+="  Power Source:     $POWER_SOURCE\n"
    if [ -n "$INPUT_VOLTAGE" ]; then
        local IV_VOLTS=$(echo "scale=2; $INPUT_VOLTAGE / 1000" | bc 2>/dev/null || echo "$INPUT_VOLTAGE mV")
        INFO+="  Input Voltage:    ${IV_VOLTS}V\n"
    else
        INFO+="  Input Voltage:    N/A\n"
    fi
    if [ -n "$BATTERY_VOLTAGE" ]; then
        local BV_VOLTS=$(echo "scale=2; $BATTERY_VOLTAGE / 1000" | bc 2>/dev/null || echo "$BATTERY_VOLTAGE mV")
        INFO+="  Battery Voltage:  ${BV_VOLTS}V\n"
    fi

    # Service status
    INFO+="\n  SERVICE\n"
    INFO+="---------------------------------------------------------------\n"
    local ENABLED_STATUS=$(systemctl is-enabled w3p-ups 2>/dev/null || echo "disabled")
    if [ "$SERVICE_STATUS" = "active" ]; then
        INFO+="  Status:           Running\n"
    else
        INFO+="  Status:           $SERVICE_STATUS\n"
    fi
    INFO+="  Start on boot:    $ENABLED_STATUS\n"

    # Hardware
    local PORT=$(system_ups_toml_get "$CONFIG_FILE" "serial" "port")
    INFO+="\n  HARDWARE\n"
    INFO+="---------------------------------------------------------------\n"
    if [ -e "$PORT" ]; then
        INFO+="  Serial port:      $PORT (connected)\n"
    else
        INFO+="  Serial port:      $PORT (NOT FOUND)\n"
    fi

    # Configuration summary
    INFO+="\n  CONFIGURATION\n"
    INFO+="---------------------------------------------------------------\n"
    INFO+="  Shutdown at:      $(system_ups_toml_get "$CONFIG_FILE" "battery" "shutdown_threshold")%\n"

    whiptail --title "Web3 Pi UPS Status" --scrolltext --msgbox "$INFO" 26 $TERM_WIDTH
}

system_ups_logs() {
    if [ ! -f /usr/local/bin/w3p-ups ]; then
        msg_box "Not Installed" "Web3 Pi UPS is not installed."
        return
    fi

    CHOICE=$(whiptail --title "Web3 Pi UPS Logs" \
        --menu "View service logs:" $TERM_HEIGHT $TERM_WIDTH 6 \
        "1" "Last 50 lines" \
        "2" "Last 100 lines" \
        "3" "Last 200 lines" \
        "4" "Follow logs (live)" \
        "0" "Back" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) clear; journalctl -u w3p-ups -n 50 --no-pager; read -p "Press Enter to continue..." ;;
        2) clear; journalctl -u w3p-ups -n 100 --no-pager; read -p "Press Enter to continue..." ;;
        3) clear; journalctl -u w3p-ups -n 200 --no-pager; read -p "Press Enter to continue..." ;;
        4)
            clear
            echo "Following Web3 Pi UPS logs (Ctrl+C to exit)..."
            echo ""
            journalctl -u w3p-ups -f
            ;;
    esac
}

system_ups_about() {
    local INSTALLED_VERSION="(not installed)"
    if [ -x /usr/local/bin/w3p-ups ]; then
        INSTALLED_VERSION=$(/usr/local/bin/w3p-ups --version 2>/dev/null | head -1 | awk '{print $2}')
        [ -z "$INSTALLED_VERSION" ] && INSTALLED_VERSION="(unknown)"
    fi

    INFO="===============================================================\n"
    INFO+="                    WEB3 PI UPS\n"
    INFO+="===============================================================\n\n"
    INFO+="Installed version: ${INSTALLED_VERSION}\n\n"
    INFO+="A battery monitoring and safe shutdown agent for Raspberry Pi\n"
    INFO+="with Web3 Pi UPS hardware.\n\n"
    INFO+="Features:\n"
    INFO+="  - Real-time battery voltage monitoring\n"
    INFO+="  - Automatic safe shutdown on low battery\n"
    INFO+="  - Configurable shutdown thresholds\n"
    INFO+="  - Customizable shutdown script\n"
    INFO+="  - Live UPS data view (CLI + control-panel)\n"
    INFO+="  - Protection for Ethereum validator keys\n\n"
    INFO+="Configuration:\n"
    INFO+="  - Config file:     /etc/w3p-ups/config.toml\n"
    INFO+="  - Shutdown script: /etc/w3p-ups/shutdown.sh\n"
    INFO+="  - IPC socket:      /run/w3p-ups/agent.sock\n"
    INFO+="  - Service:         w3p-ups.service\n\n"
    INFO+="Source: github.com/Web3-Pi/Web3-Pi-UPS-Service\n"

    msg_box "About Web3 Pi UPS" "$INFO"
}

# =============================================================================
# Auto OC Detection Functions
# =============================================================================

system_auto_oc_menu() {
    local OC_CONFIG="/opt/web3pi/oc-config"

    while true; do
        # Read current OC status
        local DETECTED_FREQ="Not detected"
        local DETECT_DATE="Never"
        local CURRENT_FREQ="N/A"
        local HW_MAX="N/A"

        if [ -f "$OC_CONFIG" ]; then
            source "$OC_CONFIG"
            if [ -n "${OC_DETECTED_MAX_FREQ:-}" ] && [ "$OC_DETECTED_MAX_FREQ" -gt 0 ] 2>/dev/null; then
                DETECTED_FREQ="$((OC_DETECTED_MAX_FREQ / 1000)) MHz"
            fi
            DETECT_DATE="${OC_DETECT_DATE:-Never}"
        fi

        CURRENT_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
        if [ -n "$CURRENT_FREQ" ]; then
            CURRENT_FREQ="$((CURRENT_FREQ / 1000)) MHz"
        fi

        HW_MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
        if [ -n "$HW_MAX" ]; then
            HW_MAX="$((HW_MAX / 1000)) MHz"
        fi

        # Read scan range settings
        local OC_SETTINGS="/opt/web3pi/oc-settings"
        local SCAN_START=2400
        local SCAN_END=3200
        if [ -f "$OC_SETTINGS" ]; then
            source "$OC_SETTINGS"
            [ -n "${OC_SCAN_START:-}" ] && SCAN_START=$((OC_SCAN_START / 1000))
            [ -n "${OC_SCAN_END:-}" ] && SCAN_END=$((OC_SCAN_END / 1000))
        fi

        CHOICE=$(whiptail --title "Auto OC Detection" \
            --menu "Detected Max: $DETECTED_FREQ | Current: $CURRENT_FREQ\nHW Ceiling: $HW_MAX | Last Run: $DETECT_DATE\nScan Range: ${SCAN_START} - ${SCAN_END} MHz" \
            $TERM_HEIGHT $TERM_WIDTH 8 \
            "1" "Run Auto OC Detection" \
            "2" "View Last Results" \
            "3" "View Detection Log" \
            "4" "Settings (range: ${SCAN_START}-${SCAN_END} MHz)" \
            "5" "Reset to Stock (2400 MHz)" \
            "6" "About" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_auto_oc_run ;;
            2) system_auto_oc_results ;;
            3) system_auto_oc_log ;;
            4) system_auto_oc_settings ;;
            5) system_auto_oc_reset ;;
            6) system_auto_oc_about ;;
            0|"") return ;;
        esac
    done
}

system_auto_oc_settings() {
    local OC_SETTINGS="/opt/web3pi/oc-settings"

    # Read current settings
    local CURRENT_START=2400000
    local CURRENT_END=3200000
    if [ -f "$OC_SETTINGS" ]; then
        source "$OC_SETTINGS"
        [ -n "${OC_SCAN_START:-}" ] && CURRENT_START=$OC_SCAN_START
        [ -n "${OC_SCAN_END:-}" ] && CURRENT_END=$OC_SCAN_END
    fi

    while true; do
        CHOICE=$(whiptail --title "Auto OC Settings" \
            --menu "Start: $((CURRENT_START / 1000)) MHz | End: $((CURRENT_END / 1000)) MHz" \
            $TERM_HEIGHT $TERM_WIDTH 4 \
            "1" "Start Frequency ($((CURRENT_START / 1000)) MHz)" \
            "2" "End Frequency ($((CURRENT_END / 1000)) MHz)" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1)
                NEW_START=$(whiptail --title "Start Frequency" \
                    --menu "Start scanning from:" $TERM_HEIGHT $TERM_WIDTH 5 \
                    "2400000" "2400 MHz (stock)" \
                    "2500000" "2500 MHz" \
                    "2600000" "2600 MHz" \
                    "2700000" "2700 MHz" \
                    "2800000" "2800 MHz" \
                    3>&1 1>&2 2>&3)
                if [ -n "$NEW_START" ]; then
                    if [ "$NEW_START" -ge "$CURRENT_END" ]; then
                        msg_box "Error" "Start frequency must be lower than end frequency ($((CURRENT_END / 1000)) MHz)."
                    else
                        CURRENT_START=$NEW_START
                        cat > "$OC_SETTINGS" << EOF
# Web3 Pi - Auto OC Detection Settings
OC_SCAN_START=$CURRENT_START
OC_SCAN_END=$CURRENT_END
EOF
                    fi
                fi
                ;;
            2)
                NEW_END=$(whiptail --title "End Frequency" \
                    --menu "Stop scanning at:" $TERM_HEIGHT $TERM_WIDTH 5 \
                    "2800000" "2800 MHz" \
                    "2900000" "2900 MHz" \
                    "3000000" "3000 MHz" \
                    "3100000" "3100 MHz" \
                    "3200000" "3200 MHz" \
                    3>&1 1>&2 2>&3)
                if [ -n "$NEW_END" ]; then
                    if [ "$NEW_END" -le "$CURRENT_START" ]; then
                        msg_box "Error" "End frequency must be higher than start frequency ($((CURRENT_START / 1000)) MHz)."
                    else
                        CURRENT_END=$NEW_END
                        cat > "$OC_SETTINGS" << EOF
# Web3 Pi - Auto OC Detection Settings
OC_SCAN_START=$CURRENT_START
OC_SCAN_END=$CURRENT_END
EOF
                    fi
                fi
                ;;
            0|"") return ;;
        esac
    done
}

system_auto_oc_run() {
    # Check if detection script exists
    if [ ! -x /opt/web3pi/auto-oc-detect.sh ]; then
        msg_box "Error" "auto-oc-detect.sh not found or not executable."
        return
    fi

    # Check if already running
    if [ -f /tmp/auto-oc-detect.lock ]; then
        if ! flock -n /tmp/auto-oc-detect.lock true 2>/dev/null; then
            msg_box "Already Running" "An OC detection is already in progress.\n\nPlease wait for it to complete."
            return
        fi
    fi

    # Read scan range settings
    local OC_SETTINGS="/opt/web3pi/oc-settings"
    local SCAN_START=2400000
    local SCAN_END=3200000
    if [ -f "$OC_SETTINGS" ]; then
        source "$OC_SETTINGS"
        [ -n "${OC_SCAN_START:-}" ] && SCAN_START=$OC_SCAN_START
        [ -n "${OC_SCAN_END:-}" ] && SCAN_END=$OC_SCAN_END
    fi
    local SCAN_START_MHZ=$((SCAN_START / 1000))
    local SCAN_END_MHZ=$((SCAN_END / 1000))

    local NUM_STEPS_DLG=$(( (SCAN_END - SCAN_START) / 100000 + 1 ))
    local EST_MIN_DLG=$(( NUM_STEPS_DLG * 3 + 5 ))

    if ! yesno_box "Run Auto OC Detection" \
        "This will test CPU frequencies from ${SCAN_START_MHZ} to ${SCAN_END_MHZ} MHz\n(${NUM_STEPS_DLG} steps, ~${EST_MIN_DLG} min total)\nusing NEON/SIMD stress tests (3 min per step),\nfollowed by a 5-minute confirmation at the max stable freq.\n\nChange range in Settings before running.\n\nREQUIREMENTS:\n- Active cooling MUST be working\n- Official 5.1V 5A power supply\n- No heavy workloads running\n\nThe system remains safe at all times.\n\nProceed?"; then
        return
    fi

    # Warn about running Ethereum services
    local SERVICES_RUNNING=""
    if systemctl is-active --quiet geth 2>/dev/null; then
        SERVICES_RUNNING+="  - Geth (Execution Layer)\n"
    fi
    if systemctl is-active --quiet nimbus-beacon-node 2>/dev/null; then
        SERVICES_RUNNING+="  - Nimbus Beacon Node\n"
    fi

    if [ -n "$SERVICES_RUNNING" ]; then
        if ! yesno_box "Services Running" \
            "These services are currently running:\n\n${SERVICES_RUNNING}\nRunning OC detection alongside them\nmay give less accurate results.\n\nRecommendation: Stop services first.\n\nContinue anyway?"; then
            return
        fi
    fi

    local NUM_STEPS=$(( (SCAN_END - SCAN_START) / 100000 + 1 ))
    local EST_MINUTES=$(( NUM_STEPS * 3 + 5 ))

    clear
    echo "==============================================================="
    echo "         AUTO OVERCLOCK DETECTION"
    echo "==============================================================="
    echo ""
    echo "Testing frequencies: ${SCAN_START_MHZ} - ${SCAN_END_MHZ} MHz (NEON stress, 3 min/step)"
    echo "Steps: ${NUM_STEPS}, estimated time: ~${EST_MINUTES} min (incl. 5 min confirmation)"
    echo ""
    echo "Press Ctrl+C to abort safely (frequency will be restored)"
    echo ""
    echo "---------------------------------------------------------------"
    echo ""

    /opt/web3pi/auto-oc-detect.sh --start "$SCAN_START" --end "$SCAN_END" 2>&1

    echo ""
    echo "==============================================================="
    echo "  Detection complete."
    echo "  Reboot to apply the detected frequency."
    echo "==============================================================="
    echo ""

    read -p "Press Enter to continue..."
}

system_auto_oc_results() {
    local OC_CONFIG="/opt/web3pi/oc-config"

    if [ ! -f "$OC_CONFIG" ]; then
        msg_box "No Results" "No OC detection has been run yet.\n\nUse 'Run Auto OC Detection' first."
        return
    fi

    source "$OC_CONFIG"

    INFO="===============================================================\n"
    INFO+="            AUTO OC DETECTION RESULTS\n"
    INFO+="===============================================================\n\n"
    INFO+="  DETECTED MAXIMUM STABLE FREQUENCY\n"
    INFO+="---------------------------------------------------------------\n"
    if [ -n "${OC_DETECTED_MAX_FREQ:-}" ] && [ "$OC_DETECTED_MAX_FREQ" -gt 0 ] 2>/dev/null; then
        INFO+="  Max Stable:   $((OC_DETECTED_MAX_FREQ / 1000)) MHz\n"
    else
        INFO+="  Max Stable:   Not determined (using stock 2400 MHz)\n"
    fi
    INFO+="\n  DETECTION PARAMETERS\n"
    INFO+="---------------------------------------------------------------\n"
    INFO+="  Range:        $((${OC_DETECT_START:-0} / 1000)) - $((${OC_DETECT_END:-0} / 1000)) MHz\n"
    INFO+="  Step size:    $((${OC_DETECT_STEP:-0} / 1000)) MHz\n"
    INFO+="  Stress time:  ${OC_DETECT_STRESS_DURATION:-N/A} sec/step\n"
    INFO+="  Confirm time: ${OC_DETECT_CONFIRM_DURATION:-N/A} sec\n"
    INFO+="  Confirmed:    $([ "${OC_DETECT_CONFIRM_PASSED:-false}" = "true" ] && echo "YES" || echo "NO")\n"
    INFO+="  Max temp:     ${OC_DETECT_MAX_TEMP:-N/A}C\n"
    INFO+="  HW ceiling:   $((${OC_DETECT_HW_MAX:-0} / 1000)) MHz\n"
    INFO+="  Run date:     ${OC_DETECT_DATE:-N/A}\n"
    INFO+="\n  CURRENT STATUS\n"
    INFO+="---------------------------------------------------------------\n"
    local CUR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
    local MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "0")
    local GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    INFO+="  Current freq: $((CUR / 1000)) MHz\n"
    INFO+="  Max allowed:  $((MAX / 1000)) MHz\n"
    INFO+="  Governor:     ${GOV}\n"

    whiptail --title "Auto OC Detection Results" --scrolltext --msgbox "$INFO" 26 $TERM_WIDTH
}

system_auto_oc_log() {
    local OC_LOG="/opt/web3pi/logs/auto-oc-detect.log"

    if [ ! -f "$OC_LOG" ]; then
        msg_box "No Log" "No detection log found.\n\nRun a detection first."
        return
    fi

    CHOICE=$(whiptail --title "Detection Log" \
        --menu "View detection log:" $TERM_HEIGHT $TERM_WIDTH 4 \
        "1" "Last 50 lines" \
        "2" "Full log (less)" \
        "0" "Back" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1)
            clear
            tail -50 "$OC_LOG"
            echo ""
            read -p "Press Enter to continue..."
            ;;
        2)
            less "$OC_LOG"
            ;;
    esac
}

system_auto_oc_reset() {
    if ! yesno_box "Reset to Stock" \
        "Reset CPU frequency to stock 2400 MHz?\n\nThis will:\n- Set detected max to 2400 MHz\n- Update the OC config file\n- Take effect on next reboot\n\nContinue?"; then
        return
    fi

    cat > /opt/web3pi/oc-config << EOF
# Web3 Pi - Auto OC Detection Results
# Reset to stock: $(date '+%Y-%m-%d %H:%M:%S')
OC_DETECTED_MAX_FREQ=2400000
OC_DETECT_DATE="$(date '+%Y-%m-%d %H:%M:%S') (manual reset)"
EOF

    msg_box "Reset Complete" "CPU frequency reset to stock 2400 MHz.\n\nReboot to apply."
}

system_auto_oc_about() {
    INFO="===============================================================\n"
    INFO+="               AUTO OC DETECTION\n"
    INFO+="===============================================================\n\n"
    INFO+="Automatically discovers the maximum stable CPU overclock\n"
    INFO+="for your specific Raspberry Pi 5.\n\n"
    INFO+="How it works:\n"
    INFO+="  1. config.txt sets a high HW ceiling (3200 MHz)\n"
    INFO+="  2. cpu-freq-safe.service clamps to safe freq at boot\n"
    INFO+="  3. Detection raises freq in 100/50 MHz steps\n"
    INFO+="  4. Each step: 3-min NEON/SIMD stress + throttle check\n"
    INFO+="  5. If stable: move to next step\n"
    INFO+="  6. If unstable: previous step is the max candidate\n"
    INFO+="  7. 5-min confirmation test at detected max\n"
    INFO+="  8. If confirmation fails: step down and retry\n"
    INFO+="  9. Result saved and applied on next reboot\n\n"
    INFO+="Safety:\n"
    INFO+="  - System always boots at safe frequency\n"
    INFO+="  - Detection can be interrupted safely (Ctrl+C)\n"
    INFO+="  - Frequency restored on any exit/error\n"
    INFO+="  - Temperature limit enforced (85C)\n"
    INFO+="  - Under-voltage detection\n\n"
    INFO+="Requirements:\n"
    INFO+="  - Active cooling (fan) must be working\n"
    INFO+="  - Official power supply (5.1V 5A)\n\n"
    INFO+="Files:\n"
    INFO+="  - Config: /opt/web3pi/oc-config\n"
    INFO+="  - Log:    /opt/web3pi/logs/auto-oc-detect.log\n"
    INFO+="  - Script: /opt/web3pi/auto-oc-detect.sh\n"

    msg_box "About Auto OC Detection" "$INFO"
}
