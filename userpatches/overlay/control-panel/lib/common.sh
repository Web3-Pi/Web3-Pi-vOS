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
    fi
}

save_config() {
    # Preserve an explicitly-empty GETH_HISTORY_FLAG (user chose "off"): the
    # colon-less default only fires for a truly-unset variable (upgrade path),
    # not for an intentional empty value.
    local geth_history_flag="${GETH_HISTORY_FLAG-"--history.chain=postprague"}"

    # MEV-Boost: MEV_BOOST_ENABLED is the single source of truth; the per-unit
    # flag fragments are re-derived on every save so they can never disagree
    # with it. The nimbus units reference them WITHOUT braces (word-split,
    # empty -> zero args — same trick as GETH_HISTORY_FLAG in geth.service).
    local mev_boost_enabled="${MEV_BOOST_ENABLED:-false}"
    local mev_bn_flags="" mev_vc_flags=""
    if [ "$mev_boost_enabled" = "true" ]; then
        mev_bn_flags="--payload-builder=true --payload-builder-url=http://127.0.0.1:18550"
        mev_vc_flags="--payload-builder=true"
    fi
    cat > "$CONFIG_FILE" << EOF
# Web3 Pi Staking Configuration

# Network: hoodi, holesky, or mainnet
NETWORK=${NETWORK:-hoodi}

# Geth P2P port (TCP/UDP)
GETH_PORT=${GETH_PORT:-30303}

# Geth chain-history retention (disk usage).
# Full flag passed to geth, or empty to omit it (Geth default = keep all history).
#   --history.chain=postprague  prune pre-Prague history  (~1 TB less, recommended)
#   --history.chain=postmerge   prune pre-Merge history
#   --history.chain=all         keep full history (Geth default, most disk)
#   (empty)                     do not pass the flag
# Toggle via control-panel.sh -> Eth Network Configuration -> Geth Chain History.
GETH_HISTORY_FLAG="${geth_history_flag}"

# Nimbus P2P port (TCP/UDP)
NIMBUS_PORT=${NIMBUS_PORT:-9000}

# NOTE: If you change ports, update /etc/nftables.conf:
#   Change 'dport <old_port>' to 'dport <new_port>'
#   sudo systemctl restart nftables
#   sudo systemctl daemon-reload
#   sudo systemctl restart geth nimbus-beacon-node

# Validator Configuration
# Fee recipient address for block rewards (REQUIRED for validator)
FEE_RECIPIENT=${FEE_RECIPIENT:-0x0000000000000000000000000000000000000000}

# Graffiti message (max 32 characters, visible in proposed blocks)
GRAFFITI=${GRAFFITI:-Web3Pi}

# MEV-Boost (external block builder)
# Toggle + relay list via control-panel.sh -> Validator Management -> MEV Boost.
MEV_BOOST_ENABLED=${mev_boost_enabled}

# Comma-separated relay URLs (https://0x<pubkey>@host). Network-specific:
# switching NETWORK resets this to the new network's defaults.
MEV_RELAYS="${MEV_RELAYS}"

# Derived from MEV_BOOST_ENABLED — do not edit by hand (rewritten on every
# config save). The nimbus units reference these WITHOUT braces so an empty
# value expands to zero arguments (same trick as GETH_HISTORY_FLAG above).
MEV_BOOST_BN_FLAGS="${mev_bn_flags}"
MEV_BOOST_VC_FLAGS="${mev_vc_flags}"
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
