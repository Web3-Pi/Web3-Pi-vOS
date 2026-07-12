#!/bin/bash
#
# Web3 Pi Control Panel - LCD Display Module (w3p-hwm)
#
# Manage the Web3 Pi LCD dashboard: install/update from GitHub releases,
# start/stop/enable, logs and SPI status. Mirrors the Web3 Pi UPS module.
#

W3P_HWM_BIN="/usr/local/bin/w3p-hwm"
W3P_HWM_SERVICE="w3p-hwm.service"
W3P_HWM_UNIT_FILE="/etc/systemd/system/w3p-hwm.service"
W3P_HWM_INSTALL_URL="https://raw.githubusercontent.com/Web3-Pi/web3-pi-lcd/main/install.sh"

system_lcd_menu() {
    while true; do
        local INSTALLED="No"
        local SERVICE_STATUS="N/A"
        local ENABLED_STATUS="N/A"

        if [ -f "$W3P_HWM_BIN" ]; then
            INSTALLED="Yes"
            SERVICE_STATUS=$(systemctl is-active "$W3P_HWM_SERVICE" 2>/dev/null || echo "inactive")
            ENABLED_STATUS=$(systemctl is-enabled "$W3P_HWM_SERVICE" 2>/dev/null || echo "disabled")
        fi

        CHOICE=$(whiptail --title "LCD Display (w3p-hwm)" \
            --menu "Installed: $INSTALLED | Service: $SERVICE_STATUS | Boot: $ENABLED_STATUS" \
            $TERM_HEIGHT $TERM_WIDTH 9 \
            "1" "Install / Update" \
            "2" "Uninstall" \
            "3" "Service Control" \
            "4" "View Logs" \
            "5" "SPI Status" \
            "6" "About" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) system_lcd_install ;;
            2) system_lcd_uninstall ;;
            3) system_lcd_service_control ;;
            4) system_lcd_logs ;;
            5) system_lcd_spi_status ;;
            6) system_lcd_about ;;
            0|"") return ;;
        esac
    done
}

system_lcd_install() {
    if [ -f "$W3P_HWM_BIN" ]; then
        if ! yesno_box "Already Installed" "The LCD dashboard is already installed.\n\nUpdate to the latest release?"; then
            return
        fi
    fi

    if ! yesno_box "Install / Update LCD Dashboard" "This downloads the latest w3p-hwm release from GitHub, installs the service and (re)starts it.\n\nSource: github.com/Web3-Pi/web3-pi-lcd\n\nAssets are embedded in the binary. SPI is enabled if not already.\n\nContinue?"; then
        return
    fi

    clear
    echo "==============================================================="
    echo "        INSTALLING WEB3 PI LCD DASHBOARD (w3p-hwm)"
    echo "==============================================================="
    echo ""
    if curl -fsSL "$W3P_HWM_INSTALL_URL" | bash; then
        echo ""
        echo "==============================================================="
        echo "  Done. If SPI was just enabled, a REBOOT is required."
        echo "==============================================================="
    else
        echo ""
        echo "==============================================================="
        echo "  Installation failed. Check the output above."
        echo "==============================================================="
    fi
    echo ""
    read -p "Press Enter to continue..."
}

system_lcd_uninstall() {
    if [ ! -f "$W3P_HWM_BIN" ]; then
        msg_box "Not Installed" "The LCD dashboard is not installed."
        return
    fi

    if ! yesno_box "Uninstall LCD Dashboard" "Stop and remove the w3p-hwm service and binary.\n\nSPI stays enabled in config.txt.\n\nContinue?"; then
        return
    fi

    systemctl disable --now "$W3P_HWM_SERVICE" 2>/dev/null || true
    rm -f "$W3P_HWM_BIN" "$W3P_HWM_UNIT_FILE"
    systemctl daemon-reload
    msg_box "Uninstalled" "The LCD dashboard has been removed."
}

system_lcd_service_control() {
    if [ ! -f "$W3P_HWM_BIN" ]; then
        msg_box "Not Installed" "The LCD dashboard is not installed."
        return
    fi

    while true; do
        local S E
        S=$(systemctl is-active "$W3P_HWM_SERVICE" 2>/dev/null || echo "inactive")
        E=$(systemctl is-enabled "$W3P_HWM_SERVICE" 2>/dev/null || echo "disabled")

        CHOICE=$(whiptail --title "LCD Service Control" \
            --menu "Service: $S | Boot: $E" \
            $TERM_HEIGHT $TERM_WIDTH 8 \
            "1" "Start" \
            "2" "Stop" \
            "3" "Restart" \
            "4" "Enable at boot" \
            "5" "Disable at boot" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) systemctl start "$W3P_HWM_SERVICE" && msg_box "LCD" "Service started." || msg_box "LCD" "Start failed." ;;
            2) systemctl stop "$W3P_HWM_SERVICE" && msg_box "LCD" "Service stopped." || msg_box "LCD" "Stop failed." ;;
            3) systemctl restart "$W3P_HWM_SERVICE" && msg_box "LCD" "Service restarted." || msg_box "LCD" "Restart failed." ;;
            4) systemctl enable "$W3P_HWM_SERVICE" 2>/dev/null && msg_box "LCD" "Enabled at boot." ;;
            5) systemctl disable "$W3P_HWM_SERVICE" 2>/dev/null && msg_box "LCD" "Disabled at boot." ;;
            0|"") return ;;
        esac
    done
}

system_lcd_logs() {
    if [ ! -f "$W3P_HWM_BIN" ]; then
        msg_box "Not Installed" "The LCD dashboard is not installed."
        return
    fi
    clear
    echo "==============================================================="
    echo "  LCD DASHBOARD LOGS (last 200 lines)"
    echo "==============================================================="
    echo ""
    journalctl -u "$W3P_HWM_SERVICE" -n 200 --no-pager 2>&1
    echo ""
    read -p "Press Enter to return to the menu..."
}

system_lcd_spi_status() {
    local dev="absent (/dev/spidev0.0 not found)"
    local cfg="not set"
    local d
    for d in /dev/spidev0.0 /dev/spidev0.1; do
        [ -e "$d" ] && dev="$d present"
    done
    if grep -Eq '^[[:space:]]*dtparam[[:space:]]*=[[:space:]]*spi[[:space:]]*=[[:space:]]*on([[:space:]]*(,|$))' /boot/firmware/config.txt 2>/dev/null; then
        cfg="enabled in config.txt"
    fi
    msg_box "SPI Status" "Header SPI device: $dev\nBoot config:       $cfg\n\nThe LCD needs /dev/spidev0.0. If SPI was just enabled in config.txt, reboot for the device node to appear."
}

system_lcd_about() {
    msg_box "LCD Display (w3p-hwm)" "Web3 Pi LCD dashboard for the 1.69\" ST7789V2 SPI panel.\n\nSingle self-contained binary — font, logos and animation are embedded. A missing or unwired panel is non-fatal: the service stays active and renders as soon as a panel is present.\n\nSource:  github.com/Web3-Pi/web3-pi-lcd\nBinary:  /usr/local/bin/w3p-hwm\nService: w3p-hwm.service"
}
