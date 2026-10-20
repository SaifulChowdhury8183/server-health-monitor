# Server Health Monitor

## Purpose
A beginner Linux and DevOps project that checks server health and records
warnings in a timestamped log.

## Checks
- CPU load and uptime
- Memory usage
- Disk usage on mounted filesystems
- Top five memory-consuming processes
- SSH, Nginx, and cron service status

## Files
- `scripts/health_check.sh`: monitoring script
- `health.conf`: warning and critical thresholds
- `TESTING.md`: test plan and results

## Run manually
```bash
sudo ./scripts/health_check.sh
```

## Configuration and logs
- Thresholds are stored in `health.conf`.
- Reports are written to `/var/log/health/health.log`.

## Scheduling with cron
Cron runs the script every five minutes from root's crontab:
```
*/5 * * * * /home/ubuntu/server-health-monitor/scripts/health_check.sh >/dev/null 2>&1
```

## Log rotation
Logrotate rotates the log daily, keeps seven old logs, and compresses them.
The rule is stored in `/etc/logrotate.d/server-health`.

## Exit codes
- 0: OK
- 1: WARNING
- 2: CRITICAL

## Testing
Test cases and observed results are recorded in `TESTING.md`.
