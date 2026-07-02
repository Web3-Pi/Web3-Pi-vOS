#!/bin/bash
#
# Web3 Pi Control Panel - Internet Failover Module (M5)
# Ethernet -> WiFi -> USB LTE ladder; watchdog = w3p-failover.service.
# Settings live in /etc/w3p-failover.conf (root:600, sourced by a root
# daemon — deliberately NOT under the ethereum-writable /opt/web3pi, and
# NOT in the main config which save_config rewrites from a template).
#

FAILOVER_CONF=/etc/w3p-failover.conf
FAILOVER_STATUS=/run/w3p-failover/status.json
WIFI_NETPLAN=/etc/netplan/30-w3p-wifi.yaml

failover_menu() {
    local state CHOICE
    while true; do
        state="disabled"
        systemctl is-enabled -q w3p-failover 2>/dev/null && state="enabled"
        systemctl is-active -q w3p-failover 2>/dev/null && state="$state, running"
        CHOICE=$(whiptail --title "Internet Failover (LTE)" \
            --menu "Watchdog: $state" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Enable & start failover" \
            "2" "Disable & stop failover" \
            "3" "Live status (links, active WAN)" \
            "4" "Modem info (signal, SIM, network)" \
            "5" "WiFi backup link setup" \
            "6" "Data usage (LTE)" \
            "7" "Edit failover settings" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) systemctl enable --now w3p-failover \
                   && msg_box "Failover" "Watchdog enabled and started." \
                   || msg_box "Failover" "FAILED to start — check: journalctl -u w3p-failover" ;;
            2) systemctl disable --now w3p-failover
               # daemon sweeps its override/qdisc/masks on stop (trap +
               # ExecStopPost) — verify and tell the truth either way
               if ip route show default metric 50 2>/dev/null | grep -q .; then
                   msg_box "Failover" "Watchdog stopped, but an override route is still present:\n$(ip route show default metric 50)\nRemove with: ip route del default metric 50"
               else
                   msg_box "Failover" "Watchdog stopped and disabled.\nBaseline metric ladder stays active (cable-pull failover still works)."
               fi ;;
            3) failover_status ;;
            4) failover_modem_info ;;
            5) failover_wifi_setup ;;
            6) failover_data_usage ;;
            7) ${EDITOR:-nano} "$FAILOVER_CONF"
               systemctl is-active -q w3p-failover 2>/dev/null \
                   && yesno_box "Failover" "Restart the watchdog to apply the new settings?" \
                   && systemctl restart w3p-failover ;;
            0|"") return ;;
        esac
    done
}

failover_lte_dev() {
    local d dev=""
    for d in /sys/class/net/*; do
        case "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)" in
            cdc_ether|rndis_host) dev=$(basename "$d") ;;
        esac
    done
    echo "$dev"
}

failover_status() {
    local txt=""
    if [ -r "$FAILOVER_STATUS" ]; then
        txt=$(jq -r '
            (if .latched then "!! FLAP CLAMP LATCHED until \(.latched_until | todate) !!\n" else "" end) +
            (if .all_down then "!! ALL LINKS DOWN !!\n" else "" end) +
            "Active WAN: \(.active)\nSwitches: \(.switches)  Escalated: \(.escalated)" +
            (if .verifying != "" then "  (verifying \(.verifying))" else "" end) + "\n\n" +
            (.links | to_entries | map("\(.key):\t\(.value.if // "-")\t\(.value.health)\tip=\(.value.ip // "-")") | join("\n"))' \
            "$FAILOVER_STATUS" 2>/dev/null)
    fi
    [ -z "$txt" ] && txt="No status yet — is w3p-failover running?"
    msg_box "Failover Status" "$txt\n\nRoutes:\n$(ip route show default)"
}

# Modem JSON API (ZTE goform; read commands work without login on stock fw).
failover_modem_info() {
    local dev gw out
    dev=$(failover_lte_dev)
    [ -z "$dev" ] && { msg_box "Modem" "No USB LTE modem detected (cdc_ether/rndis)."; return; }
    gw=$(ip -j route show dev "$dev" 2>/dev/null | jq -r '[.[] | select(.dst=="default")][0].gateway // empty')
    [ -z "$gw" ] && { msg_box "Modem" "Modem $dev present but no gateway (no DHCP lease?)."; return; }
    out=$(curl -s --max-time 5 -H "Referer: http://$gw/index.html" \
        "http://$gw/goform/goform_get_cmd_process?isTest=false&multi_data=1&cmd=signalbar,network_type,network_provider,ppp_status,pin_status,monthly_rx_bytes,monthly_tx_bytes" \
        | jq -r 'to_entries | map("\(.key): \(.value)") | join("\n")' 2>/dev/null)
    msg_box "Modem ($dev via $gw)" "${out:-API not reachable — non-ZTE modem or web UI password required.}"
}

failover_wifi_setup() {
    local ssid psk wif dropin
    # networkd's netplan backend rejects match:/globs for wifis — the stanza
    # must name the concrete interface (bench: wld0 on resolute/6.18)
    wif=$(basename "$(ls -d /sys/class/net/wl* 2>/dev/null | head -1)" 2>/dev/null)
    [ -z "$wif" ] && { msg_box "WiFi Backup" "No WiFi interface (wl*) found on this system."; return; }
    ssid=$(input_box "WiFi Backup Link" "SSID of the WiFi network (mid rung of the failover ladder, metric 300):" "")
    [ -z "$ssid" ] && return
    psk=$(whiptail --title "WiFi Backup Link" --passwordbox "WPA2 password for '$ssid':" 10 60 3>&1 1>&2 2>&3)
    [ -z "$psk" ] && return
    # validate at the boundary: quotes/backslashes would corrupt the YAML
    case "$ssid$psk" in
        *'"'*|*'\'*) msg_box "WiFi Backup" "SSID/password must not contain quote (\") or backslash (\\) characters."; return ;;
    esac
    # keep the last working config restorable — netplan validates only in place
    [ -f "$WIFI_NETPLAN" ] && cp -p "$WIFI_NETPLAN" "$WIFI_NETPLAN.bak"
    install -m 600 /dev/null "$WIFI_NETPLAN"
    cat > "$WIFI_NETPLAN" <<EOF
# Written by control-panel (failover module). WiFi = middle failover rung.
network:
  version: 2
  wifis:
    $wif:
      dhcp4: true
      dhcp6: false
      optional: true
      dhcp4-overrides:
        route-metric: 300
        use-dns: false
      access-points:
        "$ssid":
          password: "$psk"
EOF
    if netplan generate 2>/tmp/netplan.err; then
        # AP-roam carrier blips must not withdraw the rung (netplan has no
        # timespan knob -> raw networkd drop-in on the generated unit)
        dropin=/etc/systemd/network/10-netplan-$wif.network.d
        mkdir -p "$dropin"
        printf '[Network]\nIgnoreCarrierLoss=3s\n' > "$dropin/w3p.conf"
        netplan apply
        msg_box "WiFi Backup" "WiFi '$ssid' configured on $wif at metric 300.\nCheck: ip -br addr"
    else
        if [ -f "$WIFI_NETPLAN.bak" ]; then
            mv "$WIFI_NETPLAN.bak" "$WIFI_NETPLAN"; netplan generate 2>/dev/null
            msg_box "WiFi Backup" "netplan rejected the new config:\n$(cat /tmp/netplan.err)\nPrevious WiFi config was restored."
        else
            rm -f "$WIFI_NETPLAN"
            msg_box "WiFi Backup" "netplan rejected the config:\n$(cat /tmp/netplan.err)\nNothing was applied."
        fi
    fi
    rm -f "$WIFI_NETPLAN.bak"
}

failover_data_usage() {
    local dev
    dev=$(failover_lte_dev)
    [ -z "$dev" ] && { msg_box "Data Usage" "No USB LTE modem detected."; return; }
    msg_box "Data Usage ($dev)" "$(vnstat -i "$dev" 2>/dev/null || echo 'vnstat has no data yet for this interface.')"
}
