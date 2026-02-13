#!/bin/bash
#
# Web3 Pi - CPU Frequency Safety Clamp
# Runs at early boot (sysinit.target) to set a safe max frequency.
#
# config.txt sets arm_freq to a high ceiling (e.g., 3000 MHz),
# but this script immediately clamps the actual operating frequency
# to a known-safe value read from /opt/web3pi/oc-config.
#
# If no detection has been run yet, falls back to 2400 MHz (stock Pi5).

OC_CONFIG="/opt/web3pi/oc-config"
OC_PROGRESS="/opt/web3pi/oc-detect-progress"
DEFAULT_SAFE_FREQ=2400000  # 2400 MHz in kHz - stock Pi5 frequency
LOG_TAG="cpu-freq-safe"

# Read detected safe max frequency from OC config
SAFE_MAX_FREQ="$DEFAULT_SAFE_FREQ"
if [ -f "$OC_CONFIG" ]; then
    . "$OC_CONFIG"
    if [ -n "$OC_DETECTED_MAX_FREQ" ] && [ "$OC_DETECTED_MAX_FREQ" -gt 0 ] 2>/dev/null; then
        SAFE_MAX_FREQ="$OC_DETECTED_MAX_FREQ"
    fi
fi

# Check for interrupted OC detection (e.g. kernel panic during stress test)
# Progress file contains the last frequency that passed stress testing
if [ -f "$OC_PROGRESS" ]; then
    PROGRESS_FREQ=$(cat "$OC_PROGRESS" 2>/dev/null || echo "0")
    if [ "$PROGRESS_FREQ" -gt 0 ] 2>/dev/null; then
        logger -t "$LOG_TAG" "WARNING: OC detection was interrupted (crash/panic). Last stable freq: ${PROGRESS_FREQ} kHz"
        # Use the higher of config vs progress (don't downgrade from previous detection)
        if [ "$PROGRESS_FREQ" -gt "$SAFE_MAX_FREQ" ]; then
            SAFE_MAX_FREQ="$PROGRESS_FREQ"
        fi
    fi
    # Clean up progress file so this only triggers once
    rm -f "$OC_PROGRESS"
fi

logger -t "$LOG_TAG" "Applying CPU frequency clamp: max=${SAFE_MAX_FREQ} kHz"

# Apply to ALL CPU cores
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    freq_dir="${cpu_dir}/cpufreq"
    [ -d "$freq_dir" ] || continue

    # Set governor to powersave first (forces lowest frequency)
    echo "powersave" > "${freq_dir}/scaling_governor" 2>/dev/null || true
    # Set the max frequency clamp
    echo "$SAFE_MAX_FREQ" > "${freq_dir}/scaling_max_freq" 2>/dev/null || true
    # Set governor to ondemand for normal operation
    # (scales up to scaling_max_freq under load, never beyond)
    echo "ondemand" > "${freq_dir}/scaling_governor" 2>/dev/null || true
done

logger -t "$LOG_TAG" "CPU frequency clamp applied: max=${SAFE_MAX_FREQ} kHz"
