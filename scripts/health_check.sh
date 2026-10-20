#!/bin/bash

# Stop on unhandled errors, undefined variables, and failed command pipelines.
set -euo pipefail

# Find the project directory based on this script's location.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Load configurable warning and critical thresholds.
CONFIG_FILE="${PROJECT_DIR}/health.conf"

# Store monitoring reports in a system log directory.
LOG_DIR="/var/log/health"
LOG_FILE="${LOG_DIR}/health.log"

# Display instructions when the user requests help.
show_help() {
    cat <<'HELP'
Server Health Monitor

Usage:
  sudo ./scripts/health_check.sh
  ./scripts/health_check.sh --help

Checks:
  - CPU load and uptime
  - Memory usage
  - Disk usage for mounted filesystems
  - Top five memory-consuming processes
  - SSH, Nginx, and cron service status

Exit codes:
  0 = OK
  1 = WARNING
  2 = CRITICAL
HELP
}

# Handle the help option before performing any checks.
if [[ "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

# Reject unsupported command-line options.
if [[ "$#" -gt 0 ]]; then
    echo "ERROR: Unknown option: $1" >&2
    show_help >&2
    exit 2
fi

# Require the configuration file to exist.
if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: Cannot read configuration: $CONFIG_FILE" >&2
    exit 2
fi

# Load the threshold variables from the project configuration.
# Only use a trusted configuration file that you control.
# shellcheck source=../health.conf
source "$CONFIG_FILE"

# Verify that every required threshold is defined.
: "${DISK_WARNING:?Missing DISK_WARNING in health.conf}"
: "${DISK_CRITICAL:?Missing DISK_CRITICAL in health.conf}"
: "${MEMORY_WARNING:?Missing MEMORY_WARNING in health.conf}"
: "${MEMORY_CRITICAL:?Missing MEMORY_CRITICAL in health.conf}"
: "${CPU_WARNING:?Missing CPU_WARNING in health.conf}"
: "${CPU_CRITICAL:?Missing CPU_CRITICAL in health.conf}"

# Validate percentage thresholds as whole numbers from 1 to 100.
for threshold_name in DISK_WARNING DISK_CRITICAL MEMORY_WARNING MEMORY_CRITICAL; do
    threshold_value="${!threshold_name}"

    if [[ ! "$threshold_value" =~ ^[0-9]+$ ]] ||
       (( threshold_value < 1 || threshold_value > 100 )); then
        echo "ERROR: $threshold_name must be a whole number from 1 to 100." >&2
        exit 2
    fi
done

# Ensure warning thresholds are lower than critical thresholds.
if (( DISK_WARNING >= DISK_CRITICAL )); then
    echo "ERROR: DISK_WARNING must be less than DISK_CRITICAL." >&2
    exit 2
fi

if (( MEMORY_WARNING >= MEMORY_CRITICAL )); then
    echo "ERROR: MEMORY_WARNING must be less than MEMORY_CRITICAL." >&2
    exit 2
fi

# Validate CPU load thresholds as positive decimal numbers.
for threshold_name in CPU_WARNING CPU_CRITICAL; do
    threshold_value="${!threshold_name}"

    if [[ ! "$threshold_value" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v value="$threshold_value" 'BEGIN { exit !(value > 0) }'; then
        echo "ERROR: $threshold_name must be a positive number." >&2
        exit 2
    fi
done

# Ensure the CPU critical threshold exceeds the warning threshold.
if ! awk -v warning="$CPU_WARNING" -v critical="$CPU_CRITICAL" \
    'BEGIN { exit !(warning < critical) }'; then
    echo "ERROR: CPU_WARNING must be less than CPU_CRITICAL." >&2
    exit 2
fi

# Create the system log directory if it does not exist.
if ! mkdir -p "$LOG_DIR"; then
    echo "ERROR: Cannot create $LOG_DIR. Try running with sudo." >&2
    exit 2
fi

# Create the log file if necessary.
if ! touch "$LOG_FILE"; then
    echo "ERROR: Cannot write to $LOG_FILE. Try running with sudo." >&2
    exit 2
fi

# Start with an OK result. Warnings and critical issues raise the severity.
STATUS=0

# Print each report line to the terminal and append it to the log.
log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

# Record a warning unless a critical result has already occurred.
warn() {
    if (( STATUS < 1 )); then
        STATUS=1
    fi
    log "WARNING: $*"
}

# Record a critical issue and give it the highest severity.
critical() {
    STATUS=2
    log "CRITICAL: $*"
}

# Start a timestamped report.
log ""
log "============================================================"
log "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log "Hostname: $(hostname)"
log "============================================================"

# Report uptime and load averages.
log ""
log "----- UPTIME AND CPU LOAD -----"

uptime_output="$(uptime 2>&1)" || {
    critical "Unable to read uptime information."
    uptime_output="uptime command failed: ${uptime_output}"
}
log "$uptime_output"

# Read the one-minute load average from /proc/loadavg.
if [[ -r /proc/loadavg ]]; then
    read -r LOAD_1 LOAD_5 LOAD_15 _ < /proc/loadavg
    CPU_COUNT="$(nproc)"

    log "CPU cores: $CPU_COUNT"
    log "Load averages (1, 5, 15 minutes): $LOAD_1, $LOAD_5, $LOAD_15"

    # Compare one-minute load with thresholds scaled to CPU count.
    if awk -v load="$LOAD_1" -v cores="$CPU_COUNT" \
        -v threshold="$CPU_CRITICAL" \
        'BEGIN { exit !(load >= threshold * cores) }'; then
        critical "One-minute CPU load is critically high."
    elif awk -v load="$LOAD_1" -v cores="$CPU_COUNT" \
        -v threshold="$CPU_WARNING" \
        'BEGIN { exit !(load >= threshold * cores) }'; then
        warn "One-minute CPU load is high."
    else
        log "CPU load: OK"
    fi
else
    critical "Cannot read /proc/loadavg."
fi

# Display a snapshot of CPU and process activity.
log ""
log "----- TOP SNAPSHOT -----"
if top -bn1 | head -n 15 >> "$LOG_FILE"; then
    :
else
    warn "Could not collect the top snapshot."
fi

# Calculate memory usage using available memory, in bytes.
log ""
log "----- MEMORY -----"

if command -v free >/dev/null 2>&1; then
    free -m | tee -a "$LOG_FILE"

    read -r TOTAL_MEMORY AVAILABLE_MEMORY < <(
        awk '/^Mem:/ { print $2, $7 }' < <(free -m)
    )

    if [[ "${TOTAL_MEMORY:-0}" =~ ^[0-9]+$ ]] &&
       [[ "${AVAILABLE_MEMORY:-}" =~ ^[0-9]+$ ]] &&
       (( TOTAL_MEMORY > 0 )); then
        USED_MEMORY=$(( TOTAL_MEMORY - AVAILABLE_MEMORY ))
        MEMORY_PERCENT=$(( USED_MEMORY * 100 / TOTAL_MEMORY ))

        log "Memory usage: ${MEMORY_PERCENT}%"

        if (( MEMORY_PERCENT >= MEMORY_CRITICAL )); then
            critical "Memory usage is critically high."
        elif (( MEMORY_PERCENT >= MEMORY_WARNING )); then
            warn "Memory usage is high."
        else
            log "Memory usage: OK"
        fi
    else
        critical "Unable to calculate memory usage."
    fi
else
    critical "The free command is not installed."
fi

# Check disk usage for mounted filesystems.
log ""
log "----- DISK USAGE -----"

if df -P -h >> "$LOG_FILE"; then
    :
else
    warn "Could not collect disk usage."
fi

# Read filesystem usage as percentages, excluding header rows.
while read -r filesystem size used available percent mountpoint; do
    [[ "${percent:-}" =~ ^[0-9]+%$ ]] || continue

    disk_percent="${percent%\%}"

    # Ignore filesystems that cannot reasonably be treated as local disk capacity.
    case "$filesystem" in
        tmpfs|devtmpfs|overlay|squashfs|udev|shm|/dev/loop*)
            continue
            ;;
    esac

    log "Disk mount $mountpoint: ${disk_percent}% used"

    if (( disk_percent >= DISK_CRITICAL )); then
        critical "Disk usage on $mountpoint is critically high."
    elif (( disk_percent >= DISK_WARNING )); then
        warn "Disk usage on $mountpoint is high."
    fi
done < <(df -P | awk 'NR > 1 { print $1, $2, $3, $4, $5, $6 }')

# List the five processes using the most memory.
log ""
log "----- TOP 5 MEMORY-CONSUMING PROCESSES -----"

if ps aux --sort=-%mem | head -n 6 >> "$LOG_FILE"; then
    :
else
    warn "Could not collect the process list."
fi

# Check whether a systemd service is active.
check_service() {
    local service_name="$1"
    local display_name="$2"

    if systemctl is-active --quiet "$service_name"; then
        log "Service $display_name: ACTIVE"
    else
        warn "Service $display_name is not active."
    fi
}

# Check SSH using the common Ubuntu service name.
log ""
log "----- SERVICE STATUS -----"

if systemctl list-unit-files ssh.service --no-legend 2>/dev/null |
    grep -q '^ssh\.service'; then
    check_service ssh.service ssh
elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null |
    grep -q '^sshd\.service'; then
    check_service sshd.service sshd
else
    warn "Neither ssh.service nor sshd.service was found."
fi

# Check Nginx. It may be absent on a fresh server.
if systemctl list-unit-files nginx.service --no-legend 2>/dev/null |
    grep -q '^nginx\.service'; then
    check_service nginx.service nginx
else
    warn "nginx.service is not installed or was not found."
fi

# Check cron, which is responsible for scheduling recurring health checks.
if systemctl list-unit-files cron.service --no-legend 2>/dev/null |
    grep -q '^cron\.service'; then
    check_service cron.service cron
else
    warn "cron.service was not found."
fi

# Report the final severity and return the matching exit code.
log ""
case "$STATUS" in
    0)
        log "FINAL RESULT: OK"
        ;;
    1)
        log "FINAL RESULT: WARNING"
        ;;
    2)
        log "FINAL RESULT: CRITICAL"
        ;;
esac

log "Exit code: $STATUS"
exit "$STATUS"
