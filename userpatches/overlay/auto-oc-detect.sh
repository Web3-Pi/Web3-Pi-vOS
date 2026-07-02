#!/bin/bash
#
# Web3 Pi - Automatic Overclock Detection
# Discovers the maximum stable CPU frequency for this specific Raspberry Pi 5.
#
# Usage: auto-oc-detect.sh [--start FREQ_KHZ] [--end FREQ_KHZ]
#                          [--step STEP_KHZ] [--duration SECONDS]
#                          [--max-temp CELSIUS]
#
# Must be run as root.

set -euo pipefail

# =============================================================================
# Configuration defaults (all frequencies in kHz)
# =============================================================================
START_FREQ=2400000       # Start from 2400 MHz (stock Pi5)
END_FREQ=3200000         # Maximum to try (must match config.txt arm_freq)
STEP_SIZE=100000         # 100 MHz steps
STRESS_DURATION=180      # Seconds of stress per step (3 minutes)
CONFIRM_DURATION=300     # Seconds for final confirmation test (5 minutes)
MAX_TEMP=85              # Celsius - abort step if exceeded
COOLDOWN_TEMP=55         # Wait until CPU cools to this before next step
COOLDOWN_TIMEOUT=120     # Max seconds to wait for cooldown
OC_CONFIG="/opt/web3pi/oc-config"
OC_PROGRESS="/opt/web3pi/oc-detect-progress"
OC_LOG="/opt/web3pi/logs/auto-oc-detect.log"
LOCK_FILE="/tmp/auto-oc-detect.lock"
NUM_CORES=$(nproc)

# =============================================================================
# Parse CLI arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)    START_FREQ="$2"; shift 2 ;;
        --end)      END_FREQ="$2"; shift 2 ;;
        --step)     STEP_SIZE="$2"; shift 2 ;;
        --duration) STRESS_DURATION="$2"; shift 2 ;;
        --confirm-duration) CONFIRM_DURATION="$2"; shift 2 ;;
        --max-temp) MAX_TEMP="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: auto-oc-detect.sh [OPTIONS]"
            echo "  --start FREQ_KHZ         Start frequency (default: 2400000)"
            echo "  --end FREQ_KHZ           End frequency (default: 3200000)"
            echo "  --step STEP_KHZ          Step size (default: 100000)"
            echo "  --duration SECS          Stress duration per step (default: 180)"
            echo "  --confirm-duration SECS  Confirmation test duration (default: 300)"
            echo "  --max-temp CELSIUS       Max temperature limit (default: 85)"
            exit 0
            ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Safety checks
# =============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must be run as root"
    exit 1
fi

if ! command -v stress-ng &>/dev/null; then
    echo "ERROR: stress-ng not found (should be pre-installed)"
    exit 1
fi

if ! command -v vcgencmd &>/dev/null; then
    echo "ERROR: vcgencmd not found (Raspberry Pi required)"
    exit 1
fi

# Verify NEON/SIMD stressors are available in this stress-ng version
if ! stress-ng --matrix 0 --timeout 1s &>/dev/null; then
    echo "ERROR: stress-ng does not support --matrix stressor (version too old?)"
    exit 1
fi

# Prevent concurrent runs
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "ERROR: Another OC detection is already running"
    exit 1
fi

# Ensure log directory exists
mkdir -p "$(dirname "$OC_LOG")"

# Check hardware max supports our END_FREQ
HW_MAX=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "0")
if [ "$HW_MAX" -eq 0 ]; then
    echo "ERROR: Cannot read cpuinfo_max_freq"
    exit 1
fi
if [ "$END_FREQ" -gt "$HW_MAX" ]; then
    echo "NOTE: END_FREQ ($END_FREQ) exceeds hardware max ($HW_MAX), clamping"
    END_FREQ="$HW_MAX"
fi

# =============================================================================
# Helper functions
# =============================================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$OC_LOG"
}

get_cpu_temp() {
    local temp
    temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    echo $((temp / 1000))
}

get_throttle_status() {
    vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "0x0"
}

is_throttled_now() {
    # Check current throttle bits (bits 1-3):
    #   Bit 1: Arm frequency capped
    #   Bit 2: Currently throttled
    #   Bit 3: Soft temperature limit active
    local status="$1"
    local val=$((status))
    [ $((val & 0xE)) -ne 0 ]
}

has_throttle_history() {
    # Check historical throttle bits (bits 17-19):
    #   Bit 17: Arm frequency capping has occurred
    #   Bit 18: Throttling has occurred
    #   Bit 19: Soft temperature limit has occurred
    local status="$1"
    local val=$((status))
    [ $((val & 0xE0000)) -ne 0 ]
}

is_under_voltage() {
    # Bit 0: Under-voltage detected (current)
    # Bit 16: Under-voltage has occurred (historical)
    local status="$1"
    local val=$((status))
    [ $((val & 0x10001)) -ne 0 ]
}

set_all_cpus() {
    local freq="$1"
    local governor="$2"
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -d "$cpu_dir" ] || continue
        echo "$governor" > "${cpu_dir}/scaling_governor" 2>/dev/null || true
        echo "$freq" > "${cpu_dir}/scaling_max_freq" 2>/dev/null || true
        if [ "$governor" = "performance" ]; then
            echo "$freq" > "${cpu_dir}/scaling_min_freq" 2>/dev/null || true
        fi
    done
}

restore_safe_freq() {
    log "Restoring safe frequency..."
    # Clean up progress file on normal exit / Ctrl+C
    # (kernel panic won't reach here - that's intentional, boot script will recover)
    rm -f "$OC_PROGRESS"
    local safe_freq=2400000
    if [ -f "$OC_CONFIG" ]; then
        . "$OC_CONFIG"
        if [ -n "${OC_DETECTED_MAX_FREQ:-}" ] && [ "$OC_DETECTED_MAX_FREQ" -gt 0 ] 2>/dev/null; then
            safe_freq="$OC_DETECTED_MAX_FREQ"
        fi
    fi
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [ -d "$cpu_dir" ] || continue
        echo "powersave" > "${cpu_dir}/scaling_governor" 2>/dev/null || true
        echo 600000 > "${cpu_dir}/scaling_min_freq" 2>/dev/null || true
        echo "$safe_freq" > "${cpu_dir}/scaling_max_freq" 2>/dev/null || true
        echo "ondemand" > "${cpu_dir}/scaling_governor" 2>/dev/null || true
    done
    log "Restored to ${safe_freq} kHz"
}

wait_for_cooldown() {
    local target_temp="$1"
    local timeout="$2"
    local waited=0
    local temp

    temp=$(get_cpu_temp)
    if [ "$temp" -le "$target_temp" ]; then
        return 0
    fi

    log "Waiting for cooldown below ${target_temp}C (currently ${temp}C)..."
    while [ "$waited" -lt "$timeout" ]; do
        sleep 5
        waited=$((waited + 5))
        temp=$(get_cpu_temp)
        if [ "$temp" -le "$target_temp" ]; then
            log "Cooled to ${temp}C"
            return 0
        fi
    done

    log "WARNING: Cooldown timeout (still ${temp}C after ${timeout}s)"
    return 1
}

# =============================================================================
# Stress test function (NEON/SIMD focused)
# =============================================================================
# Run a stress test at the current CPU frequency and monitor for failures.
# Arguments:
#   $1 - duration in seconds
#   $2 - frequency label (for logging, e.g., "2800 MHz")
#   $3 - phase label (e.g., "detection" or "confirmation")
# Returns 0 if stable, 1 if failed.
run_stress_test() {
    local duration="$1"
    local freq_label="$2"
    local phase_label="$3"

    log "Running NEON stress test [${phase_label}] for ${duration}s at ${freq_label}..."

    stress-ng --matrix "$NUM_CORES" --matrix-size 128 \
              --vecmath "$NUM_CORES" \
              --timeout "${duration}s" \
              --metrics-brief 2>>"$OC_LOG" &
    local stress_pid=$!

    local elapsed=0
    local stress_failed=false
    while kill -0 "$stress_pid" 2>/dev/null; do
        sleep 5
        elapsed=$((elapsed + 5))

        local current_temp
        current_temp=$(get_cpu_temp)
        local current_throttle
        current_throttle=$(get_throttle_status)

        # Periodic status
        if [ $((elapsed % 15)) -eq 0 ]; then
            local current_actual
            current_actual=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
            log "  [${phase_label}][${elapsed}s] temp=${current_temp}C freq=$((current_actual/1000))MHz throttle=${current_throttle}"
            echo "  [${elapsed}s/${duration}s] temp=${current_temp}C"
        fi

        # Temperature limit
        if [ "$current_temp" -ge "$MAX_TEMP" ]; then
            log "FAIL [${phase_label}]: Temperature ${current_temp}C exceeded limit ${MAX_TEMP}C"
            echo "  FAIL: Temperature ${current_temp}C > ${MAX_TEMP}C limit"
            kill "$stress_pid" 2>/dev/null || true
            wait "$stress_pid" 2>/dev/null || true
            stress_failed=true
            break
        fi

        # Throttling
        if is_throttled_now "$current_throttle"; then
            log "FAIL [${phase_label}]: Throttling detected (${current_throttle}) at ${freq_label}"
            echo "  FAIL: CPU throttling at ${freq_label}"
            kill "$stress_pid" 2>/dev/null || true
            wait "$stress_pid" 2>/dev/null || true
            stress_failed=true
            break
        fi
    done

    # Wait for stress-ng to finish
    wait "$stress_pid" 2>/dev/null
    local stress_exit=$?

    if [ "$stress_exit" -ne 0 ] && [ "$stress_failed" = false ]; then
        log "FAIL [${phase_label}]: stress-ng exited with code ${stress_exit} at ${freq_label}"
        echo "  FAIL: stress-ng error (exit code ${stress_exit})"
        stress_failed=true
    fi

    # Post-stress checks
    local post_throttle
    post_throttle=$(get_throttle_status)
    local post_temp
    post_temp=$(get_cpu_temp)
    log "Post-stress [${phase_label}]: temp=${post_temp}C, throttle=${post_throttle}"

    if [ "$stress_failed" = false ] && has_throttle_history "$post_throttle"; then
        log "FAIL [${phase_label}]: Historical throttling detected (${post_throttle}) at ${freq_label}"
        echo "  FAIL: Throttling occurred during test"
        stress_failed=true
    fi

    if [ "$stress_failed" = true ]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Trap: always restore safe frequency on exit
# =============================================================================
trap restore_safe_freq EXIT

# =============================================================================
# Main detection loop
# =============================================================================
log "============================================================"
log "  Web3 Pi - Auto Overclock Detection"
log "============================================================"
log "  Range:     ${START_FREQ} - ${END_FREQ} kHz"
log "  Step:      ${STEP_SIZE} kHz"
log "  Stress:    ${STRESS_DURATION}s per step (NEON/SIMD)"
log "  Confirm:   ${CONFIRM_DURATION}s at detected max"
log "  Max temp:  ${MAX_TEMP}C"
log "  Cooldown:  ${COOLDOWN_TEMP}C"
log "  CPU cores: ${NUM_CORES}"
log "  HW max:    ${HW_MAX} kHz"
log "============================================================"

echo ""
echo "  Range:     $((START_FREQ / 1000)) - $((END_FREQ / 1000)) MHz"
echo "  Step:      $((STEP_SIZE / 1000)) MHz"
echo "  Stress:    ${STRESS_DURATION}s per step (NEON/SIMD)"
echo "  Confirm:   ${CONFIRM_DURATION}s at detected max"
echo "  Max temp:  ${MAX_TEMP}C"
echo ""

# Build list of frequencies to test
FREQ_LIST=()
f=$START_FREQ
while [ "$f" -le "$END_FREQ" ]; do
    FREQ_LIST+=("$f")
    f=$((f + STEP_SIZE))
done
TOTAL_STEPS=${#FREQ_LIST[@]}

LAST_STABLE_FREQ=0
STEP_NUM=0

# Create progress file - survives kernel panic so boot script can recover
echo "0" > "$OC_PROGRESS"
sync

for CURRENT_FREQ in "${FREQ_LIST[@]}"; do
    STEP_NUM=$((STEP_NUM + 1))
    FREQ_MHZ=$((CURRENT_FREQ / 1000))

    log ""
    log "--- Step $STEP_NUM/$TOTAL_STEPS: Testing ${FREQ_MHZ} MHz ---"
    echo "[$STEP_NUM/$TOTAL_STEPS] Testing ${FREQ_MHZ} MHz..."

    # Wait for cooldown before each step
    if ! wait_for_cooldown "$COOLDOWN_TEMP" "$COOLDOWN_TIMEOUT"; then
        log "Stopping: CPU too hot to continue"
        echo "  STOPPED: CPU too hot"
        break
    fi

    # Clear throttle history by reading
    vcgencmd get_throttled > /dev/null 2>&1 || true
    sleep 1

    # Set target frequency with performance governor
    set_all_cpus "$CURRENT_FREQ" "performance"
    sleep 2  # Let frequency settle

    # Verify frequency was set
    ACTUAL_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
    log "Requested: ${FREQ_MHZ} MHz, Actual: $((ACTUAL_FREQ / 1000)) MHz"

    # Skip if the CPU doesn't support this exact frequency
    # (Pi 5 uses discrete frequency steps; the kernel rounds to the nearest valid one)
    if [ "$((ACTUAL_FREQ / 1000))" -ne "$FREQ_MHZ" ]; then
        log "SKIP: ${FREQ_MHZ} MHz not a valid CPU frequency (actual: $((ACTUAL_FREQ / 1000)) MHz)"
        echo "  SKIP: ${FREQ_MHZ} MHz not available (nearest: $((ACTUAL_FREQ / 1000)) MHz)"
        continue
    fi

    # Check pre-stress state
    PRE_THROTTLE=$(get_throttle_status)
    PRE_TEMP=$(get_cpu_temp)
    log "Pre-stress: temp=${PRE_TEMP}C, throttle=${PRE_THROTTLE}"

    if is_throttled_now "$PRE_THROTTLE"; then
        log "FAIL: Already throttled before stress at ${FREQ_MHZ} MHz"
        echo "  FAIL: Throttled before stress"
        break
    fi

    if is_under_voltage "$PRE_THROTTLE"; then
        log "WARNING: Under-voltage detected! Use official Pi 5.1V 5A PSU."
        echo "  WARNING: Under-voltage! Check power supply."
    fi

    # Run NEON/SIMD stress test
    if run_stress_test "$STRESS_DURATION" "${FREQ_MHZ} MHz" "detection"; then
        LAST_STABLE_FREQ=$CURRENT_FREQ
        echo "$LAST_STABLE_FREQ" > "$OC_PROGRESS"
        sync
        log "RESULT: ${FREQ_MHZ} MHz is STABLE (progress saved)"
        echo "  OK: ${FREQ_MHZ} MHz stable (temp: $(get_cpu_temp)C)"
    else
        log "RESULT: ${FREQ_MHZ} MHz is NOT stable"
        break
    fi
done

# =============================================================================
# Confirmation test phase
# =============================================================================
CONFIRM_PASSED=false

if [ "$LAST_STABLE_FREQ" -gt 0 ]; then
    log ""
    log "============================================================"
    log "  CONFIRMATION PHASE"
    log "============================================================"

    CONFIRM_FREQ=$LAST_STABLE_FREQ

    while [ "$CONFIRM_FREQ" -ge "$START_FREQ" ]; do
        CONFIRM_MHZ=$((CONFIRM_FREQ / 1000))

        log ""
        log "--- Confirmation test: ${CONFIRM_MHZ} MHz for ${CONFIRM_DURATION}s ---"
        echo ""
        echo "  CONFIRMATION: Testing ${CONFIRM_MHZ} MHz for ${CONFIRM_DURATION}s ($(( CONFIRM_DURATION / 60 )) minutes)..."

        # Cooldown before confirmation
        if ! wait_for_cooldown "$COOLDOWN_TEMP" "$COOLDOWN_TIMEOUT"; then
            log "WARNING: Cooldown timeout before confirmation, proceeding anyway"
        fi

        # Clear throttle history
        vcgencmd get_throttled > /dev/null 2>&1 || true
        sleep 1

        # Set frequency
        set_all_cpus "$CONFIRM_FREQ" "performance"
        sleep 2

        # Verify frequency was actually applied
        ACTUAL_CONFIRM=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
        if [ "$((ACTUAL_CONFIRM / 1000))" -ne "$CONFIRM_MHZ" ]; then
            log "SKIP confirmation: ${CONFIRM_MHZ} MHz not valid (actual: $((ACTUAL_CONFIRM / 1000)) MHz), stepping down"
            echo "  SKIP: ${CONFIRM_MHZ} MHz not available, stepping down..."
            CONFIRM_FREQ=$((CONFIRM_FREQ - STEP_SIZE))
            continue
        fi

        if run_stress_test "$CONFIRM_DURATION" "${CONFIRM_MHZ} MHz" "confirmation"; then
            log "CONFIRMATION PASSED: ${CONFIRM_MHZ} MHz is stable for ${CONFIRM_DURATION}s"
            echo "  CONFIRMED: ${CONFIRM_MHZ} MHz stable for ${CONFIRM_DURATION}s"
            LAST_STABLE_FREQ=$CONFIRM_FREQ
            echo "$LAST_STABLE_FREQ" > "$OC_PROGRESS"
            sync
            CONFIRM_PASSED=true
            break
        else
            log "CONFIRMATION FAILED at ${CONFIRM_MHZ} MHz, stepping down..."
            echo "  Confirmation FAILED at ${CONFIRM_MHZ} MHz, trying lower..."

            CONFIRM_FREQ=$((CONFIRM_FREQ - STEP_SIZE))
        fi
    done

    if [ "$CONFIRM_PASSED" = false ]; then
        log "WARNING: No frequency passed confirmation! Falling back to stock."
        echo "  WARNING: No frequency passed confirmation test."
        LAST_STABLE_FREQ=2400000
    fi
fi

# =============================================================================
# Results
# =============================================================================
log ""
log "============================================================"
log "  DETECTION COMPLETE"
log "============================================================"

if [ "$LAST_STABLE_FREQ" -eq 0 ]; then
    log "WARNING: No stable frequency found! Using default: 2400 MHz"
    LAST_STABLE_FREQ=2400000
fi

RESULT_MHZ=$((LAST_STABLE_FREQ / 1000))
log "Maximum stable frequency: ${RESULT_MHZ} MHz"
log "Confirmation test: $([ "$CONFIRM_PASSED" = true ] && echo "PASSED" || echo "FAILED/SKIPPED")"
log "============================================================"

# Save result
cat > "$OC_CONFIG" << EOF
# Web3 Pi - Auto OC Detection Results
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT EDIT MANUALLY - use auto-oc-detect.sh or control panel

# Maximum stable frequency detected (in kHz)
OC_DETECTED_MAX_FREQ=$LAST_STABLE_FREQ

# Detection parameters
OC_DETECT_START=$START_FREQ
OC_DETECT_END=$END_FREQ
OC_DETECT_STEP=$STEP_SIZE
OC_DETECT_STRESS_DURATION=$STRESS_DURATION
OC_DETECT_CONFIRM_DURATION=$CONFIRM_DURATION
OC_DETECT_CONFIRM_PASSED=$CONFIRM_PASSED
OC_DETECT_MAX_TEMP=$MAX_TEMP
OC_DETECT_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
OC_DETECT_HW_MAX=$HW_MAX
EOF

# Remove progress file - final result is now in oc-config
rm -f "$OC_PROGRESS"

echo ""
echo "============================================================"
echo "  Maximum stable frequency: ${RESULT_MHZ} MHz"
if [ "$CONFIRM_PASSED" = true ]; then
    echo "  Confirmation test:        PASSED (${CONFIRM_DURATION}s)"
else
    echo "  Confirmation test:        NOT PASSED"
fi
echo "  Results saved to: $OC_CONFIG"
echo "  Reboot to apply the new frequency."
echo "============================================================"
echo ""

# Check for under-voltage warning
FINAL_THROTTLE=$(get_throttle_status)
if is_under_voltage "$FINAL_THROTTLE"; then
    log "WARNING: Under-voltage detected during test. Use official Pi 5.1V 5A PSU."
    echo "  WARNING: Under-voltage detected! Results may be unreliable."
    echo "  Use the official Raspberry Pi 5.1V 5A power supply."
    echo ""
fi

# Pi-Under-Pressure recommendation
echo "---------------------------------------------------------------"
echo "  RECOMMENDATION: For full confidence in your overclock"
echo "  stability, run a longer comprehensive stress test using"
echo "  Pi-Under-Pressure (available in the System menu of the"
echo "  Web3 Pi control panel, or via CLI):"
echo ""
echo "    pi-under-pressure -d 1h"
echo ""
echo "  This exercises CPU, memory, and I/O simultaneously for a"
echo "  more thorough validation of your overclock settings."
echo "---------------------------------------------------------------"
echo ""
log "RECOMMENDATION: Run pi-under-pressure -d 1h for comprehensive validation."

# EXIT trap will call restore_safe_freq
exit 0
