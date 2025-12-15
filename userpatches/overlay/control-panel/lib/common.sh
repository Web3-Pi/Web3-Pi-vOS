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
    cat > "$CONFIG_FILE" << EOF
# Web3 Pi Staking Configuration

# Network: hoodi, holesky, or mainnet
NETWORK=${NETWORK:-hoodi}

# Geth P2P port (TCP/UDP)
GETH_PORT=${GETH_PORT:-30303}

# Nimbus P2P port (TCP/UDP)
NIMBUS_PORT=${NIMBUS_PORT:-9000}

# NOTE: If you change ports, update UFW firewall rules:
#   sudo ufw delete allow <old_port>/tcp
#   sudo ufw delete allow <old_port>/udp
#   sudo ufw allow <new_port>/tcp
#   sudo ufw allow <new_port>/udp
#   sudo systemctl daemon-reload
#   sudo systemctl restart geth nimbus-beacon-node

# Validator Configuration
# Fee recipient address for block rewards (REQUIRED for validator)
FEE_RECIPIENT=${FEE_RECIPIENT:-0x0000000000000000000000000000000000000000}

# Graffiti message (max 32 characters, visible in proposed blocks)
GRAFFITI=${GRAFFITI:-Web3Pi}
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
