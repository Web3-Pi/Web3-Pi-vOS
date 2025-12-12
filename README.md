# Web3 Pi Staking

> **WARNING: EARLY DEVELOPMENT STAGE**
>
> This project is in early development. Do NOT use in production environments.
> Use at your own risk. Always test on testnets (hoodi) before considering mainnet.

Ethereum staking OS image for Raspberry Pi 5, based on Armbian.

## Overview

Web3 Pi Staking provides a pre-configured environment for running:
- **Geth** - Execution Layer client
- **Nimbus** - Consensus Layer client (beacon node + validator)

With security features:
- UFW firewall (IPv6 disabled)
- LUKS encrypted storage for validator keys
- SSH key-based authentication
- Separate system users for each component

## Hardware Requirements

- Raspberry Pi 5 (16GB RAM recommended)
- NVMe SSD (2TB+ recommended for mainnet)
- Boot from NVMe (no SD card)
- Stable internet connection
- Active cooling

---

## Quick Start Guide

### 1. Flash the Image

Download the latest image and flash it to your NVMe drive using Balena Etcher:

Insert NVMe SSD into your Raspberry Pi 5 and power on.

---

### 2. First Boot & SSH Login

The system will boot and configure itself. Wait ~1-3 minutes for first boot setup.

Find your Pi's IP address (check your router or use `nmap`):

```bash
ssh ethereum@<IP_ADDRESS>
```

**Default credentials:**
- Username: `ethereum`
- Password: `ethereum`

> You will be prompted to change the password on first login.

---

### 3. SSH Security Hardening

#### 3.1 Add Your SSH Public Key

On the RPi, run:

```bash
sudo /opt/web3pi/ssh-add-key.sh
```

Paste your public key when prompted.

#### 3.2 Test Key-Based Login

Open a **new terminal** and test SSH login with key.

If successful (no password prompt), proceed to disable password authentication.

#### 3.3 Disable Password Authentication

```bash
sudo /opt/web3pi/ssh-disable-password.sh
```

> **Important:** Keep your current SSH session open until you verify key-based login works!

---

### 4. Configure Network

Edit the configuration file:

```bash
sudo nano /opt/web3pi/config
```

Set your network (`hoodi` for testnet, `mainnet` for production):

```bash
# Network: hoodi or mainnet
NETWORK=hoodi

# Geth P2P port (TCP/UDP)
GETH_PORT=30303

# Nimbus P2P port (TCP/UDP)
NIMBUS_PORT=9000
```

> **Note:** If you change ports, you must also update UFW firewall rules. See comments in the config file.

---

### 5. LUKS Encrypted Storage Setup

Create encrypted partition for validator keys (one-time setup):

```bash
sudo /opt/web3pi/setup-luks.sh
```

You will be prompted to:
1. Select a disk for the encrypted partition
2. Create a strong passphrase

> **Important:** Remember your passphrase! It cannot be recovered.

After setup, unlock the encrypted storage:

```bash
sudo /opt/web3pi/unlock-luks.sh
```

---

### 6. Trusted Node Sync (Checkpoint Sync)

Perform fast initial sync using checkpoint sync servers:

```bash
sudo /opt/web3pi/trusted-node-sync.sh
```

This downloads a recent checkpoint state instead of syncing from genesis, reducing sync time from days to minutes.

> The script uses the `NETWORK` value from `/opt/web3pi/config`.

---

### 7. Start Ethereum Clients

Enable and start the services:

```bash
# Enable services to start on boot
sudo systemctl enable geth
sudo systemctl enable nimbus-beacon-node

# Start services
sudo systemctl start geth
sudo systemctl start nimbus-beacon-node
```

---

### 8. Monitor Synchronization

#### Check Service Status

```bash
sudo systemctl status geth
sudo systemctl status nimbus-beacon-node
```

#### View Logs

```bash
# Geth (Execution Layer)
sudo journalctl -u geth -f

# Nimbus (Consensus Layer)
sudo journalctl -u nimbus-beacon-node -f
```

#### Sync Progress

**Geth sync status:**
```bash
geth attach --datadir /var/lib/el --exec "eth.syncing"
```

Returns `false` when fully synced.

**Nimbus sync status:**
```bash
curl -s http://127.0.0.1:5052/eth/v1/node/syncing | jq
```

Wait for both EL and CL to fully synchronize before proceeding.

---

### 9. Validator Setup

> **UNDER CONSTRUCTION**
>
> This section is currently being developed.
>
> Future steps will include:
> - Importing validator keys to `/home/signer/keys`
> - Configuring fee recipient address
> - Starting the validator client
> - Monitoring validator performance

---

## After Reboot

After each system reboot:

1. Unlock encrypted storage:
   ```bash
   sudo /opt/web3pi/unlock-luks.sh
   ```

2. Start validator (when configured):
   ```bash
   sudo /opt/web3pi/start-validator.sh
   ```

> Geth and Nimbus beacon node start automatically if enabled.

---

## File Locations

| Component | Directory |
|-----------|-----------|
| Configuration | `/opt/web3pi/config` |
| Geth data | `/var/lib/el` |
| Nimbus beacon data | `/var/lib/cl` |
| Validator keys | `/home/signer/keys` (encrypted) |
| Scripts | `/opt/web3pi/` |
| Logs | `/opt/web3pi/logs/` |

---

## Useful Commands

```bash
# Show help
/home/ethereum/help.sh

# Service control
sudo systemctl start|stop|restart|status geth
sudo systemctl start|stop|restart|status nimbus-beacon-node
sudo systemctl start|stop|restart|status nimbus-validator

# Firewall status
sudo ufw status numbered

# Disk usage
df -h
```

---

## Network Ports

| Port | Protocol | Service | Description |
|------|----------|---------|-------------|
| 22 | TCP | SSH | Remote access (rate limited) |
| 30303 | TCP/UDP | Geth | P2P communication |
| 9000 | TCP/UDP | Nimbus | P2P communication |

Internal only (localhost):
- 8545 - Geth HTTP RPC
- 8551 - Geth Auth RPC (Engine API)
- 5052 - Nimbus REST API

---

## Troubleshooting

### Services won't start
```bash
sudo journalctl -u geth -n 50
sudo journalctl -u nimbus-beacon-node -n 50
```

### Sync issues
- Ensure correct network is set in `/opt/web3pi/config`
- Check internet connectivity
- Verify firewall allows P2P ports

### LUKS issues
- Ensure you're using the correct passphrase
- Check if partition exists: `lsblk`

---