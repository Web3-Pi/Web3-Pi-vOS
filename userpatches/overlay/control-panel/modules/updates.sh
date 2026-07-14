#!/bin/bash
#
# Web3 Pi Control Panel - Client Updates Module
#
# Both Ethereum clients come from APT repositories baked into the image
# (customize-image.sh): Geth from ppa:ethereum/ethereum (suite pinned to
# noble) and Nimbus from apt.status.im. An update is therefore an apt
# upgrade of exactly those packages — never a blanket system upgrade.
#
# Package names are resolved from what is actually installed (dpkg) rather
# than hardcoded to one name: the Geth PPA splits binaries across packages
# ('geth' plus the 'ethereum' metapackage) and that layout is not ours to
# control.
#
# The panel usually runs over SSH. If the connection drops mid-upgrade the
# apt transaction dies with the session and dpkg is left interrupted — the
# failure dialog and _updates_apt_install's HUP guard below deal with that.

UPDATES_GETH_PKGS="geth ethereum"
UPDATES_NIMBUS_PKGS="nimbus-beacon-node nimbus-validator-client"

# Echo the subset of the space-separated candidate list in $1 that dpkg
# reports as installed on this system. Excludes removed-but-config-files
# ('rc') packages, which still answer dpkg-query with a version.
_updates_installed() {
    local pkg out=""
    for pkg in $1; do
        if dpkg -s "$pkg" 2>/dev/null | grep -q '^Status: .* installed$'; then
            out="$out $pkg"
        fi
    done
    echo "${out# }"
}

_updates_pkg_version() {
    dpkg-query -W -f '${Version}' "$1" 2>/dev/null || true
}

# apt-cache output is localized ('Candidate:' -> 'Kandydująca:' under pl_PL,
# carried in over SSH via AcceptEnv LANG LC_*), so force the C locale or the
# awk match silently fails and everything looks up to date.
_updates_pkg_candidate() {
    LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

# True when $2 is a real upgrade over $1. dpkg --compare-versions, not string
# inequality: with the PPA suite pinned to noble the candidate can be OLDER
# than a locally-newer install — apt would no-op on it and we must not promise
# an update (nor restart services for nothing).
_updates_is_upgrade() {
    [ -n "$2" ] && [ "$2" != "(none)" ] && dpkg --compare-versions "${1:-0}" lt "$2"
}

_updates_is_held() {
    dpkg -s "$1" 2>/dev/null | grep -q '^Status: hold '
}

# Version line for the menu header; only consults installed packages so a
# removed-but-not-purged package doesn't masquerade as a version.
_updates_header_version() {
    local installed
    installed=$(_updates_installed "$1")
    if [ -n "$installed" ]; then
        _updates_pkg_version "${installed%% *}"
    else
        echo "not installed"
    fi
}

# Map package names to the systemd units that must be bounced to pick the new
# binary up. Restarts are derived from what actually got UPGRADED, not from
# the menu choice — updating only geth must not cost the validator its
# ~2-3 epoch doppelganger pause.
_updates_units_for_pkgs() {
    local pkg units=""
    for pkg in $1; do
        case "$pkg" in
            geth|ethereum)             units="$units geth" ;;
            nimbus-beacon-node)        units="$units nimbus-beacon-node" ;;
            nimbus-validator-client)   units="$units nimbus-validator" ;;
        esac
    done
    # dedupe, preserve order
    local unit out=""
    for unit in $units; do
        case " $out " in *" $unit "*) ;; *) out="$out $unit" ;; esac
    done
    echo "${out# }"
}

# Overflow-aware dialogs. The stock msg_box/yesno_box clip anything taller
# than ~14 rows (whiptail wraps but does not scroll), and both the update
# report and the confirmation warning can legitimately exceed that. But
# --scrolltext has a UX cost: focus starts on the textbox (so Enter is
# swallowed until the user tabs/arrows over to the button — confirmed on HW),
# so it is used ONLY when the text genuinely does not fit.
#
# Visible text area inside a TERM_HEIGHT=20 x TERM_WIDTH=70 whiptail box is
# ~14 rows x 66 cols (newt: 2 border + 3 button + 1 padding rows; 4 cols).
_updates_text_rows() {
    printf '%b' "$1" | awk '
        { n = length($0); r += (n <= 66) ? 1 : int((n - 1) / 66) + 1 }
        END { print r + 0 }'
}

_updates_msg() {
    if [ "$(_updates_text_rows "$2")" -le 13 ]; then
        msg_box "$1" "$2"
    else
        whiptail --title "$1" --scrolltext --msgbox "$2" $TERM_HEIGHT $TERM_WIDTH
    fi
}

_updates_yesno() {
    if [ "$(_updates_text_rows "$2")" -le 13 ]; then
        yesno_box "$1" "$2"
    else
        whiptail --title "$1" --scrolltext --yesno "$2" $TERM_HEIGHT $TERM_WIDTH
    fi
}

updates_menu() {
    while true; do
        local GETH_VER NIMBUS_VER
        GETH_VER=$(_updates_header_version "$UPDATES_GETH_PKGS")
        NIMBUS_VER=$(_updates_header_version "$UPDATES_NIMBUS_PKGS")

        CHOICE=$(whiptail --title "Client Updates" \
            --menu "Geth: $GETH_VER | Nimbus: $NIMBUS_VER" \
            $TERM_HEIGHT $TERM_WIDTH $LIST_HEIGHT \
            "1" "Check for Updates" \
            "2" "Update Geth" \
            "3" "Update Nimbus (Beacon + Validator Client)" \
            "4" "Update Both Clients" \
            "0" "Back to Main Menu" \
            3>&1 1>&2 2>&3)

        case $CHOICE in
            1) updates_check ;;
            2) updates_apply "Geth" "$UPDATES_GETH_PKGS" ;;
            3) updates_apply "Nimbus" "$UPDATES_NIMBUS_PKGS" ;;
            4) updates_apply "Geth + Nimbus" "$UPDATES_GETH_PKGS $UPDATES_NIMBUS_PKGS" ;;
            0|"") return ;;
        esac
    done
}

# Refresh the package indexes, showing apt output live in the terminal.
# --error-on=any: transient fetch failures (DNS down, LTE flapping — the
# normal failure mode on this fleet) print warnings but exit 0 by default,
# which would silently turn into a stale "up to date" verdict.
# Lock timeout: the image ships unattended-upgrades, so apt-daily can hold
# the lock when the operator opens the panel — wait instead of failing with
# a message that blames the network.
_updates_refresh_indexes() {
    clear
    echo "Refreshing package lists (apt-get update)..."
    echo
    if ! apt-get -o DPkg::Lock::Timeout=60 update --error-on=any; then
        echo
        read -p "Press Enter to continue..." || true
        msg_box "Update Check Failed" "apt-get update failed.\n\nUsual causes: no internet connectivity (DNS, default\nroute, LTE failover mid-switch) or another apt process\nholding the lock for over a minute.\n\nNothing was changed."
        return 1
    fi
    return 0
}

updates_check() {
    _updates_refresh_indexes || return

    local report="" pkg cur cand installed
    installed=$(_updates_installed "$UPDATES_GETH_PKGS $UPDATES_NIMBUS_PKGS")
    if [ -z "$installed" ]; then
        msg_box "No Clients Found" "None of the expected client packages are installed:\n$UPDATES_GETH_PKGS $UPDATES_NIMBUS_PKGS"
        return
    fi
    for pkg in $installed; do
        cur=$(_updates_pkg_version "$pkg")
        cand=$(_updates_pkg_candidate "$pkg")
        if _updates_is_upgrade "$cur" "$cand"; then
            if _updates_is_held "$pkg"; then
                report+="$pkg: $cur  [$cand available but package is HELD]\n"
            else
                report+="$pkg: $cur -> $cand  <-- UPDATE\n"
            fi
        else
            report+="$pkg: $cur  (up to date)\n"
        fi
    done
    _updates_msg "Available Updates" "$report"
}

# The apt transaction itself. HUP is ignored inside the subshell so a dropped
# SSH session no longer kills dpkg mid-unpack (which leaves the interrupted
# 'dpkg --configure -a' state); if the session does drop, the upgrade
# completes but the service restarts below never run — the clients keep
# running the old binaries until restarted via Service Management.
_updates_apt_install() {
    (
        trap '' HUP
        NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive \
        apt-get -o DPkg::Lock::Timeout=60 \
                -o Dpkg::Options::=--force-confold \
                install --only-upgrade --no-remove -y "$@"
    )
}

# updates_apply <display name> <candidate packages>
updates_apply() {
    local NAME="$1"
    local installed pkg cur cand upgradable="" held="" summary=""

    installed=$(_updates_installed "$2")
    if [ -z "$installed" ]; then
        msg_box "Not Installed" "No installed packages found for $NAME\n(expected: $2)"
        return
    fi

    _updates_refresh_indexes || return

    for pkg in $installed; do
        cur=$(_updates_pkg_version "$pkg")
        cand=$(_updates_pkg_candidate "$pkg")
        if _updates_is_upgrade "$cur" "$cand"; then
            if _updates_is_held "$pkg"; then
                held="$held $pkg"
            else
                upgradable="$upgradable $pkg"
                summary+="  $pkg: $cur -> $cand\n"
            fi
        fi
    done
    upgradable="${upgradable# }"

    if [ -z "$upgradable" ]; then
        if [ -n "$held" ]; then
            msg_box "Packages Held" "Updates exist for:${held}\nbut the packages are on hold (apt-mark hold).\n\nRelease with: apt-mark unhold <package>"
        else
            msg_box "Up to Date" "$NAME is already at the newest available version."
        fi
        return
    fi

    # Units affected by the packages that will actually change. The definitive
    # is-active filter runs right before the restart (post-apt) — between this
    # dialog and the restart minutes can pass, and e.g. a validator started
    # via start-validator.sh in the meantime must be picked up.
    local restart_candidates
    restart_candidates=$(_updates_units_for_pkgs "$upgradable")

    local warn="The following packages will be upgraded:\n\n${summary}\nServices restarted afterwards (only if running):\n  ${restart_candidates}\n\n"
    case " $restart_candidates " in
        *" geth "*)
            warn+="Geth may take several minutes to stop cleanly\n(it flushes state to disk; do NOT power off).\nThe beacon node restarts with it (Requires=).\n\n" ;;
    esac
    case " $restart_candidates " in
        *" nimbus-validator "*)
            warn+="Validator restart pauses attestations for ~2-3\nepochs (doppelganger detection). Expected, not\nslashable.\n\n" ;;
    esac
    if [ -n "$held" ]; then
        warn+="Skipped (apt-mark hold):${held}\n\n"
    fi

    if ! _updates_yesno "Update $NAME" "${warn}Proceed?"; then
        return
    fi

    clear
    echo "Upgrading: $upgradable"
    echo
    if ! _updates_apt_install $upgradable; then
        echo
        read -p "Press Enter to continue..." || true
        msg_box "Upgrade Failed" "apt-get reported an error while upgrading:\n$upgradable\n\nThe services were NOT restarted; the previous\nbinaries keep running.\n\nIf the output above mentions an interrupted dpkg,\nrun:  dpkg --configure -a\nthen retry."
        return
    fi

    # Restart what is running NOW (post-apt re-check). geth first; when geth
    # restarts, nimbus-beacon-node is bounced by systemd anyway
    # (Requires=geth.service), so it is skipped in the restart loop to avoid
    # a second full stop/checkpoint cycle — but it stays in the health check.
    local unit restart_units="" check_units=""
    for unit in $restart_candidates; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            restart_units="$restart_units $unit"
            check_units="$check_units $unit"
        fi
    done
    restart_units="${restart_units# }"
    case " $restart_units " in
        *" geth "*)
            # BN is bounced by systemd when geth restarts (Requires=), so it
            # leaves the restart loop (no second stop/checkpoint cycle) but
            # must join the health check whether or not its package changed.
            local kept=""
            for unit in $restart_units; do
                [ "$unit" = "nimbus-beacon-node" ] || kept="$kept $unit"
            done
            restart_units="${kept# }"
            if systemctl is-active --quiet nimbus-beacon-node 2>/dev/null; then
                case " $check_units " in
                    *" nimbus-beacon-node "*) ;;
                    *) check_units="$check_units nimbus-beacon-node" ;;
                esac
            fi ;;
    esac
    check_units="${check_units# }"

    local failed=""
    for unit in $restart_units; do
        echo "Restarting $unit..."
        systemctl restart "$unit" || failed="$failed $unit"
    done

    # Health check: poll for 30 s instead of a single glance. geth is
    # Type=simple, so is-active goes green the moment the process starts; a
    # broken upgrade that fatals during DB open can take >5 s on a large
    # datadir. A unit sitting in RestartSec backoff reports 'activating' and
    # fails the check. (A fatal later than ~30 s still escapes — check
    # Monitoring -> Sync Status after any upgrade.)
    if [ -n "$check_units" ]; then
        echo
        echo "Waiting 30s to verify services stay up..."
        local i
        for i in 1 2 3 4 5 6; do
            sleep 5
            for unit in $check_units; do
                if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
                    case " $failed " in
                        *" $unit "*) ;;
                        *) failed="$failed $unit" ;;
                    esac
                fi
            done
        done
    fi
    failed="${failed# }"
    echo
    read -p "Press Enter to continue..." || true

    local newver=""
    for pkg in $upgradable; do
        newver+="  $pkg: $(_updates_pkg_version "$pkg")\n"
    done

    if [ -n "$failed" ]; then
        _updates_msg "Update Finished With Errors" "Packages upgraded:\n$newver\nBUT these services are not running (or died within\n30s of the restart):\n  $failed\n\nInspect with:\n  journalctl -u <service> -n 100"
    else
        _updates_msg "Update Complete" "Packages upgraded:\n$newver\nAll affected services restarted and healthy for 30s.\n\nVerify sync resumes: Monitoring -> Sync Status."
    fi
}
