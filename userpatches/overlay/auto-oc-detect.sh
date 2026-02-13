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
STEP_SIZE=100000         # 100 MHz steps (below FINE_STEP_FROM)
FINE_STEP_SIZE=50000     # 50 MHz steps (at and above FINE_STEP_FROM)
FINE_STEP_FROM=2800000   # Switch to fine steps from 2800 MHz
STRESS_DURATION=60       # Seconds of stress per step
MAX_TEMP=85              # Celsius - abort step if exceeded
COOLDOWN_TEMP=55         # Wait until CPU cools to this before next step
COOLDOWN_TIMEOUT=120     # Max seconds to wait for cooldown
OC_CONFIG="/opt/web3pi/oc-config"
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
        --max-temp) MAX_TEMP="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: auto-oc-detect.sh [OPTIONS]"
            echo "  --start FREQ_KHZ    Start frequency (default: 2400000)"
            echo "  --end FREQ_KHZ      End frequency (default: 3000000)"
            echo "  --step STEP_KHZ     Step size (default: 100000)"
            echo "  --duration SECS     Stress duration per step (default: 60)"
            echo "  --max-temp CELSIUS  Max temperature limit (default: 80)"
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
log "  Step:      ${STEP_SIZE}/${FINE_STEP_SIZE} kHz (switch at ${FINE_STEP_FROM})"
log "  Stress:    ${STRESS_DURATION}s per step"
log "  Max temp:  ${MAX_TEMP}C"
log "  Cooldown:  ${COOLDOWN_TEMP}C"
log "  CPU cores: ${NUM_CORES}"
log "  HW max:    ${HW_MAX} kHz"
log "============================================================"

echo ""
echo "  Range:     $((START_FREQ / 1000)) - $((END_FREQ / 1000)) MHz"
echo "  Step:      $((STEP_SIZE / 1000)) MHz (below $((FINE_STEP_FROM / 1000))), $((FINE_STEP_SIZE / 1000)) MHz (above)"
echo "  Stress:    ${STRESS_DURATION}s per step"
echo "  Max temp:  ${MAX_TEMP}C"
echo ""

# Build list of frequencies to test
FREQ_LIST=()
f=$START_FREQ
while [ "$f" -le "$END_FREQ" ]; do
    FREQ_LIST+=("$f")
    if [ "$f" -ge "$FINE_STEP_FROM" ]; then
        f=$((f + FINE_STEP_SIZE))
    else
        f=$((f + STEP_SIZE))
    fi
done
TOTAL_STEPS=${#FREQ_LIST[@]}

LAST_STABLE_FREQ=0
STEP_NUM=0

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

    # Run stress test in background
    log "Running stress-ng for ${STRESS_DURATION}s on ${NUM_CORES} cores..."
    STRESS_FAILED=false

    stress-ng --cpu "$NUM_CORES" --cpu-method all \
              --timeout "${STRESS_DURATION}s" \
              --metrics-brief 2>>"$OC_LOG" &
    STRESS_PID=$!

    # Monitor during stress
    ELAPSED=0
    while kill -0 "$STRESS_PID" 2>/dev/null; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))

        CURRENT_TEMP=$(get_cpu_temp)
        CURRENT_THROTTLE=$(get_throttle_status)

        # Periodic status
        if [ $((ELAPSED % 15)) -eq 0 ]; then
            CURRENT_ACTUAL=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
            log "  [${ELAPSED}s] temp=${CURRENT_TEMP}C freq=$((CURRENT_ACTUAL/1000))MHz throttle=${CURRENT_THROTTLE}"
            echo "  [${ELAPSED}s/${STRESS_DURATION}s] temp=${CURRENT_TEMP}C"
        fi

        # Temperature limit
        if [ "$CURRENT_TEMP" -ge "$MAX_TEMP" ]; then
            log "FAIL: Temperature ${CURRENT_TEMP}C exceeded limit ${MAX_TEMP}C"
            echo "  FAIL: Temperature ${CURRENT_TEMP}C > ${MAX_TEMP}C limit"
            kill "$STRESS_PID" 2>/dev/null || true
            wait "$STRESS_PID" 2>/dev/null || true
            STRESS_FAILED=true
            break
        fi

        # Throttling
        if is_throttled_now "$CURRENT_THROTTLE"; then
            log "FAIL: Throttling detected (${CURRENT_THROTTLE}) at ${FREQ_MHZ} MHz"
            echo "  FAIL: CPU throttling at ${FREQ_MHZ} MHz"
            kill "$STRESS_PID" 2>/dev/null || true
            wait "$STRESS_PID" 2>/dev/null || true
            STRESS_FAILED=true
            break
        fi
    done

    # Wait for stress-ng to finish if still running
    if kill -0 "$STRESS_PID" 2>/dev/null; then
        wait "$STRESS_PID" 2>/dev/null
        STRESS_EXIT=$?
    else
        wait "$STRESS_PID" 2>/dev/null
        STRESS_EXIT=$?
    fi

    if [ "$STRESS_EXIT" -ne 0 ] && [ "$STRESS_FAILED" = false ]; then
        log "FAIL: stress-ng exited with code ${STRESS_EXIT} at ${FREQ_MHZ} MHz"
        echo "  FAIL: stress-ng error (exit code ${STRESS_EXIT})"
        STRESS_FAILED=true
    fi

    # Post-stress checks
    POST_THROTTLE=$(get_throttle_status)
    POST_TEMP=$(get_cpu_temp)
    log "Post-stress: temp=${POST_TEMP}C, throttle=${POST_THROTTLE}"

    # Check historical throttle bits
    if [ "$STRESS_FAILED" = false ] && has_throttle_history "$POST_THROTTLE"; then
        log "FAIL: Historical throttling detected (${POST_THROTTLE}) at ${FREQ_MHZ} MHz"
        echo "  FAIL: Throttling occurred during test"
        STRESS_FAILED=true
    fi

    if [ "$STRESS_FAILED" = true ]; then
        log "RESULT: ${FREQ_MHZ} MHz is NOT stable"
        break
    fi

    # This frequency is stable
    LAST_STABLE_FREQ=$CURRENT_FREQ
    log "RESULT: ${FREQ_MHZ} MHz is STABLE"
    echo "  OK: ${FREQ_MHZ} MHz stable (temp: ${POST_TEMP}C)"
done

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
OC_DETECT_FINE_STEP=$FINE_STEP_SIZE
OC_DETECT_FINE_FROM=$FINE_STEP_FROM
OC_DETECT_STRESS_DURATION=$STRESS_DURATION
OC_DETECT_MAX_TEMP=$MAX_TEMP
OC_DETECT_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
OC_DETECT_HW_MAX=$HW_MAX
EOF

echo ""
echo "============================================================"
echo "  Maximum stable frequency: ${RESULT_MHZ} MHz"
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
fi

# EXIT trap will call restore_safe_freq
exit 0
