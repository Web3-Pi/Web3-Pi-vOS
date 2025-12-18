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
