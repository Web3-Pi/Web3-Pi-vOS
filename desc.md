# Web3-Pi-vOS System Description

**Version**: w3p-v25.11
**Base**: Armbian Build Framework (Armbian Minimal)
**Target Platform**: Raspberry Pi 5 with 16 GB RAM and 2 TB NVMe (PCIe)

---

## 1. Project Overview

Web3-Pi-vOS is a customized Armbian-based operating system designed specifically for **Ethereum solo staking** on Raspberry Pi 5. It transforms a Raspberry Pi into a fully functional Ethereum validator node with enterprise-grade security features.

### Key Advantages

- Based on **Armbian Minimal** - contains only essential packages, extremely lightweight
- Most packages and configuration applied during **image build phase** (not at runtime)
- Compressed image size: **~400 MB**
- First-Boot time on Raspberry Pi 5: **~15 seconds**
- Optimized for **performance and reliability**

### Core Philosophy

- **Security First**: LUKS-encrypted validator keys, locked root account, firewall-first approach, SSH key-only authentication with optional FIDO2 hardware key support
- **Minimal Attack Surface**: Headless CLI system, no desktop environment
- **Self-Sovereign Staking**: All keys remain on-device, no third-party custody
- **Ease of Use**: TUI Control Panel for configuration without requiring deep Linux expertise

### Why Armbian?

During development, four operating systems were evaluated for Raspberry Pi 5:
- **Ubuntu Server 24.04+** (official ARM64 builds)
- **Raspberry Pi OS Lite** (Debian-based, official)
- **DietPi** (Debian-based, optimized)
- **Armbian Minimal** (Ubuntu-based)

**Initial benchmarks** using GeekBench6 showed a significant performance advantage for DietPi and Raspberry Pi OS over Ubuntu-based systems. However, GeekBench6 tests general computing workloads that are quite different from Ethereum node operations.

**Custom Ethereum benchmark** was developed to measure performance relevant to actual staking workloads: [ethBenchmark](https://github.com/cmd0s/ethBenchmark). This specialized tool tests operations that Ethereum clients actually perform:

- Keccak256 hashing
- ECDSA/secp256k1 signatures
- BLS12-381 operations (using gnark-crypto)
- BN256 pairing
- Merkle Patricia Trie simulation
- Object pool allocation
- State cache patterns
- Sequential I/O throughput
- Random 4K I/O (bypassing page cache)
- Batch write simulation

**Results**: With Ethereum-specific benchmarks, DietPi and Raspberry Pi OS showed only a marginal performance advantage over Ubuntu-based systems.

**Decision criteria** shifted from raw performance to:

1. **Build system quality**: Armbian Build System provides deep image customization capabilities
2. **Package availability**: Geth and Nimbus are available as official APT packages for Ubuntu arm64. On Debian-based systems (Raspberry Pi OS, DietPi), Geth is not available as a package or binary and must be compiled from source
3. **Customization flexibility**: Armbian allows extensive pre-configuration during image build phase

**Conclusion**: Armbian was selected for its superior build system, official Ethereum client packages, and deep customization capabilities - outweighing the minimal performance difference.

### Client Architecture

Web3-Pi-vOS uses a **split client architecture** separating the Consensus Layer beacon node from the Validator Client:

```
┌─────────────────────────────────────────────────────────────────
│                    SPLIT ARCHITECTURE
├─────────────────────────────────────────────────────────────────
│
│   nimbus_beacon_node        (Consensus Layer - CL)
│   └── Tracks chain head, manages P2P, serves REST API
│              │
│              │ REST API (localhost:5052)
│              ▼
│   nimbus_validator_client   (Validator/Signer)
│   └── Signs attestations and proposals, manages keys
│
```

**Why not use integrated mode?**

Nimbus beacon node can run with built-in validator functionality (integrated mode). However, splitting into separate processes provides significant advantages:

**Security Isolation**
- Validator keys are handled by a dedicated `signer` user with no shell access
- Keys stored on LUKS-encrypted partition, completely separate from beacon node data
- Compromise of beacon node process does not expose validator keys
- Reduced attack surface per process

**LUKS Encrypted Storage**
- Validator keys reside on encrypted `/dev/nvme0n1p3` partition (2 GiB)
- LUKS2 with AES-XTS-plain64, Argon2id KDF, 512-bit key
- Must be manually unlocked after each boot - keys never accessible without passphrase
- Protects against physical theft of NVMe drive

**Performance Benefits**
- Two separate processes can utilize multiple CPU cores more effectively
- Critical for Raspberry Pi 5 where single-core performance is limited
- Validator client has minimal resource requirements, runs independently

**Operational Flexibility**
- Services can be restarted independently
- Beacon node updates don't require validator restart
- Easier debugging - separate logs per component
- Can run beacon node while validator is stopped (for testing/maintenance)

---

## 2. System Topology

### 2.1 Two-Phase Setup Architecture

The system employs a two-phase installation strategy:

```
┌──────────────────────────────────────────────────────────────────
│                        PHASE 1: BUILD-TIME
│                     (chroot environment)
├──────────────────────────────────────────────────────────────────
│  customize-image.sh
│  ├── User creation (ethereum, el, cl, signer)
│  ├── Package installation (geth, nimbus, cryptsetup, etc.)
│  ├── Service file deployment
│  ├── Security hardening (root locked, SSH hardened)
│  ├── Firewall configuration (nftables)
│  └── Script deployment to /opt/web3pi/
│
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────
│                     PHASE 2: FIRST-BOOT
│                   (actual hardware)
├──────────────────────────────────────────────────────────────────
│  rc.local
│  ├── Network connectivity check
│  ├── NTP time synchronization
│  ├── Ethereum user home directory finalization
│  ├── Unattended upgrades configuration
│  └── Installation stage tracking (/root/.install_stage)
│
```

### 2.2 Directory Structure

```
/opt/web3pi/
├── config                      # Central configuration file
├── logs/                       # System logs
├── control-panel.sh            # Main TUI interface
├── control-panel/              # Control panel modules
│   ├── lib/common.sh           # Shared functions
│   └── modules/
│       ├── data.sh             # Data management
│       ├── luks.sh             # Encryption management
│       ├── monitoring.sh       # System monitoring
│       ├── network.sh          # Network configuration
│       ├── services.sh         # Service management
│       ├── ssh.sh              # SSH security
│       ├── sync.sh             # Checkpoint sync
│       ├── system.sh           # System settings
│       └── validator.sh        # Validator management
├── setup-luks.sh               # LUKS partition creation
├── unlock-luks.sh              # LUKS unlock
├── start-validator.sh          # Validator startup
├── trusted-node-sync.sh        # Checkpoint sync
├── ssh-add-key.sh              # SSH key management
├── ssh-disable-password.sh     # Security hardening
├── rpi-eeprom/                 # Firmware update tools
├── servers_mainnet.txt         # Checkpoint sync servers
├── servers_holesky.txt
└── servers_hoodi.txt

/var/lib/el/                    # Geth data directory (el user)
├── jwt.hex                     # JWT secret for EL-CL auth
└── [blockchain data]

/var/lib/cl/                    # Nimbus beacon data (cl user)
└── [consensus layer data]

/home/signer/                   # LUKS-encrypted partition
└── keys/                       # Validator keystores
    └── validators/             # Imported validator keys

/home/ethereum/                 # Main operator account
├── .ssh/authorized_keys        # SSH public keys
├── validator_keys/             # Staging for key import
└── control-panel.sh -> symlink # Quick access
```

---

## 3. User Architecture

### 3.1 User Table

| User | Type | Home Directory | Shell | Purpose |
|------|------|----------------|-------|---------|
| `ethereum` | Regular | `/home/ethereum` | `/bin/bash` | Main operator account for SSH access and node management |
| `el` | System | `/var/lib/el` | none | Runs Geth (Execution Layer) - owns blockchain data |
| `cl` | System | `/var/lib/cl` | none | Runs Nimbus Beacon Node (Consensus Layer) |
| `signer` | System | none | `/usr/sbin/nologin` | Runs Validator Client - owns encrypted keys |

### 3.2 User Permissions and Group Memberships

**ethereum user groups:**
- `sudo` - Execute commands as root
- `netdev` - Manage network interfaces
- `systemd-journal` - View system logs
- `dialout` - Access serial ports (UART)
- `plugdev` - Access USB devices

**Cross-user permissions:**
- `cl` user is added to `el` group to read JWT secret (`/var/lib/el/jwt.hex`)
- JWT file permissions: `640` (owner: el, group: el, readable by cl)

### 3.3 Service-to-User Mapping

```
┌─────────────────────────────────────────────────────────────────
│                    SERVICE ARCHITECTURE
├─────────────────────────────────────────────────────────────────
│
│   geth.service            ──► runs as: el
│   (Execution Layer)            port 8545 (HTTP-RPC)
│                                port 8546 (WebSocket)
│                                port 8551 (Auth-RPC)
│                                port 30303 (P2P)
│              │
│              │ JWT Auth
│              ▼
│   nimbus-beacon-node      ──► runs as: cl
│   (Consensus Layer)            port 5052 (REST API)
│                                port 9000 (P2P)
│              │
│              │ REST API
│              ▼
│   nimbus-validator        ──► runs as: signer
│   (Validator Client)           (no external ports)
│
```

---

## 4. LUKS Encrypted Partition

### 4.1 Purpose

The LUKS (Linux Unified Key Setup) encrypted partition provides hardware-level protection for validator keys. Even if the NVMe drive is physically stolen, the keys remain encrypted and inaccessible without the passphrase.

### 4.2 Technical Specifications

| Property | Value |
|----------|-------|
| Device | `/dev/nvme0n1p3` |
| Size | 2 GiB |
| Encryption | LUKS2 |
| Cipher | AES-XTS-plain64 |
| Key Size | 512 bits |
| KDF | Argon2id |
| Mount Point | `/home/signer` |
| Mapper Name | `signer_home` |

### 4.3 LUKS Workflow

```
                        BOOT SEQUENCE
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────
│                     LUKS LOCKED
│  Validator keys encrypted on /dev/nvme0n1p3
│  nimbus-validator service cannot start
│
                             │
         ┌───────────────────┴───────────────────
         │  sudo /opt/web3pi/unlock-luks.sh
         │  (requires passphrase)
         └───────────────────┬───────────────────
                             ▼
┌─────────────────────────────────────────────────────────────────
│                     LUKS UNLOCKED
│  /dev/mapper/signer_home mounted at /home/signer
│  Keys accessible to signer user
│
                             │
         ┌───────────────────┴───────────────────
         │  sudo /opt/web3pi/start-validator.sh
         └───────────────────┬───────────────────
                             ▼
┌─────────────────────────────────────────────────────────────────
│                   VALIDATOR RUNNING
│  nimbus-validator service active
│  Performing attestations and proposals
│
```

---

## 5. Ethereum Client Stack

### 5.1 Execution Layer: Geth

**Source**: Ethereum PPA (`ppa:ethereum/ethereum`)

**Configuration highlights** (`geth.service`):
- Sync mode: Snap sync
- State scheme: Path-based
- Cache: 4096 MB
- Memory limit: 10 GB (cgroups v2)
- JSON-RPC: localhost only (127.0.0.1:8545)
- WebSocket: localhost only (127.0.0.1:8546)
- Auth-RPC: localhost only (127.0.0.1:8551)
- P2P port: Configurable (default 30303)

### 5.2 Consensus Layer: Nimbus Beacon Node

**Source**: Status.im APT repository (`apt.status.im`)

**Configuration highlights** (`nimbus-beacon-node.service`):
- REST API: localhost only (127.0.0.1:5052)
- EL connection: http://127.0.0.1:8551
- JWT authentication: Reads `/var/lib/el/jwt.hex`
- P2P port: Configurable (default 9000)
- ENR auto-update: Enabled

### 5.3 Validator Client: Nimbus Validator

**Configuration highlights** (`nimbus-validator.service`):
- Data directory: `/home/signer/keys` (on LUKS)
- Beacon node: http://127.0.0.1:5052
- Fee recipient: Configurable via control panel
- Graffiti: Configurable (default "Web3Pi")

---

## 6. Network Configuration

### 6.1 Supported Ethereum Networks

| Network | Type | Checkpoint Sync Servers |
|---------|------|-------------------------|
| `hoodi` | Testnet (default) | 4 servers |
| `holesky` | Testnet | 4 servers |
| `mainnet` | Production | 8 servers |

### 6.2 Port Configuration

| Port | Protocol | Service | Direction |
|------|----------|---------|-----------|
| 22 | TCP | SSH | Inbound (rate limited) |
| 30303 | TCP/UDP | Geth P2P | Inbound |
| 9000 | TCP/UDP | Nimbus P2P | Inbound |
| 8545 | TCP | Geth HTTP-RPC | Localhost only |
| 8546 | TCP | Geth WebSocket | Localhost only |
| 8551 | TCP | Geth Auth-RPC | Localhost only |
| 5052 | TCP | Nimbus REST API | Localhost only |

---

## 7. Security Features

### 7.1 Firewall (nftables)

```
INPUT Chain (policy: DROP)
├── Accept loopback (required for EL-CL communication)
├── Accept established/related connections
├── Drop invalid packets
├── SSH: Rate limit 5/minute
├── Geth P2P: 30303 TCP/UDP
└── Nimbus P2P: 9000 TCP/UDP

OUTPUT Chain (policy: ACCEPT)
└── Drop invalid packets

FORWARD Chain (policy: DROP)
└── All blocked
```

### 7.2 SSH Security

- **Root login**: Disabled
- **Password authentication**: Enabled by default, can be disabled via control panel
- **Public key types supported**: ssh-ed25519, ssh-rsa, FIDO2 (sk-ssh-ed25519, sk-ecdsa)
- **FIDO2 hardware key enforcement**: Optional (can require hardware keys only)

### 7.3 System Hardening

- **Root account**: Locked (`passwd --lock root`)
- **IPv6**: Disabled system-wide
- **Service isolation**: Each service runs as dedicated user
- **Security flags**: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`
- **Unattended upgrades**: Automatically applied

---

## 8. Control Panel Features

The Control Panel (`/opt/web3pi/control-panel.sh`) provides a whiptail-based TUI for system management.

### 8.1 Main Menu Structure

```
Web3 Pi Staking Control Panel
├── 1. Eth Network Configuration
│   ├── Select Network (hoodi/holesky/mainnet)
│   ├── Configure Geth P2P Port
│   ├── Configure Nimbus P2P Port
│   └── View Current Config
│
├── 2. SSH Security
│   ├── Add SSH Public Key
│   ├── List Authorized Keys
│   ├── Remove SSH Key
│   ├── Toggle Password Authentication
│   ├── Toggle Public Key Authentication
│   ├── Require FIDO2 Hardware Key
│   └── Reload SSH Server
│
├── 3. LUKS Encrypted Storage
│   ├── Setup LUKS Partition
│   ├── Unlock LUKS
│   ├── Check Status
│   └── Change Passphrase
│
├── 4. Initial Sync
│   ├── Run Trusted Node Sync
│   └── Select Server Manually
│
├── 5. Service Management
│   ├── Geth (Execution Layer)
│   ├── Nimbus Beacon Node (Consensus Layer)
│   ├── Nimbus Validator
│   ├── View Logs
│   ├── Start All Services
│   └── Stop All Services
│
├── 6. Monitoring
│   ├── Sync Status (Geth & Nimbus) [auto-refresh]
│   ├── Peer Connections
│   ├── Resource Usage (RAM, CPU, Temps)
│   ├── Disk Usage
│   ├── System Overview
│   └── Network Info
│
├── 7. Data Management
│   ├── Wipe Geth Data
│   ├── Wipe Nimbus Beacon Data
│   ├── Wipe Signer Data
│   ├── Wipe ALL Data
│   └── View Disk Usage
│
├── 8. System
│   ├── Change Hostname
│   ├── Change ethereum Password
│   ├── Set Timezone
│   ├── Set Keyboard Layout
│   ├── Time Sync Status (Chrony)
│   ├── Edit Boot Config (config.txt)
│   ├── System Information
│   ├── Update Firmware (EEPROM)
│   │   ├── Release (stable)
│   │   └── Latest (beta from GitHub)
│   ├── OC (Pi-Under-Pressure)
│   │   ├── Install stress testing tool
│   │   └── Run Stress Test
│   ├── Reboot System
│   └── Shutdown System
│
├── 9. Validator Management
│   ├── Import Validator Keys
│   │   ├── From ~/validator_keys (SSH upload)
│   │   └── From USB drive
│   ├── List Validators
│   ├── Configure Fee Recipient
│   ├── Configure Graffiti
│   ├── Start Validator
│   ├── Stop Validator
│   ├── View Validator Status
│   └── Voluntary Exit (EXIT STAKING)
│
├── A. Arkiv [coming soon]
│
└── 0. Exit
```

### 8.2 Key Control Panel Features

#### Monitoring (Real-time)
- **Sync Status**: Auto-refreshes every 5 seconds, shows Geth block height, Nimbus slot, sync distance, backfill progress
- **Resource Usage**: RAM per-process (Geth, Nimbus BN, Nimbus VC), CPU load, temperatures (CPU, GPU, NVMe)
- **Peer Connections**: Geth and Nimbus peer counts via JSON-RPC/REST APIs

#### Validator Management
- **Key Import**: From staging directory (`~/validator_keys/`) or USB drive
- **Fee Recipient**: Ethereum address validation, warning for zero address
- **Voluntary Exit**: Two-step confirmation, requires beacon node sync and keystore file

#### System Management
- **Firmware Update**: Both release (stable) and latest (beta from GitHub master)
- **Pi-Under-Pressure**: Integrated stress testing tool for validating overclocking stability

---

## 9. Trusted Node Sync (Checkpoint Sync)

### 9.1 Purpose

Instead of syncing from genesis (which takes weeks), checkpoint sync downloads a recent finalized state from a trusted beacon node, enabling the node to be operational within minutes.

### 9.2 Sync Servers

**Mainnet**:
- https://sync.invis.tools
- https://mainnet-checkpoint-sync.stakely.io
- https://beaconstate.info
- https://sync-mainnet.beaconcha.in
- https://mainnet-checkpoint-sync.attestant.io
- https://beaconstate-mainnet.chainsafe.io
- https://checkpointz.pietjepuk.net
- https://mainnet.checkpoint.sigp.io

**Holesky**:
- https://checkpoint-sync.holesky.ethpandaops.io
- https://holesky.beaconstate.info
- https://beaconstate-holesky.chainsafe.io
- https://holesky-checkpoint-sync.stakely.io

**Hoodi**:
- https://checkpoint-sync.hoodi.ethpandaops.io
- https://hoodi.beaconstate.info
- https://hoodi-checkpoint-sync.attestant.io
- https://beaconstate-hoodi.chainsafe.io

### 9.3 Sync Workflow

1. Script tries each server in the list sequentially
2. Uses `nimbus_beacon_node trustedNodeSync` command
3. Downloads finalized state without backfill
4. On success, beacon node can start syncing from recent state

---

## 10. Configuration File

Central configuration is stored at `/opt/web3pi/config`:

```bash
# Web3 Pi Staking Configuration

# Network: hoodi, holesky, or mainnet
NETWORK=hoodi

# Geth P2P port (TCP/UDP)
GETH_PORT=30303

# Nimbus P2P port (TCP/UDP)
NIMBUS_PORT=9000

# Validator Configuration
# Fee recipient address for block rewards (REQUIRED for validator)
FEE_RECIPIENT=0x0000000000000000000000000000000000000000

# Graffiti message (max 32 characters, visible in proposed blocks)
GRAFFITI=Web3Pi
```

This file is sourced by all systemd service files via `EnvironmentFile=`.

---

## 11. Systemd Services

### 11.1 Service Dependency Chain

```
network-online.target
        │
        ▼
   geth.service
        │
        ▼
nimbus-beacon-node.service (Requires=geth.service)
        │
        ▼
nimbus-validator.service (manual start after LUKS unlock)
```

### 11.2 Service Details

| Service | User | Auto-start | Restart Policy |
|---------|------|------------|----------------|
| `geth` | el | No (manual) | on-failure (120s delay) |
| `nimbus-beacon-node` | cl | No (manual) | on-failure (120s delay) |
| `nimbus-validator` | signer | No (always manual) | on-failure (10s delay) |
| `nftables` | root | Yes | - |
| `rc-local` | root | Yes | oneshot |
| `ssh-keygen` | root | Yes (if keys missing) | oneshot |

---

## 12. WiFi Stability

WiFi power saving can cause intermittent connection drops, which is unacceptable for a staking node that requires constant connectivity. A udev rule disables WiFi power saving to improve connection stability:

```
/etc/udev/rules.d/99-wifi-powersave.rules:
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan0", RUN+="/usr/sbin/iw dev wlan0 set power_save off"
```

---

## 13. Installed Packages

### 13.1 System Utilities
- `chrony` - NTP time synchronization
- `avahi-daemon` - mDNS/DNS-SD
- `screen` - Terminal multiplexer
- `bpytop` - Resource monitor
- `neofetch` - System info display
- `dialog` - TUI dialogs
- `jq` - JSON processing

### 13.2 Storage & Security
- `cryptsetup` - LUKS encryption
- `nftables` - Firewall
- `rng-tools` - Random number generator
- `unattended-upgrades` - Auto updates

### 13.3 Development & Diagnostics
- `git`, `git-extras` - Version control
- `nvme-cli` - NVMe management
- `smartmontools` - Drive health
- `fio` - Storage benchmarking
- `stress-ng` - Stress testing
- `iotop` - I/O monitoring
- `speedtest-cli` - Network speed test

### 13.4 Ethereum Stack
- `ethereum` (Geth) - Execution layer client
- `nimbus-beacon-node` - Consensus layer beacon node
- `nimbus-validator-client` - Validator client

---

## 14. Build Configuration

### 14.1 config-w3p.conf

```bash
BOARD=rpi4b-w3p              # Raspberry Pi 5 (see note below)
BRANCH=current               # Latest LTS kernel
RELEASE=plucky               # Ubuntu 25.04
BUILD_DESKTOP=no             # Headless
BUILD_MINIMAL=yes            # Minimal base with CLI utils
NETWORKING_STACK="systemd-networkd"
LOCALE_DEFAULT="en_US.UTF-8"
TZDATA="Europe/Warsaw"
VENDORPRETTYNAME="Web3 Pi Staking"
CONSOLE_AUTOLOGIN=no
OPENSSHD_REGENERATE_HOST_KEYS=no  # Handled by ssh-keygen.service
PREFER_DOCKER=yes
```

**Note**: Despite the `BOARD=rpi4b-w3p` name, this configuration targets **Raspberry Pi 5**. This naming is a consequence of the Armbian Build System architecture where the bcm2711 board family covers both RPi 4 and RPi 5.

### 14.2 Board Definition (rpi4b-w3p.conf)

```bash
BOARD_NAME="Raspberry Pi"
BOARDFAMILY="bcm2711"
BOARD_MAINTAINER="Robert Mordzon"
KERNEL_TARGET="current,edge,legacy"
```

---

## 15. Development Timeline (Key Commits)

| Date Range | Features Added |
|------------|----------------|
| Initial | Basic customize-image.sh, user creation, APT packages |
| Early | rc.local first-boot script, logging infrastructure |
| Mid | LUKS encryption for validator keys, Ethereum service files |
| Mid | SSH key management, trusted node sync |
| Mid | nftables firewall, IPv6 disabled |
| Recent | Control Panel TUI with all modules |
| Recent | Validator management (import, fee recipient, graffiti) |
| Recent | Voluntary exit functionality |
| Recent | Firmware update (release and beta) |
| Recent | OC/stress testing integration (Pi-Under-Pressure) |
| Recent | WiFi stability fix, Geth cache optimization (4GB) |
| Latest | SSH key generation service, FIDO2 key support |

---

## 16. Typical User Workflow

### 16.1 Initial Setup

1. Flash image to NVMe (via Raspberry Pi Imager)
2. Boot Raspberry Pi 5
3. SSH to `ethereum@<hostname>` (default password: `ethereum`)
4. Change password on first login
5. Run `sudo ./control-panel.sh`

### 16.2 Node Setup

1. **Network Selection**: Configure network (hoodi/holesky/mainnet)
2. **Checkpoint Sync**: Run trusted node sync for fast initial sync
3. **Start Services**: Enable Geth and Nimbus beacon node
4. **Wait for Sync**: Monitor sync status until complete

### 16.3 Validator Setup

1. **LUKS Setup**: Create encrypted partition (`sudo /opt/web3pi/setup-luks.sh`)
2. **Key Upload**: SCP keystore files to `~/validator_keys/`
3. **Key Import**: Import keys via Control Panel
4. **Configure**: Set fee recipient address
5. **Unlock & Start**: Unlock LUKS and start validator

### 16.4 After Reboot

1. SSH into system
2. Unlock LUKS: `sudo /opt/web3pi/unlock-luks.sh`
3. Start validator: `sudo /opt/web3pi/start-validator.sh`
4. Or use Control Panel for both operations

---

## 17. Security Considerations

### 17.1 What This System Protects Against
- Remote attacks (firewall, no open services except SSH and P2P)
- Physical theft (LUKS encryption)
- Privilege escalation (service isolation, no root login)
- SSH brute force (rate limiting)
- Accidental slashing (encrypted keys, single device)

### 17.2 What This System Does NOT Protect Against
- Compromised operator workstation
- Passphrase disclosure
- Zero-day exploits in SSH/kernel
- Physical access with LUKS passphrase
- Side-channel attacks on the device

### 17.3 Recommended Additional Security
- Use FIDO2 hardware keys for SSH
- Store LUKS passphrase in a safe place
- Keep firmware updated
- Monitor validator performance via beaconcha.in or similar
- Regular backups of configuration (not validator keys on same device)

---

## 18. Technical Implementation Summary

### Build System
- Custom Armbian board definition `rpi4b-w3p.conf`
- Build configuration `config-w3p.conf` with all options
- Armbian Minimal base (`BUILD_MINIMAL=yes`)
- Docker-based build (`PREFER_DOCKER=yes`)
- Custom vendor name `VENDORPRETTYNAME="Web3 Pi Staking"`
- Disabled console autologin
- systemd-networkd networking stack
- Build wrapper script `build-analyze.sh` with error/warning summary

### Users & Permissions
- Pre-created `ethereum` user (main operator)
- Pre-created `el` system user (Geth)
- Pre-created `cl` system user (Nimbus beacon)
- Pre-created `signer` system user (validator, no shell)
- `ethereum` added to groups: sudo, netdev, systemd-journal, dialout, plugdev
- `cl` user added to `el` group for JWT access
- Secure permissions: `/var/lib/el` (750), `/var/lib/cl` (700)
- Home directory `/home/ethereum` with 750 permissions
- Staging directory `/home/ethereum/validator_keys` for key import

### Ethereum Clients
- Geth installed from Ethereum PPA
- Nimbus beacon node from apt.status.im
- Nimbus validator client from apt.status.im
- JWT secret auto-generated at build time
- Custom `geth.service` with environment file
- Custom `nimbus-beacon-node.service` with dependency on Geth
- Custom `nimbus-validator.service` (manual start)
- Geth cache set to 4096 MB
- Geth memory limit 10 GB (cgroups v2)
- Geth state.scheme=path (path-based storage)
- Geth snap sync mode
- Service security flags: NoNewPrivileges, PrivateTmp, ProtectSystem

### LUKS Encryption
- `setup-luks.sh` - one-time LUKS partition creation
- `unlock-luks.sh` - unlock LUKS and mount
- `start-validator.sh` - start validator after LUKS unlock
- LUKS2 with AES-XTS-plain64 cipher
- Argon2id key derivation function
- 512-bit key size
- 2 GiB encrypted partition on `/dev/nvme0n1p3`
- Mount point `/home/signer`
- Automatic partition creation if missing

### Trusted Node Sync
- `trusted-node-sync.sh` script
- Server list for mainnet (8 servers)
- Server list for holesky (4 servers)
- Server list for hoodi (4 servers)
- Automatic server fallback on failure
- Manual server selection option

### Network & Firewall
- nftables firewall (replaces UFW)
- INPUT policy: DROP
- OUTPUT policy: ACCEPT (required for P2P)
- FORWARD policy: DROP
- SSH rate limiting (5/minute)
- Geth P2P port 30303 TCP/UDP allowed
- Nimbus P2P port 9000 TCP/UDP allowed
- Loopback accepted for EL-CL communication
- IPv6 disabled system-wide (`/etc/sysctl.d/99-disable-ipv6.conf`)
- Configurable P2P ports via `/opt/web3pi/config`

### SSH Security
- `ssh-add-key.sh` - add SSH public key
- `ssh-disable-password.sh` - disable password auth
- Root SSH login disabled
- Support for ssh-ed25519 keys
- Support for ssh-rsa keys
- Support for FIDO2 hardware keys (sk-ssh-ed25519, sk-ecdsa)
- Optional FIDO2-only enforcement
- SSH key generation service before ssh.service
- Disabled Armbian SSH key regeneration (`OPENSSHD_REGENERATE_HOST_KEYS=no`)

### Control Panel (TUI)
- Main script `control-panel.sh`
- Modular architecture with separate modules
- Common library `lib/common.sh`
- Network configuration module
- SSH security module
- LUKS management module
- Sync management module
- Service management module
- Monitoring module
- Data management module
- System module
- Validator management module
- Symlink in `/home/ethereum/control-panel.sh`

### Control Panel - Network Module
- Network selection (hoodi/holesky/mainnet)
- Geth P2P port configuration
- Nimbus P2P port configuration
- View current configuration

### Control Panel - SSH Module
- Add SSH public key
- List authorized keys
- Remove SSH key
- Toggle password authentication
- Toggle public key authentication
- Require FIDO2 hardware key option
- Reload SSH server

### Control Panel - LUKS Module
- Setup LUKS partition
- Unlock LUKS
- Check status
- Change passphrase

### Control Panel - Sync Module
- Run trusted node sync
- Manual server selection

### Control Panel - Services Module
- Individual service control (start/stop/restart)
- Enable/disable service on boot
- View service status
- View logs (journalctl)
- Start all services
- Stop all services

### Control Panel - Monitoring Module
- Sync status with auto-refresh (5 seconds)
- Geth sync status via JSON-RPC
- Nimbus sync status via REST API
- Backfill progress detection from logs
- Geth indexing detection from logs
- Peer connections count
- Resource usage (RAM per process)
- CPU load average
- Temperature monitoring (CPU, GPU, NVMe)
- Disk usage per directory
- System overview
- Network info (IP, hostname)

### Control Panel - Data Module
- Wipe Geth data
- Wipe Nimbus beacon data
- Wipe signer data
- Wipe ALL data
- View disk usage
- Double confirmation for destructive operations

### Control Panel - System Module
- Change hostname (RFC 1123 validation)
- Change ethereum password
- Set timezone (preset list + manual)
- Set keyboard layout
- Time sync status (Chrony details)
- Edit boot config (`/boot/firmware/config.txt`)
- System information display
- Firmware update (release branch)
- Firmware update (latest/beta from GitHub)
- OC (Pi-Under-Pressure) installation
- OC stress test execution
- Reboot system
- Shutdown system

### Control Panel - Validator Module
- Import validator keys from staging directory
- Import validator keys from USB drive
- List imported validators
- Configure fee recipient (address validation)
- Configure graffiti (32 char limit)
- Start validator (with LUKS check)
- Stop validator
- View validator status
- Voluntary exit (two-step confirmation)
- Keystore file handling for voluntary exit
- Move keystores to encrypted storage after import

### First Boot (rc.local)
- Installation stage tracking (`/root/.install_stage`)
- Network connectivity check (curl to github.com)
- NTP time synchronization (chronyd -q)
- Ethereum user home directory setup
- Control panel symlink creation
- Force password change on first login
- Wait for apt locks before upgrades
- Unattended upgrades configuration
- Welcome message with IP and hostname

### System Packages
- chrony (NTP)
- avahi-daemon (mDNS)
- screen
- bpytop
- neofetch
- dialog
- jq
- cryptsetup
- nftables
- rng-tools
- unattended-upgrades
- git, git-extras
- nvme-cli
- smartmontools
- fio
- stress-ng
- iotop
- speedtest-cli
- vim
- net-tools
- telnet
- gdisk

### System Configuration
- Custom MOTD banner "Web3 Pi Staking"
- VENDORPRETTYNAME fix in `/etc/armbian-image-release`
- Removed `.not_logged_in_yet` file
- Enabled MOTD scripts (`chmod +x /etc/update-motd.d/*`)
- Central configuration file `/opt/web3pi/config`
- Logs directory `/opt/web3pi/logs`
- rpi-eeprom cloned for firmware updates

### WiFi Stability
- udev rule to disable WiFi power save
- Rule file: `/etc/udev/rules.d/99-wifi-powersave.rules`
- Triggered on wlan0 interface add

### Security Hardening
- Root account locked (`passwd --lock root`)
- Root SSH login disabled
- Service isolation (dedicated users)
- systemd security flags on all services
- JWT secret with restricted permissions (640)
- Validator keys on encrypted partition
- No desktop environment
- Minimal package set

### Systemd Services
- `rc-local.service` for first-boot scripts
- `ssh-keygen.service` for SSH key generation
- `geth.service` with EnvironmentFile
- `nimbus-beacon-node.service` with Geth dependency
- `nimbus-validator.service` (manual start)
- nftables service enabled

---

*Document generated from codebase analysis on branch w3p-v25.11*
