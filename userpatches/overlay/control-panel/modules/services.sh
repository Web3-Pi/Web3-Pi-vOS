#!/bin/bash
#
# Web3 Pi Control Panel - Service Management Module
#

service_menu() {
    while true; do
        # Get service statuses
        GETH_STATUS=$(systemctl is-active geth 2>/dev/null || echo "inactive")
        NIMBUS_BN_STATUS=$(systemctl is-active nimbus-beacon-node 2>/dev/null || echo "inactive")
        NIMBUS_VC_STATUS=$(systemctl is-active nimbus-validator 2>/dev/null || echo "inactive")

        CHOICE=$(whiptail --title "Service Management" \
            --menu "Geth: $GETH_STATUS | Beacon: $NIMBUS_BN_STATUS | Validator: $NIMBUS_VC_STATUS" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Geth (Execution Layer)" \
            "2" "Nimbus Beacon Node (Consensus Layer)" \
            "3" "Nimbus Validator" \
            "4" "View Logs" \
            "5" "Start All Services" \
            "6" "Stop All Services" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) service_control "geth" "Geth" ;;
            2) service_control "nimbus-beacon-node" "Nimbus Beacon Node" ;;
            3) service_control "nimbus-validator" "Nimbus Validator" ;;
            4) service_logs ;;
            5)
                systemctl start geth nimbus-beacon-node
                msg_box "Services Started" "Geth and Nimbus Beacon Node started."
                ;;
            6)
                systemctl stop nimbus-validator nimbus-beacon-node geth 2>/dev/null
                msg_box "Services Stopped" "All services stopped."
                ;;
            0|"") return ;;
        esac
    done
}

service_control() {
    SERVICE=$1
    NAME=$2

    while true; do
        STATUS=$(systemctl is-active $SERVICE 2>/dev/null || echo "inactive")
        ENABLED=$(systemctl is-enabled $SERVICE 2>/dev/null || echo "disabled")

        CHOICE=$(whiptail --title "$NAME" \
            --menu "Status: $STATUS | Boot: $ENABLED" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Start" \
            "2" "Stop" \
            "3" "Restart" \
            "4" "Enable (start on boot)" \
            "5" "Disable (don't start on boot)" \
            "6" "View Status" \
            "0" "Back" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) systemctl start $SERVICE && msg_box "Success" "$NAME started." ;;
            2) systemctl stop $SERVICE && msg_box "Success" "$NAME stopped." ;;
            3) systemctl restart $SERVICE && msg_box "Success" "$NAME restarted." ;;
            4) systemctl enable $SERVICE && msg_box "Success" "$NAME enabled." ;;
            5) systemctl disable $SERVICE && msg_box "Success" "$NAME disabled." ;;
            6)
                STATUS_OUT=$(systemctl status $SERVICE 2>&1 | head -20)
                whiptail --title "$NAME Status" --scrolltext --msgbox "$STATUS_OUT" $TERM_HEIGHT $TERM_WIDTH
                ;;
            0|"") return ;;
        esac
    done
}

service_logs() {
    CHOICE=$(whiptail --title "View Logs" \
        --menu "Select service:" $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
        "1" "Geth" \
        "2" "Nimbus Beacon Node" \
        "3" "Nimbus Validator" \
        "0" "Back" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) clear; journalctl -u geth -n 100 --no-pager; read -p "Press Enter to continue..." ;;
        2) clear; journalctl -u nimbus-beacon-node -n 100 --no-pager; read -p "Press Enter to continue..." ;;
        3) clear; journalctl -u nimbus-validator -n 100 --no-pager; read -p "Press Enter to continue..." ;;
    esac
}
