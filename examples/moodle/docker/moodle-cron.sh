#!/bin/sh
# =============================================================================
# moodle-cron.sh — fixed-interval Moodle cron runner
# =============================================================================
# Two things the previous `while true; do php cron.php >/dev/null 2>&1; sleep 60; done`
# got wrong:
#
#   * output was discarded, so a failing cron was undiagnosable
#   * `sleep 60` AFTER the run means the interval is 60s + runtime, so a cron
#     taking five minutes fires every six — and drifts further every cycle
#
# This computes the remaining time in the minute so the period stays 60s.
# =============================================================================
set -u

CLI_DIR="${MOODLE_CLI_DIR:-/var/www/html/public/admin/cli}"
INTERVAL="${MOODLE_CRON_INTERVAL:-60}"

# Let the web container finish generating config.php and running any upgrade.
sleep "${MOODLE_CRON_STARTUP_DELAY:-30}"

echo "[moodle-cron] running ${CLI_DIR}/cron.php every ${INTERVAL}s"

while true; do
    start="$(date +%s)"

    # Output goes to the container log on purpose. Failures are visible, and a
    # non-zero exit does not kill the loop.
    php "${CLI_DIR}/cron.php" 2>&1 || echo "[moodle-cron] cron.php exited non-zero"

    elapsed="$(( $(date +%s) - start ))"
    remaining="$(( INTERVAL - elapsed ))"
    [ "$remaining" -gt 0 ] || remaining=1
    sleep "$remaining"
done
