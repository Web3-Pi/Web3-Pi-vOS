#!/bin/bash
#
# Web3 Pi Control Panel - Common Library
# Shared constants, configuration, and helper functions
#

# Configuration paths
CONFIG_FILE="/opt/web3pi/config"
SSH_DIR="/home/ethereum/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Terminal dimensions
TERM_HEIGHT=20
TERM_WIDTH=70
LIST_HEIGHT=10

# Colors for whiptail
export NEWT_COLORS='
root=,blue
window=,lightgray
border=black,lightgray
textbox=black,lightgray
button=black,cyan
'

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root: sudo $0"
        exit 1
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        _migrate_legacy_config_names
    fi
}

# Config keys were renamed to the W3P_ prefix (2026-07-13): geth scans its own
# environment for GETH_*-named variables and maps them onto flags, so our
# GETH_PORT was silently consumed and GETH_HISTORY_FLAG logged
# "Unknown config environment variable" on every start. A config written by an
# older image still has the old names — map them onto the new ones so the first
# save_config migrates the file in place.
# Guard choice matters: for keys that can never be legitimately empty the
# ${W3P_X:-} form also repairs a set-but-empty variable (e.g. left behind by a
# cancelled whiptail dialog) instead of letting save_config replace it with the
# default. Only W3P_GETH_HISTORY_FLAG ("off"), W3P_MEV_RELAYS (no relays) and
# the two derived MEV fragments are legitimately empty, so they use the ${x+x}
# form to preserve an intentional empty value.
_migrate_legacy_config_names() {
    [ -z "${W3P_NETWORK:-}" ]           && [ -n "${NETWORK:-}" ]           && W3P_NETWORK="$NETWORK"
    [ -z "${W3P_GETH_PORT:-}" ]         && [ -n "${GETH_PORT:-}" ]         && W3P_GETH_PORT="$GETH_PORT"
    [ -z "${W3P_NIMBUS_PORT:-}" ]       && [ -n "${NIMBUS_PORT:-}" ]       && W3P_NIMBUS_PORT="$NIMBUS_PORT"
    [ -z "${W3P_FEE_RECIPIENT:-}" ]     && [ -n "${FEE_RECIPIENT:-}" ]     && W3P_FEE_RECIPIENT="$FEE_RECIPIENT"
    [ -z "${W3P_GRAFFITI:-}" ]          && [ -n "${GRAFFITI:-}" ]          && W3P_GRAFFITI="$GRAFFITI"
    [ -z "${W3P_MEV_BOOST_ENABLED:-}" ] && [ -n "${MEV_BOOST_ENABLED:-}" ] && W3P_MEV_BOOST_ENABLED="$MEV_BOOST_ENABLED"
    [ -z "${W3P_GETH_HISTORY_FLAG+x}" ] && [ -n "${GETH_HISTORY_FLAG+x}" ] && W3P_GETH_HISTORY_FLAG="$GETH_HISTORY_FLAG"
    [ -z "${W3P_MEV_RELAYS+x}" ]        && [ -n "${MEV_RELAYS+x}" ]        && W3P_MEV_RELAYS="$MEV_RELAYS"
    # Derived fragments: functionally re-derived by save_config, mapped here only
    # so status screens don't show "none" next to "Enabled: true" before the
    # first save migrates the file.
    [ -z "${W3P_MEV_BOOST_BN_FLAGS+x}" ] && [ -n "${MEV_BOOST_BN_FLAGS+x}" ] && W3P_MEV_BOOST_BN_FLAGS="$MEV_BOOST_BN_FLAGS"
    [ -z "${W3P_MEV_BOOST_VC_FLAGS+x}" ] && [ -n "${MEV_BOOST_VC_FLAGS+x}" ] && W3P_MEV_BOOST_VC_FLAGS="$MEV_BOOST_VC_FLAGS"
    return 0
}

save_config() {
    # Preserve an explicitly-empty W3P_GETH_HISTORY_FLAG (user chose "off"): the
    # colon-less default only fires for a truly-unset variable (upgrade path),
    # not for an intentional empty value.
    local geth_history_flag="${W3P_GETH_HISTORY_FLAG-"--history.chain=postprague"}"

    # MEV-Boost: W3P_MEV_BOOST_ENABLED is the single source of truth; the
    # per-unit flag fragments are re-derived on every save so they can never
    # disagree with it. The nimbus units reference them WITHOUT braces
    # (word-split, empty -> zero args — same trick as W3P_GETH_HISTORY_FLAG in
    # geth.service).
    local mev_boost_enabled="${W3P_MEV_BOOST_ENABLED:-false}"
    local mev_bn_flags="" mev_vc_flags=""
    if [ "$mev_boost_enabled" = "true" ]; then
        mev_bn_flags="--payload-builder=true --payload-builder-url=http://127.0.0.1:18550"
        mev_vc_flags="--payload-builder=true"
    fi
    cat > "$CONFIG_FILE" << EOF
# Web3 Pi Staking Configuration
# All keys use the W3P_ prefix: geth maps GETH_*-named environment variables
# onto its own flags, so unprefixed names collide with its namespace.

# Network: hoodi, holesky, or mainnet
W3P_NETWORK=${W3P_NETWORK:-hoodi}

# Geth P2P port (TCP/UDP)
W3P_GETH_PORT=${W3P_GETH_PORT:-30303}

# Geth chain-history retention (disk usage).
# Full flag passed to geth, or empty to omit it (Geth default = keep all history).
#   --history.chain=postprague  prune pre-Prague history  (~1 TB less, recommended)
#   --history.chain=postmerge   prune pre-Merge history
#   --history.chain=all         keep full history (Geth default, most disk)
#   (empty)                     do not pass the flag
# Toggle via control-panel.sh -> Eth Network Configuration -> Geth Chain History.
W3P_GETH_HISTORY_FLAG="${geth_history_flag}"

# Nimbus P2P port (TCP/UDP)
W3P_NIMBUS_PORT=${W3P_NIMBUS_PORT:-9000}

# NOTE: If you change ports, update /etc/nftables.conf:
#   Change 'dport <old_port>' to 'dport <new_port>'
#   sudo systemctl restart nftables
#   sudo systemctl daemon-reload
#   sudo systemctl restart geth nimbus-beacon-node

# Validator Configuration
# Fee recipient address for block rewards (REQUIRED for validator)
W3P_FEE_RECIPIENT=${W3P_FEE_RECIPIENT:-0x0000000000000000000000000000000000000000}

# Graffiti message (max 32 characters, visible in proposed blocks)
W3P_GRAFFITI=${W3P_GRAFFITI:-Web3Pi}

# MEV-Boost (external block builder)
# Toggle + relay list via control-panel.sh -> Validator Management -> MEV Boost.
W3P_MEV_BOOST_ENABLED=${mev_boost_enabled}

# Comma-separated relay URLs (https://0x<pubkey>@host). Network-specific:
# switching W3P_NETWORK resets this to the new network's defaults.
W3P_MEV_RELAYS="${W3P_MEV_RELAYS}"

# Derived from W3P_MEV_BOOST_ENABLED — do not edit by hand (rewritten on every
# config save). The nimbus units reference these WITHOUT braces so an empty
# value expands to zero arguments (same trick as W3P_GETH_HISTORY_FLAG above).
W3P_MEV_BOOST_BN_FLAGS="${mev_bn_flags}"
W3P_MEV_BOOST_VC_FLAGS="${mev_vc_flags}"
EOF
}

msg_box() {
    whiptail --title "$1" --msgbox "$2" $TERM_HEIGHT $TERM_WIDTH
}

yesno_box() {
    whiptail --title "$1" --yesno "$2" $TERM_HEIGHT $TERM_WIDTH
}

input_box() {
    whiptail --title "$1" --inputbox "$2" $TERM_HEIGHT $TERM_WIDTH "$3" 3>&1 1>&2 2>&3
}
