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
            "5" "WiFi backup link (scan / setup / status)" \
            "6" "Data usage (LTE)" \
            "7" "Edit failover settings" \
            "8" "Link speed test (wired / LTE)" \
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
            5) failover_wifi_menu ;;
            6) failover_data_usage ;;
            7) ${EDITOR:-nano} "$FAILOVER_CONF"
               systemctl is-active -q w3p-failover 2>/dev/null \
                   && yesno_box "Failover" "Restart the watchdog to apply the new settings?" \
                   && systemctl restart w3p-failover ;;
            8) failover_speed_test ;;
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

failover_wifi_iface() {
    basename "$(ls -d /sys/class/net/wl* 2>/dev/null | head -1)" 2>/dev/null
}

failover_wifi_menu() {
    local wif CHOICE
    wif=$(failover_wifi_iface)
    [ -z "$wif" ] && { msg_box "WiFi Backup" "No WiFi interface (wl*) found on this system."; return; }
    while true; do
        local state="not configured"
        [ -f "$WIFI_NETPLAN" ] && state="configured"
        iw dev "$wif" link 2>/dev/null | grep -q "^Connected" && state="$state, connected"
        CHOICE=$(whiptail --title "WiFi Backup Link ($wif)" \
            --menu "Middle rung of the failover ladder (metric 300).\nStatus: $state" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Scan & connect to a network" \
            "2" "Enter SSID manually" \
            "3" "Connection status" \
            "4" "Forget WiFi configuration" \
            "0" "Back" \
            3>&1 1>&2 2>&3)
        case $CHOICE in
            1) failover_wifi_scan_connect "$wif" ;;
            2) failover_wifi_setup "$wif" "" ;;
            3) failover_wifi_status "$wif" ;;
            4) failover_wifi_forget "$wif" ;;
            0|"") return ;;
        esac
    done
}

# Scan for nearby networks (interface must be administratively up to scan;
# leaving it up is harmless — it has no config until provisioned).
failover_wifi_scan_connect() {
    local wif=$1 scan choice
    ip link set "$wif" up 2>/dev/null
    TERM=ansi whiptail --infobox "Scanning for WiFi networks on $wif..." 8 50
    # iw scan -> "SSID<TAB>signal%", strongest first, deduplicated
    scan=$(iw dev "$wif" scan 2>/dev/null | awk '
        /^BSS /            { sig="" }
        /signal:/          { sig=$2 }
        /^\tSSID: ./       { ssid=substr($0, 8)
                             if (ssid != "" && !(ssid in best) || sig+0 > best[ssid]+0) best[ssid]=sig }
        END { for (s in best) printf "%s\t%.0f\n", s, best[s] }' \
        | sort -t$'\t' -k2 -nr | head -15)
    if [ -z "$scan" ]; then
        msg_box "WiFi Scan" "No networks found (or scan failed).\nYou can still enter the SSID manually."
        return
    fi
    local args=() ssid sig first=ON
    while IFS=$'\t' read -r ssid sig; do
        args+=("$ssid" "signal ${sig} dBm" "$first"); first=OFF
    done <<< "$scan"
    choice=$(whiptail --title "WiFi Scan — networks in range" --radiolist \
        "Pick a network (strongest first):" $TERM_HEIGHT $TERM_WIDTH 12 \
        "${args[@]}" 3>&1 1>&2 2>&3) || return
    [ -n "$choice" ] && failover_wifi_setup "$wif" "$choice"
}

failover_wifi_status() {
    local wif=$1 link addr probe="not tested"
    link=$(iw dev "$wif" link 2>/dev/null)
    addr=$(ip -j -4 addr show dev "$wif" 2>/dev/null | jq -r '.[0].addr_info[0].local // "no address"')
    if echo "$link" | grep -q "^Connected"; then
        ping -I "$wif" -c1 -W3 -q 1.1.1.1 >/dev/null 2>&1 && probe="internet OK" || probe="NO internet via WiFi"
    fi
    msg_box "WiFi Status ($wif)" \
"$( [ -f "$WIFI_NETPLAN" ] && echo "Config: $WIFI_NETPLAN present" || echo "Config: none" )
IP: $addr    Probe: $probe

$( echo "$link" | head -8 )

Routes on $wif:
$( ip route show dev "$wif" 2>/dev/null | head -3 )"
}

failover_wifi_forget() {
    local wif=$1
    [ -f "$WIFI_NETPLAN" ] || { msg_box "WiFi Backup" "Nothing to forget — no WiFi config present."; return; }
    yesno_box "WiFi Backup" "Remove the WiFi backup configuration?\nThe failover ladder keeps working (Ethernet -> LTE)." || return
    rm -f "$WIFI_NETPLAN"
    rm -rf "/etc/systemd/network/10-netplan-$wif.network.d"
    netplan generate 2>/dev/null && netplan apply
    msg_box "WiFi Backup" "WiFi configuration removed."
}

failover_wifi_setup() {
    local wif=$1 ssid=$2 psk dropin
    if [ -z "$ssid" ]; then
        ssid=$(input_box "WiFi Backup Link" "SSID of the WiFi network (mid rung of the failover ladder, metric 300):" "")
        [ -z "$ssid" ] && return
    fi
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
        # wait for association + DHCP (up to 30 s), then report honestly
        TERM=ansi whiptail --infobox "Connecting to '$ssid'..." 8 50
        local i addr=""
        for i in $(seq 1 15); do
            sleep 2
            addr=$(ip -j -4 addr show dev "$wif" 2>/dev/null | jq -r '.[0].addr_info[0].local // empty')
            [ -n "$addr" ] && break
        done
        if [ -n "$addr" ]; then
            local sig; sig=$(iw dev "$wif" link 2>/dev/null | awk '/signal:/ {print $2, $3}')
            msg_box "WiFi Backup" "Connected: '$ssid' on $wif\nIP: $addr   Signal: ${sig:-?}\nRung active at metric 300 — the watchdog will use it automatically."
        else
            msg_box "WiFi Backup" "Config saved, but no connection after 30 s.\nCheck the password and signal, then see: Connection status.\n(journalctl -u netplan-wpa-$wif for details)"
        fi
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

# Link speed test bound to a specific interface (SO_BINDTODEVICE — the panel
# runs as root, so the traffic REALLY takes the chosen link; tools like
# speedtest-cli bind the source address only and leak via the default route).
# Verdict against the documented product minimum for failover duty (Mbit/s),
# overridable in /etc/w3p-failover.conf.
failover_speed_test() {
    local choice dev label is_lte=0
    local wired="" d
    for d in /sys/class/net/e*; do
        [ -e "$d" ] || continue
        case "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)" in
            cdc_ether|rndis_host) ;;
            *) wired=$(basename "$d"); break ;;
        esac
    done
    local lte; lte=$(failover_lte_dev)
    choice=$(whiptail --title "Link Speed Test" --radiolist \
        "Which link to measure?" $TERM_HEIGHT $TERM_WIDTH 4 \
        "wired" "Ethernet (${wired:-not found})" ON \
        "lte"   "USB LTE modem (${lte:-not found})" OFF \
        3>&1 1>&2 2>&3) || return
    if [ "$choice" = lte ]; then
        dev=$lte; label="LTE"; is_lte=1
        [ -z "$dev" ] && { msg_box "Speed Test" "No USB LTE modem detected."; return; }
        yesno_box "Speed Test" "This will transfer ~70 MB over the METERED LTE connection.\nContinue?" || return
        tc qdisc show dev "$dev" 2>/dev/null | grep -qE "cake|tbf" \
            && msg_box "Speed Test" "Note: the failover egress cap is active on $dev\n(LTE is the active WAN) — upload will show the SHAPED value."
    else
        dev=$wired; label="Ethernet"
        [ -z "$dev" ] && { msg_box "Speed Test" "No wired interface found."; return; }
    fi

    . "$FAILOVER_CONF" 2>/dev/null
    local min_down=${MIN_DOWN_MBIT:-20} min_up=${MIN_UP_MBIT:-5}

    TERM=ansi whiptail --infobox "Measuring $label ($dev)...\n\n1/3 latency" 10 50
    local lat down up down_mbit up_mbit
    lat=$(ping -I "$dev" -c 8 -i 0.3 -q 1.1.1.1 2>/dev/null | awk -F/ '/rtt/ {printf "%.0f", $5}')

    TERM=ansi whiptail --infobox "Measuring $label ($dev)...\n\n2/3 download (50 MB)" 10 50
    down=$(curl --interface "$dev" -s -o /dev/null -w "%{speed_download}" \
           "https://speed.cloudflare.com/__down?bytes=50000000" --max-time 60)
    # single retry: the endpoint occasionally hiccups with a 1-byte response
    [ "${down%.*}" -lt 10000 ] 2>/dev/null && down=$(curl --interface "$dev" -s -o /dev/null \
           -w "%{speed_download}" "https://speed.cloudflare.com/__down?bytes=50000000" --max-time 60)

    TERM=ansi whiptail --infobox "Measuring $label ($dev)...\n\n3/3 upload (20 MB)" 10 50
    dd if=/dev/urandom of=/tmp/w3p-speed.bin bs=1M count=20 2>/dev/null
    up=$(curl --interface "$dev" -s -o /dev/null -w "%{speed_upload}" \
         -T /tmp/w3p-speed.bin "https://speed.cloudflare.com/__up" --max-time 60)
    rm -f /tmp/w3p-speed.bin

    down_mbit=$(awk -v b="${down:-0}" 'BEGIN {printf "%.1f", b*8/1000000}')
    up_mbit=$(awk -v b="${up:-0}" 'BEGIN {printf "%.1f", b*8/1000000}')
    local verdict="OK — meets the ${min_down}/${min_up} Mbit/s minimum for failover duty"
    awk -v d="$down_mbit" -v u="$up_mbit" -v md="$min_down" -v mu="$min_up" \
        'BEGIN {exit !(d<md || u<mu)}' \
        && verdict="!! BELOW the ${min_down}/${min_up} Mbit/s minimum — an Ethereum node CANNOT stay healthy on this link.\nTry: reposition the modem (window), different carrier, external-antenna modem."

    local extra=""
    if [ $is_lte -eq 1 ]; then
        local gw; gw=$(ip -j route show dev "$dev" 2>/dev/null | jq -r '[.[] | select(.dst=="default")][0].gateway // empty')
        [ -n "$gw" ] && extra=$(curl -s --max-time 5 -H "Referer: http://$gw/index.html" \
            "http://$gw/goform/goform_get_cmd_process?isTest=false&multi_data=1&cmd=signalbar,network_type,network_provider,lte_rsrp,lte_snr" \
            | jq -r '"Signal: \(.signalbar)/5  \(.network_type) @ \(.network_provider)  RSRP \(.lte_rsrp) dBm  SNR \(.lte_snr) dB"' 2>/dev/null)
    fi
    msg_box "Speed Test — $label ($dev)" \
"Download: $down_mbit Mbit/s
Upload:   $up_mbit Mbit/s
Latency:  ${lat:-?} ms (avg)
${extra:+$extra
}
$verdict"
}

failover_data_usage() {
    local dev line live_rx live_tx
    dev=$(failover_lte_dev)
    [ -z "$dev" ] && { msg_box "Data Usage" "No USB LTE modem detected."; return; }
    systemctl is-active -q vnstat 2>/dev/null || systemctl enable --now vnstat 2>/dev/null
    # live kernel counters: always current, reset on boot/re-plug
    live_rx=$(numfmt --to=iec-i --suffix=B "$(cat /sys/class/net/$dev/statistics/rx_bytes 2>/dev/null || echo 0)")
    live_tx=$(numfmt --to=iec-i --suffix=B "$(cat /sys/class/net/$dev/statistics/tx_bytes 2>/dev/null || echo 0)")
    if ! line=$(vnstat --oneline -i "$dev" 2>/dev/null); then
        # modem plugged in after the vnstat daemon started -> not in its DB yet
        vnstat --add -i "$dev" >/dev/null 2>&1
        msg_box "Data Usage ($dev)" \
"Live now (kernel counters, since boot/plug-in):
  RX $live_rx    TX $live_tx

vnstat is now tracking $dev — daily/monthly history
will appear here within ~5 minutes."
        return
    fi
    # vnstat --oneline: 3=today's date 4=rx 5=tx 6=total | 8=month 9=rx 10=tx 11=total
    msg_box "Data Usage ($dev)" "$(echo "$line" | awk -F';' '{
        printf "Live now (kernel counters, since boot/plug-in):\n"
        printf "  RX %-12s TX %s\n\n", "'"$live_rx"'", "'"$live_tx"'"
        printf "vnstat history — database refreshes every 5 min:\n"
        printf "  Today (%s):\n    RX %-12s TX %-12s = %s\n", $3, $4, $5, $6
        printf "  Month (%s):\n    RX %-12s TX %-12s = %s\n", $8, $9, $10, $11
    }')"
}
