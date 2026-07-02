#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/tmp/w3p-build-$$.log"

# Kolory
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

run_build() {
    echo -e "${BLUE}Starting build...${NC}"
    echo -e "Log file: $LOG_FILE\n"
    cd "$PROJECT_ROOT"
    # Output widoczny w konsoli + zapisywany do pliku
    ./compile.sh w3p 2>&1 | tee "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

analyze_log() {
    local log="$1"

    # Krytyczne błędy (przerywają build)
    echo -e "\n${RED}=== CRITICAL ERRORS ===${NC}"
    grep -E '(💥|fatal error:|make: \*\*\*|dpkg: error processing|E: Unable to|E: Package|Segmentation fault|killed|SIGKILL)' "$log" \
        | head -30 || echo "None found"

    # Błędy systemctl (często benigne - unit nie istnieje)
    echo -e "\n${YELLOW}=== SYSTEMD WARNINGS (often benign) ===${NC}"
    grep -E 'Failed to (disable|enable|start|stop) unit' "$log" \
        | grep -v 'does not exist' \
        | head -20 || echo "None found"

    # Ostrzeżenia Armbian (emoji 🚸)
    echo -e "\n${YELLOW}=== BUILD WARNINGS ===${NC}"
    grep -E '\[.*\|🚸\]' "$log" \
        | head -20 || echo "None found"

    # Inne potencjalne problemy
    echo -e "\n${YELLOW}=== OTHER ISSUES ===${NC}"
    grep -iE '(Permission denied|Connection refused|timeout|Could not resolve|Hash Sum mismatch|apt-get.*failed)' "$log" \
        | head -20 || echo "None found"
}

print_summary() {
    local log="$1"
    local critical=$(grep -cE '(💥|fatal error:|make: \*\*\*|dpkg: error processing|E: Unable to)' "$log" 2>/dev/null || echo 0)
    local warnings=$(grep -cE '\[.*\|🚸\]' "$log" 2>/dev/null || echo 0)
    local systemd_fails=$(grep -cE 'Failed to (disable|enable) unit' "$log" 2>/dev/null || echo 0)

    echo -e "\n${BLUE}=== SUMMARY ===${NC}"
    echo -e "Critical errors: ${RED}${critical}${NC}"
    echo -e "Build warnings:  ${YELLOW}${warnings}${NC}"
    echo -e "Systemd notices: ${systemd_fails} (usually benign)"
    echo -e "Full log: $log"
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --analyze-only    Analyze the most recent build log without running a new build"
    echo "  -h, --help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run build and analyze output"
    echo "  $0 --analyze-only     # Analyze last build log only"
}

main() {
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        --analyze-only)
            local latest_log
            latest_log=$(ls -t "$PROJECT_ROOT"/output/logs/log-build-*.log 2>/dev/null | head -1) || true
            if [[ -n "$latest_log" ]]; then
                echo -e "${BLUE}Analyzing: $latest_log${NC}"
                analyze_log "$latest_log"
                print_summary "$latest_log"
            else
                echo -e "${RED}No build logs found in $PROJECT_ROOT/output/logs/${NC}"
                exit 1
            fi
            ;;
        "")
            local exit_code=0
            if run_build; then
                echo -e "\n${GREEN}Build completed successfully${NC}"
            else
                exit_code=$?
                echo -e "\n${RED}Build failed with exit code: $exit_code${NC}"
            fi
            analyze_log "$LOG_FILE"
            print_summary "$LOG_FILE"
            exit $exit_code
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
