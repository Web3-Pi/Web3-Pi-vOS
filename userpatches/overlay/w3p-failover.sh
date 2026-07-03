#!/bin/bash
# w3p-failover — WAN failover watchdog for Web3 Pi vOS (M5).
# Design: web3pi_scope/notes/M5-failover-plan-v2.md
#
# Layer 0 (declarative, netplan): metric ladder wired=100 wifi=300 lte=700.
#   Every L2 failure (cable pull, AP loss, dongle unplug) fails over with no
#   help from this daemon — the kernel picks the next-lowest-metric route.
# Layer 1 (this daemon): detects "carrier up, internet dead" links with root
#   probes bound to each interface, and forces traffic off a dead link by
#   installing ONE override default route at metric 50 (networkd runs with
#   ManageForeignRoutes=no, so the override is ours alone to add and remove).
# Layer 2 (nudge, FAILOVER_NUDGE=1): after a flip, aborts TCP sockets still
#   pinned to the old source address (ss -K by source, never by port) so the
#   Ethereum clients redial over the new path instead of waiting out kernel
#   TCP timeouts. Escalation (beacon-only restart) is clamped to once per
#   outage; the validator service is NEVER touched by this daemon.
#
# Shape: a reconciliation loop, not a straight-line script. Every cycle
# derives live state from the kernel (ip -j), compares to desired state,
# converges. Post-switch verification is a STATE of this loop (no background
# forks — a forked verifier cannot update the escalation clamp). Clamp state
# lives in /run so it survives daemon restarts (cleared on reboot, which is
# the right scope). "w3p-failover.sh cleanup" removes everything the daemon
# owns (override route, qdisc, apt masks) — used by ExecStopPost and the trap,
# so disabling the watchdog really does return the box to the bare ladder.

CONF=/etc/w3p-failover.conf
RUN_DIR=/run/w3p-failover
STATUS=$RUN_DIR/status.json
STATE=$RUN_DIR/state                    # persisted clamp state (key=value)
ESC_FLAG=$RUN_DIR/escalated             # exists = beacon already restarted this outage
NONE_FLAG=$RUN_DIR/all-down             # exists = ALL-LINKS-DOWN state entered
TAG=w3p-failover

# ---------------------------------------------------------------- defaults --
FAILOVER_ANCHORS="1.1.1.1 9.9.9.9"     # two providers; hardcoded IPs, no DNS dependency
PROBE_ACTIVE_S=5
PROBE_STANDBY_S=30
PROBE_LTE_STANDBY_S=120                 # metered: slow and ICMP-only
DEMOTE_AFTER_S=20
PROMOTE_AFTER_S=120
SWITCH_DWELL_S=60
FLAP_LIMIT=4
FLAP_WINDOW_S=600
UNLATCH_AFTER_S=1800
FAILOVER_NUDGE=1
VERIFY_BUDGET_LTE_S=300
VERIFY_BUDGET_FAST_S=120
APT_INFLIGHT_WAIT_S=120                 # bounded wait before SIGINT-ing in-flight apt on LTE
CAKE_KBIT=4500
BEACON_REST=http://127.0.0.1:5052
GETH_RPC=http://127.0.0.1:8545
[ -r "$CONF" ] && . "$CONF"

log() { logger -t $TAG "$*"; }
now() { printf '%(%s)T' -1; }

# ------------------------------------------------------------ orphan sweep --
# Everything the daemon may own, removed idempotently. Run as "cleanup" arg
# from ExecStopPost/trap; also the ALL-DOWN entry action.
LTE_DEV_CACHE=""
sweep_owned() {
    ip route del default metric 50 2>/dev/null
    systemctl unmask --runtime apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
    rm -f /etc/apt/apt.conf.d/99-w3p-metered
    local d
    for d in /sys/class/net/*; do
        case "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)" in
            cdc_ether|rndis_host) tc qdisc del dev "$(basename "$d")" root 2>/dev/null ;;
        esac
    done
}
if [ "$1" = cleanup ]; then sweep_owned; exit 0; fi

mkdir -p "$RUN_DIR"

# --------------------------------------------------------- persisted state --
LAST_SWITCH=0; LATCHED_UNTIL=0; SWITCH_TS=""; SWITCH_COUNT=0; LAST_ESCALATION=0
VERIFY_ROLE=""; VERIFY_START=0; VERIFY_HEAD=0; NONE_OLDIP=""; APT_SIGNALED=0
PREV_ACTIVE=""; LAST_IP_WIRED=""; LAST_IP_WIFI=""; LAST_IP_LTE=""
[ -r "$STATE" ] && . "$STATE"
declare -A LAST_IP=([wired]=$LAST_IP_WIRED [wifi]=$LAST_IP_WIFI [lte]=$LAST_IP_LTE)
save_state() {
    {
        printf 'LAST_SWITCH=%s\nLATCHED_UNTIL=%s\nSWITCH_TS="%s"\nSWITCH_COUNT=%s\n' \
               "$LAST_SWITCH" "$LATCHED_UNTIL" "$SWITCH_TS" "$SWITCH_COUNT"
        printf 'LAST_ESCALATION=%s\nVERIFY_ROLE="%s"\nVERIFY_START=%s\nVERIFY_HEAD=%s\n' \
               "$LAST_ESCALATION" "$VERIFY_ROLE" "$VERIFY_START" "$VERIFY_HEAD"
        printf 'NONE_OLDIP="%s"\nAPT_SIGNALED=%s\nPREV_ACTIVE="%s"\n' \
               "$NONE_OLDIP" "$APT_SIGNALED" "$PREV_ACTIVE"
        printf 'LAST_IP_WIRED="%s"\nLAST_IP_WIFI="%s"\nLAST_IP_LTE="%s"\n' \
               "${LAST_IP[wired]:-}" "${LAST_IP[wifi]:-}" "${LAST_IP[lte]:-}"
    } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# ------------------------------------------------------------- link facts --
declare -A IF GW IP4 HEALTH FAIL_SINCE OK_SINCE LAST_PROBE FAIL_STAGE
ACTIVE=""

discover_links() {
    IF=(); local n d path
    for path in /sys/class/net/*; do
        n=$(basename "$path")
        [ "$n" = lo ] && continue
        d=$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)" 2>/dev/null)
        [ -z "$d" ] && continue
        case "$d" in
            cdc_ether|rndis_host) IF[lte]=$n ;;
            *)  case "$n" in
                    wl*) IF[wifi]=$n ;;
                    e*)  [ -z "${IF[wired]:-}" ] && IF[wired]=$n ;;
                esac ;;
        esac
    done
    local r
    for r in wired wifi lte; do
        GW[$r]=""; IP4[$r]=""
        [ -n "${IF[$r]:-}" ] || continue
        IP4[$r]=$(ip -j -4 addr show dev "${IF[$r]}" 2>/dev/null \
                  | jq -r '.[0].addr_info[0].local // empty' 2>/dev/null)
        # remember the last known address: after a cable pull the address is
        # gone from the iface but its dead sockets still need nudging
        [ -n "${IP4[$r]}" ] && LAST_IP[$r]=${IP4[$r]}
        # exclude our own metric-50 override or a renewed lease's gateway is
        # never picked up
        GW[$r]=$(ip -j route show dev "${IF[$r]}" 2>/dev/null \
                  | jq -r '[.[] | select(.dst=="default" and ((.metric // 0) != 50))][0].gateway // empty' 2>/dev/null)
    done
}

# Subnet-collision preflight (§5.6): backup links MUST use distinct subnets.
# The MF79U's LAN is 192.168.0.0/24 — also the default of many home routers.
# Same connected subnet on two links makes same-IP destinations (both
# gateways are 192.168.0.1!) interface-ambiguous for unbound traffic.
# We detect and ALARM (status.json + log); per-link-bound probes keep
# working either way, but the config is documented as unsupported.
COLLISION=""; COLLISION_LOGGED=""
declare -A SUBNET_OF
detect_collision() {
    local r dst owner
    COLLISION=""; SUBNET_OF=()
    for r in wired wifi lte; do
        [ -n "${IF[$r]:-}" ] && [ -n "${IP4[$r]:-}" ] || continue
        for dst in $(ip -j -4 route show dev "${IF[$r]}" 2>/dev/null \
                     | jq -r '.[] | select(.protocol=="kernel") | .dst' 2>/dev/null); do
            owner=${SUBNET_OF[$dst]:-}
            if [ -n "$owner" ] && [ "$owner" != "$r" ]; then
                COLLISION="$owner+$r $dst"
            else
                SUBNET_OF[$dst]=$r
            fi
        done
    done
    if [ -n "$COLLISION" ] && [ "$COLLISION" != "$COLLISION_LOGGED" ]; then
        log "SUBNET COLLISION: $COLLISION — backup links must use distinct subnets (see docs); per-link probes stay interface-bound, but this configuration is unsupported"
        COLLISION_LOGGED=$COLLISION
    elif [ -z "$COLLISION" ] && [ -n "$COLLISION_LOGGED" ]; then
        log "subnet collision cleared"
        COLLISION_LOGGED=""
    fi
}

current_active() {
    local best; best=$(ip -j route show default 2>/dev/null \
        | jq -r 'sort_by(.metric // 0)[0].dev // empty' 2>/dev/null)
    local r; for r in wired wifi lte; do
        [ "${IF[$r]:-}" = "$best" ] && [ -n "$best" ] && { echo "$r"; return; }
    done
    echo ""
}

# ------------------------------------------------------------------ probes --
# Verdict per plan §5.1: DOWN = gateway dead OR (all anchors fail AND, on the
# active link, DNS fails too — DNS may only CONFIRM an anchor failure, never
# cause a demotion by itself: a single resolver outage must not flip a healthy
# link onto metered LTE). Root probes = SO_BINDTODEVICE; unprivileged -I binds
# the source only and leaks via the default route (bench-verified).
probe_link() {                          # $1 role; rc 0 healthy; sets FAIL_STAGE
    local r=$1 dev=${IF[$r]:-} a rc ok=0
    FAIL_STAGE[$r]=""
    [ -n "$dev" ] && [ -n "${IP4[$r]:-}" ] || { FAIL_STAGE[$r]=link; return 1; }
    if [ -n "${GW[$r]:-}" ]; then
        ping -I "$dev" -c1 -W2 -q "${GW[$r]}" >/dev/null 2>&1 \
            || { FAIL_STAGE[$r]=gw; return 1; }
    fi
    for a in $FAILOVER_ANCHORS; do
        ping -I "$dev" -c1 -W3 -q "$a" >/dev/null 2>&1 && { ok=1; break; }
        # TCP fallback for ICMP-hostile paths — but never on standby LTE
        # (metered; ICMP-only there per §5.1). curl rc 60 = TLS/cert stage
        # reached = TCP path alive.
        if [ "$r" != lte ] || [ "$r" = "$ACTIVE" ]; then
            curl --interface "$dev" -s --max-time 4 -o /dev/null "https://$a/" 2>/dev/null
            rc=$?
            { [ $rc -eq 0 ] || [ $rc -eq 60 ]; } && { ok=1; break; }
        fi
    done
    if [ $ok -eq 0 ]; then
        if [ "$r" = "$ACTIVE" ]; then
            # DNS corroboration before declaring the traffic-carrier dead
            for a in $FAILOVER_ANCHORS; do
                dig +time=2 +tries=1 +short cloudflare.com "@$a" >/dev/null 2>&1 \
                    && return 0        # anchors ICMP-filtered but DNS answers: alive
            done
        fi
        FAIL_STAGE[$r]=anchor; return 1
    fi
    return 0
}

probe_due() {
    local r=$1 iv=$PROBE_STANDBY_S t=$(now)
    [ "$r" = "$ACTIVE" ] && iv=$PROBE_ACTIVE_S
    [ "$r" = lte ] && [ "$r" != "$ACTIVE" ] && iv=$PROBE_LTE_STANDBY_S
    [ $(( t - ${LAST_PROBE[$r]:-0} )) -ge $iv ]
}

update_health() {
    local r t=$(now) active_down=""
    [ -n "$ACTIVE" ] && [ "${HEALTH[$ACTIVE]:-}" = down ] && active_down=1
    for r in wired wifi lte; do
        [ -n "${IF[$r]:-}" ] || { HEALTH[$r]=absent; continue; }
        # during a multi-link incident keep the loop responsive: while the
        # active link is failing, skip standby probes this cycle — EXCEPT in
        # ALL-DOWN, where standby probes are the only way to notice recovery
        [ -n "$active_down" ] && [ "$r" != "$ACTIVE" ] && [ ! -e "$NONE_FLAG" ] && continue
        probe_due "$r" || continue
        LAST_PROBE[$r]=$t
        if probe_link "$r"; then
            OK_SINCE[$r]=${OK_SINCE[$r]:-$t}; FAIL_SINCE[$r]=""; HEALTH[$r]=up
        elif [ "$r" = "$ACTIVE" ] && chain_alive_recently; then
            # probes drowned in a saturated link, but the chain is moving —
            # the link is alive; don't demote (and don't spam the log)
            if [ $(( t - CHAIN_VETO_LOG )) -ge 60 ]; then
                log "active-link probe failed but chain head is advancing — keeping $r"
                CHAIN_VETO_LOG=$t
            fi
            OK_SINCE[$r]=${OK_SINCE[$r]:-$t}; FAIL_SINCE[$r]=""; HEALTH[$r]=up
        else
            FAIL_SINCE[$r]=${FAIL_SINCE[$r]:-$t}; OK_SINCE[$r]=""; HEALTH[$r]=down
        fi
    done
    # Correlated-upstream short-circuit (§5.1): only when wired failed at the
    # ANCHOR stage (gateway alive, upstream dead) AND wifi shares that gateway
    # AND wifi has produced no fresh evidence since wired started failing.
    # Never overrides a wifi probe that passed after the wired failure began.
    if [ -n "${FAIL_SINCE[wired]:-}" ] && [ "${FAIL_STAGE[wired]:-}" = anchor ] \
       && [ -n "${GW[wifi]:-}" ] && [ "${GW[wifi]}" = "${GW[wired]:-}" ] \
       && [ "${LAST_PROBE[wifi]:-0}" -le "${FAIL_SINCE[wired]}" ]; then
        FAIL_SINCE[wifi]=${FAIL_SINCE[wifi]:-$(( t - DEMOTE_AFTER_S ))}
        OK_SINCE[wifi]=""; HEALTH[wifi]=down
    fi
}

# Chain-liveness backstop for the ACTIVE link: a node in catch-up saturates
# LTE, ICMP probes drown in the queue and false-fail — but if the beacon's
# head slot is advancing, the link self-evidently carries traffic. Sampled
# once per cycle from loopback (cheap), used to veto active-link demotion.
CHAIN_HEAD=0; CHAIN_HEAD_TS=0; CHAIN_VETO_LOG=0
chain_tick() {
    systemctl is-active -q nimbus-beacon-node 2>/dev/null || return 0
    local h; h=$(curl -s --max-time 2 "$BEACON_REST/eth/v1/node/syncing" \
                 | jq -r '.data.head_slot // 0' 2>/dev/null)
    if [ "${h:-0}" -gt "$CHAIN_HEAD" ] 2>/dev/null; then
        CHAIN_HEAD=$h; CHAIN_HEAD_TS=$(now)
    fi
}
chain_alive_recently() { [ $(( $(now) - CHAIN_HEAD_TS )) -lt 30 ]; }

link_failed_long() { local r=$1; [ -n "${FAIL_SINCE[$r]:-}" ] && [ $(( $(now) - FAIL_SINCE[$r] )) -ge $DEMOTE_AFTER_S ]; }
link_ok_long()     { local r=$1; [ "${HEALTH[$r]:-}" = up ] && [ -n "${OK_SINCE[$r]:-}" ] && [ $(( $(now) - OK_SINCE[$r] )) -ge $PROMOTE_AFTER_S ]; }

is_higher() {
    local a=$1 b=$2 i p1=9 p2=9 o=("wired" "wifi" "lte")
    for i in 0 1 2; do
        [ "${o[$i]}" = "$a" ] && p1=$i
        [ "${o[$i]}" = "$b" ] && p2=$i
    done
    [ $p1 -lt $p2 ]
}

desired_active() {
    local r
    for r in wired wifi lte; do
        [ -n "${IF[$r]:-}" ] && [ -n "${IP4[$r]:-}" ] || continue
        if [ "$r" = "$ACTIVE" ]; then
            link_failed_long "$r" || { echo "$r"; return; }
        elif is_higher "$r" "${ACTIVE:-lte}"; then
            link_ok_long "$r" && { echo "$r"; return; }
        else
            [ "${HEALTH[$r]:-}" = up ] && { echo "$r"; return; }
        fi
    done
    echo ""
}

# ------------------------------------------------------- switch mechanics --
clear_override() { ip route del default metric 50 2>/dev/null; }
apply_override() {
    local r=$1
    [ -n "${GW[$r]:-}" ] || return 1
    ip route replace default via "${GW[$r]}" dev "${IF[$r]}" metric 50
}

wan_estab_count() {                     # $1 src ip — WAN sockets only
    [ -n "$1" ] || { echo 0; return; }
    ss -Htn state established \
       "src $1 and not dst 10.0.0.0/8 and not dst 172.16.0.0/12 and not dst 192.168.0.0/16 and not dst 127.0.0.0/8" \
       2>/dev/null | wc -l
}

nudge() {
    [ "$FAILOVER_NUDGE" = 1 ] || return 0
    local oldip=$1
    [ -n "$oldip" ] || return 0
    ss -K -tn "src $oldip and not dst 10.0.0.0/8 and not dst 172.16.0.0/12 and not dst 192.168.0.0/16 and not dst 127.0.0.0/8" >/dev/null 2>&1
    conntrack -D --orig-src "$oldip" >/dev/null 2>&1
    log "nudge: killed WAN sockets with src $oldip"
}

metered_on() {
    local dev=${IF[lte]:-}
    [ -n "$dev" ] || return
    if ! tc qdisc replace dev "$dev" root cake bandwidth "${CAKE_KBIT}kbit" besteffort 2>/dev/null; then
        tc qdisc replace dev "$dev" root tbf rate "${CAKE_KBIT}kbit" burst 32kbit latency 400ms 2>/dev/null \
            && [ ! -e "$RUN_DIR/cake-warned" ] && { log "cake unavailable, using tbf"; : > "$RUN_DIR/cake-warned"; }
    fi
    systemctl mask --runtime --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
    printf 'Acquire::http::Dl-Limit "500";\n' > /etc/apt/apt.conf.d/99-w3p-metered
}
metered_off() {
    local dev=${IF[lte]:-}
    [ -n "$dev" ] && tc qdisc del dev "$dev" root 2>/dev/null
    systemctl unmask --runtime apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
    rm -f /etc/apt/apt.conf.d/99-w3p-metered
    APT_SIGNALED=0
}

# In-flight unattended-upgrade on LTE (§5.5): masked timers don't stop a
# RUNNING download. Bounded wait, then one SIGINT per dwell.
apt_inflight_tick() {
    [ "$ACTIVE" = lte ] || return 0
    [ "$APT_SIGNALED" = 1 ] && return 0
    local u busy=""
    for u in apt-daily.service apt-daily-upgrade.service; do
        systemctl is-active -q "$u" 2>/dev/null && busy=$u
    done
    [ -n "$busy" ] || return 0
    if [ $(( $(now) - LAST_SWITCH )) -ge $APT_INFLIGHT_WAIT_S ]; then
        log "apt in-flight on LTE past ${APT_INFLIGHT_WAIT_S}s — SIGINT $busy"
        systemctl kill -s SIGINT "$busy" 2>/dev/null
        APT_SIGNALED=1
    fi
}

# ----------------------------------------------------- verify (loop state) --
# Runs as a state of the main loop — no forks, so the escalation clamp and
# status stay truthful, and a switch simply re-arms the verify for the new
# role. Success = WAN sockets on the new source AND CL head advancing.
# EL checks are informational: a stuck EL suppresses escalation (a beacon
# restart cannot fix a starved geth — §5.3.4).
verify_arm() {
    VERIFY_ROLE=$1; VERIFY_START=$(now); VERIFY_HEAD=-1
}
verify_tick() {
    [ -n "$VERIFY_ROLE" ] || return 0
    if [ "$VERIFY_ROLE" != "$ACTIVE" ]; then VERIFY_ROLE=""; return 0; fi
    # beacon momentarily inactive (e.g. restarting): pause, don't cancel —
    # the budget keeps ticking and the wedged-after-restart case still alarms
    systemctl is-active -q nimbus-beacon-node 2>/dev/null || return 0
    local budget=$VERIFY_BUDGET_FAST_S head estab
    [ "$VERIFY_ROLE" = lte ] && budget=$VERIFY_BUDGET_LTE_S
    # Never judge a beacon younger than the verify budget: right after boot
    # (or its own restart) it legitimately has no advancing head yet —
    # observed as a false escalation at system boot. Hold the clock instead.
    local bpid betimes
    bpid=$(systemctl show -p MainPID --value nimbus-beacon-node 2>/dev/null)
    betimes=$(ps -o etimes= -p "${bpid:-0}" 2>/dev/null | tr -d ' ')
    if [ "${betimes:-0}" -lt "$budget" ]; then VERIFY_START=$(now); return 0; fi
    head=$(curl -s --max-time 3 "$BEACON_REST/eth/v1/node/syncing" \
           | jq -r '.data.head_slot // empty' 2>/dev/null)
    estab=$(wan_estab_count "${IP4[$VERIFY_ROLE]:-}")
    if [ -n "$head" ] && [ "$VERIFY_HEAD" -ge 0 ] && [ "${head:-0}" -gt "$VERIFY_HEAD" ] \
       && [ "${estab:-0}" -gt 0 ]; then
        log "verify OK on $VERIFY_ROLE: head $VERIFY_HEAD->$head, WAN estab=$estab"
        rm -f "$ESC_FLAG"               # verified-healthy link closes the outage
        VERIFY_ROLE=""
        return 0
    fi
    [ -n "$head" ] && VERIFY_HEAD=$head
    if [ $(( $(now) - VERIFY_START )) -ge $budget ]; then
        local el_peers; el_peers=$(curl -s --max-time 3 -X POST "$GETH_RPC" \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
            | jq -r '.result // empty' 2>/dev/null)
        if [ -n "$head" ] && [ "${el_peers:-0x0}" = "0x0" ]; then
            log "verify FAILED but EL has no peers — beacon restart won't help; suppressing escalation"
            VERIFY_ROLE=""
        elif [ -e "$ESC_FLAG" ]; then
            log "verify FAILED again — escalation already spent this outage; alarming"
            VERIFY_ROLE=""
        else
            : > "$ESC_FLAG"; LAST_ESCALATION=$(now)
            log "verify FAILED after ${budget}s — beacon-only restart (validator untouched)"
            systemctl restart nimbus-beacon-node 2>/dev/null
            verify_arm "$ACTIVE"        # confirm the restart helped; a second failure alarms
        fi
    fi
}

# ------------------------------------------------------------- switching --
prune_flap_window() {
    local t=$(now) kept="" s
    for s in $SWITCH_TS; do [ $(( t - s )) -le $FLAP_WINDOW_S ] && kept="$kept $s"; done
    SWITCH_TS=${kept# }
}
flap_count() { local c=0 s; for s in $SWITCH_TS; do c=$((c+1)); done; echo $c; }

do_switch() {                           # $1 new role, $2 old-src ip override (NONE exit)
    local new=$1 old=$ACTIVE oldip=${2:-} t=$(now)
    [ -z "$oldip" ] && [ -n "$old" ] && oldip=${IP4[$old]:-}
    # Same-link recovery (ALL-DOWN -> the same rung): the sockets pinned to
    # this address are the ones we want to KEEP. Nudging them repeatedly
    # zeroed Nimbus's freshly rebuilt peer set on every probe blip (observed
    # live during the second physical cable test).
    [ -n "$oldip" ] && [ "$oldip" = "${IP4[$new]:-}" ] && oldip=""
    if [ "$new" = wired ]; then clear_override; else apply_override "$new" || return 1; fi
    SWITCH_TS="$SWITCH_TS $t"; SWITCH_TS=${SWITCH_TS# }; SWITCH_COUNT=$((SWITCH_COUNT+1))
    log "switch: ${old:-ladder} -> $new (wired=${HEALTH[wired]:-?} wifi=${HEALTH[wifi]:-?} lte=${HEALTH[lte]:-?})"
    [ -n "$old" ] && [ -n "${IF[$old]:-}" ] && ip neigh flush dev "${IF[$old]}" 2>/dev/null
    nudge "$oldip"
    if [ "$new" = lte ]; then metered_on; else metered_off; fi
    [ "$new" = wired ] && rm -f "$ESC_FLAG"      # home again: fresh escalation budget
    LAST_SWITCH=$t
    ACTIVE=$new
    verify_arm "$new"
}

# Carrier-driven (ladder) transitions: an L2 failure flips routing in the
# KERNEL (next-lowest-metric route wins) without any do_switch — but the
# Layer-2 side effects are still owed: dead sockets pinned to the vanished
# address must be nudged or Nimbus sits deaf on a "connected" peer set for
# many minutes (observed live on the first physical cable-pull test, T6).
on_ladder_transition() {                # $1 old role (may be ""), $2 new role
    local old=$1 new=$2 t=$(now)
    if [ -z "$old" ]; then              # cold start / state reset: align only
        log "initial active link: ${new:-none}"
        if [ "$new" = lte ]; then metered_on; elif [ -n "$new" ]; then metered_off; fi
        return 0
    fi
    [ -z "$new" ] && { log "ladder transition: $old -> none (all defaults gone)"; return 0; }
    log "ladder transition (carrier-driven): $old -> $new"
    SWITCH_TS="$SWITCH_TS $t"; SWITCH_TS=${SWITCH_TS# }; SWITCH_COUNT=$((SWITCH_COUNT+1))
    LAST_SWITCH=$t
    nudge "${LAST_IP[$old]:-}"
    if [ "$new" = lte ]; then metered_on; else metered_off; fi
    [ "$new" = wired ] && rm -f "$ESC_FLAG"
    verify_arm "$new"
}

# Latch check BEFORE executing a switch (§5.2): entering the clamp performs
# one final reconcile to the highest-priority healthy link, then holds.
try_switch() {                          # $1 wanted role
    local want=$1 t=$(now)
    prune_flap_window
    if [ "$(flap_count)" -ge "$FLAP_LIMIT" ]; then
        if [ "$t" -ge "$LATCHED_UNTIL" ]; then
            LATCHED_UNTIL=$(( t + UNLATCH_AFTER_S ))
            local best r
            for r in wired wifi lte; do
                [ "${HEALTH[$r]:-}" = up ] && { best=$r; break; }
            done
            log "FLAP CLAMP: latched ${UNLATCH_AFTER_S}s; settling on ${best:-$ACTIVE}"
            [ -n "${best:-}" ] && [ "$best" != "$ACTIVE" ] && do_switch "$best"
        fi
        return 0
    fi
    [ $(( t - LAST_SWITCH )) -ge $SWITCH_DWELL_S ] && do_switch "$want"
}

# --------------------------------------------------------------- reconcile --
reconcile_assets() {
    local a=$ACTIVE
    # never re-assert an override toward a link we consider dead, and never
    # while in the ALL-DOWN state (that fight was finding #3 of the review)
    local ov ovgw
    ov=$(ip -j route show default metric 50 2>/dev/null | jq -r '.[0].dev // empty' 2>/dev/null)
    ovgw=$(ip -j route show default metric 50 2>/dev/null | jq -r '.[0].gateway // empty' 2>/dev/null)
    if [ -e "$NONE_FLAG" ] || [ "$a" = wired ] || [ -z "$a" ] || link_failed_long "$a"; then
        [ -n "$ov" ] && { clear_override; log "reconcile: dropped override via $ov"; }
    elif [ "$ov" != "${IF[$a]:-}" ] || [ "$ovgw" != "${GW[$a]:-}" ]; then
        apply_override "$a" && log "reconcile: re-asserted override via ${IF[$a]:-?}"
    fi
    if [ "$a" = lte ] && [ ! -e "$NONE_FLAG" ]; then
        tc qdisc show dev "${IF[lte]:-}" 2>/dev/null | grep -qE "cake|tbf" || metered_on
    elif [ -f /etc/apt/apt.conf.d/99-w3p-metered ]; then
        metered_off
    fi
}

write_status() {
    local t=$(now) latched=false verify=""
    [ "$t" -lt "$LATCHED_UNTIL" ] && latched=true
    [ -n "$VERIFY_ROLE" ] && verify=$VERIFY_ROLE
    {
        printf '{"ts":%s,"active":"%s","latched":%s,"latched_until":%s,' \
               "$t" "${ACTIVE:-none}" "$latched" "$LATCHED_UNTIL"
        printf '"escalated":%s,"last_escalation":%s,"switches":%s,"verifying":"%s","all_down":%s,' \
               "$([ -e "$ESC_FLAG" ] && echo true || echo false)" \
               "$LAST_ESCALATION" "$SWITCH_COUNT" "$verify" \
               "$([ -e "$NONE_FLAG" ] && echo true || echo false)"
        printf '"subnet_collision":"%s",' "$COLLISION"
        printf '"links":{'
        local r sep=""
        for r in wired wifi lte; do
            printf '%s"%s":{"if":"%s","ip":"%s","gw":"%s","health":"%s"}' \
                   "$sep" "$r" "${IF[$r]:-}" "${IP4[$r]:-}" "${GW[$r]:-}" "${HEALTH[$r]:-absent}"
            sep=","
        done
        printf '}}\n'
    } > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
}

# -------------------------------------------------------------- main loop --
log "starting (nudge=$FAILOVER_NUDGE anchors='$FAILOVER_ANCHORS' cake=${CAKE_KBIT}kbit)"
# Graceful stop: sweep owned network state AND the outage flags — an operator
# stop/start is a fresh start (a re-enable days later must not replay a stale
# ALL-DOWN recovery or a spent escalation budget). Crash restarts keep STATE.
trap 'log "stopping — sweeping owned state"; sweep_owned; rm -f "$NONE_FLAG" "$ESC_FLAG"; exit 0' TERM INT

while :; do
    discover_links
    detect_collision
    ACTIVE=$(current_active)
    [ "$ACTIVE" != "$PREV_ACTIVE" ] && on_ladder_transition "$PREV_ACTIVE" "$ACTIVE"
    chain_tick
    update_health
    reconcile_assets
    verify_tick
    apt_inflight_tick

    t=$(now)
    if [ "$t" -lt "$LATCHED_UNTIL" ]; then
        :                               # latched: hold; probes/status continue
    else
        want=$(desired_active)
        if [ -n "$want" ]; then
            if [ -e "$NONE_FLAG" ]; then
                # leaving ALL-DOWN via the ladder: run full switch side effects
                # (nudge against the pre-outage source, metered discipline).
                # No dwell (recovery is mandatory) but the flap budget still
                # counts — a marginal lte oscillating NONE<->up must latch.
                rm -f "$NONE_FLAG"
                log "recovery from ALL-DOWN -> $want"
                prune_flap_window
                if [ "$(flap_count)" -ge "$FLAP_LIMIT" ] && [ "$t" -ge "$LATCHED_UNTIL" ]; then
                    LATCHED_UNTIL=$(( t + UNLATCH_AFTER_S ))
                    log "FLAP CLAMP on ALL-DOWN recovery: latched ${UNLATCH_AFTER_S}s"
                fi
                do_switch "$want" "$NONE_OLDIP"
                NONE_OLDIP=""
            elif [ "$want" != "$ACTIVE" ]; then
                try_switch "$want"
            fi
        elif [ -z "$want" ] && [ ! -e "$NONE_FLAG" ] \
             && { [ -z "$ACTIVE" ] || link_failed_long "$ACTIVE"; }; then
            NONE_OLDIP=""; [ -n "$ACTIVE" ] && NONE_OLDIP=${IP4[$ACTIVE]:-}
            : > "$NONE_FLAG"
            sweep_owned                 # bare ladder; no override, no masks
            log "ALL LINKS DOWN — override cleared, ladder rules; probing on"
        fi
    fi

    PREV_ACTIVE=$ACTIVE                 # post-do_switch value: a watchdog
                                        # switch must not re-fire the ladder
                                        # handler next cycle
    save_state
    write_status
    sleep 5
done
