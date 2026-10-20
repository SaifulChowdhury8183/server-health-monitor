# Server Health Monitor Test Plan

Record the actual outcome of every test after running it.

| Test | Steps | Expected result | Actual result |
|---|---|---|---|
| Help | Run `./scripts/health_check.sh --help` | Usage information appears | Pending |
| Syntax | Run `bash -n scripts/health_check.sh` | No syntax errors | Pending |
| Manual run | Run `sudo ./scripts/health_check.sh` | Report is written | Pending |
| Log file | Inspect `/var/log/health/health.log` | Timestamp and final result appear | Pending |
| Service check | Check when Nginx is active | Nginx is reported active | Pending |
| Cron | Inspect cron logs after the next interval | A new report is written | Pending |
| Logrotate | Test using a separate temporary log | Rotation and compression are demonstrated | Pending |
| Thresholds | Test a safe copy with adjusted thresholds | Appropriate warning is triggered | Pending |

## Notes
Do not mark a test as passed until you have run it and confirmed the result.
Do not fill the real server disk or stop critical production services for testing.
