#!/bin/bash
#
# ssh-add-key.sh - Add SSH public key for authentication
#
# Usage: sudo /opt/web3pi/ssh-add-key.sh
#    or: sudo /opt/web3pi/ssh-add-key.sh "ssh-ed25519 AAAA... user@host"
#

SSH_DIR="/home/ethereum/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

echo ""
echo "============================================================"
echo "  ADD SSH PUBLIC KEY"
echo "============================================================"
echo ""

# Get public key from argument or prompt
if [ -n "$1" ]; then
    PUBLIC_KEY="$1"
else
    echo "Paste your SSH public key (ssh-ed25519, ssh-rsa, or sk-ssh-ed25519 for FIDO2):"
    echo ""
    read -r PUBLIC_KEY
fi

# Validate key format (including FIDO2 hardware keys)
if [[ ! "$PUBLIC_KEY" =~ ^(ssh-(ed25519|rsa|ecdsa)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) ]]; then
    echo ""
    echo "ERROR: Invalid SSH public key format."
    echo "Key should start with: ssh-ed25519, ssh-rsa, sk-ssh-ed25519@openssh.com, etc."
    exit 1
fi

# Create .ssh directory if not exists
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    chown ethereum:ethereum "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    echo "Created $SSH_DIR"
fi

# Check if key already exists
if [ -f "$AUTH_KEYS" ] && grep -qF "$PUBLIC_KEY" "$AUTH_KEYS"; then
    echo ""
    echo "This key is already in authorized_keys."
    exit 0
fi

# Add key
echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
chown ethereum:ethereum "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

echo ""
echo "============================================================"
echo "  SSH KEY ADDED SUCCESSFULLY"
echo "============================================================"
echo ""
echo "  You can now login with your private key:"
echo "    ssh ethereum@<ip-address>"
echo ""
echo "  To disable password authentication (recommended):"
echo "    sudo /opt/web3pi/ssh-disable-password.sh"
echo ""
echo "============================================================"
echo ""
