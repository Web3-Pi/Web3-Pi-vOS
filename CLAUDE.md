# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Web3-Pi-vOS is a customized Armbian build framework for creating Ethereum staking images on Raspberry Pi 5. It extends the official Armbian Build Framework with Web3/Ethereum-specific layers.

## Build Commands

```bash
# Build Web3 Pi image (uses userpatches/config-w3p.conf)
./compile.sh w3p

# Build in Docker container (recommended)
PREFER_DOCKER=yes ./compile.sh w3p

# Output location
output/images/Armbian-unofficial_*_Rpi4b-w3p_*.img
```

## Architecture

### Two-Phase Setup

1. **Build-time (chroot)**: `userpatches/customize-image.sh` runs inside the image during build
   - Creates users, installs packages, configures security
   - Files in `userpatches/overlay/` are copied to the image

2. **First-boot (runtime)**: `userpatches/overlay/rc.local` runs on the actual device
   - Creates LUKS-encrypted partition for validator keys
   - Completes user setup, mounts encrypted storage
   - Tracks installation stage via `/root/.install_stage` (0-100)

### User Architecture

| User | Purpose | Home |
|------|---------|------|
| `ethereum` | Main staking operator | `/home/ethereum` |
| `el` | Execution layer (Geth) | `/var/lib/el` |
| `cl` | Consensus layer (Nimbus) | `/var/lib/cl` |
| `signer` | Validator key signing (no shell) | `/home/signer` |

### LUKS Encrypted Partition

Validator keys are stored on an encrypted partition:
- Partition: `/dev/nvme0n1p3` (100 MiB)
- Keyfile: `/root/.luks_keyfile`
- Mount point: `/home/signer/.keys`
- Encryption: LUKS2, AES-XTS-plain64, Argon2id

## Key Files

| File | Purpose |
|------|---------|
| `userpatches/config-w3p.conf` | Build configuration (board, release, options) |
| `userpatches/customize-image.sh` | Chroot customization script |
| `userpatches/overlay/rc.local` | First-boot setup script |
| `config/boards/rpi4b-w3p.conf` | Board definition |

## Pre-installed Ethereum Clients

- **Nimbus**: Beacon node + validator client (from apt.status.im)
- **Geth**: Execution layer (from Ethereum PPA)

## Customization Pattern

To add new functionality:
1. **During build**: Add to `userpatches/customize-image.sh` (runs in chroot, no hardware access)
2. **At runtime**: Add to `userpatches/overlay/rc.local` (has full hardware access)
3. **Files to copy**: Place in `userpatches/overlay/` (copied to image root)

Note: `customize-image.sh` cannot access NVMe or other hardware - use `rc.local` for hardware-dependent operations.
