#!/bin/bash
#
# Web3 Pi Staking OS install script
#
echo "[install.sh] - start at $(date '+%Y-%m-%d %H:%M:%S')"


# Print the IP address
_IP=$(hostname -I) || true
if [ "$_IP" ]; then
  printf "\n\n\nRaspberry Pi IP address is %s\n\n\n" "$_IP"
fi


echo "[install.sh] - exit 0 at $(date '+%Y-%m-%d %H:%M:%S')"
exit 0
