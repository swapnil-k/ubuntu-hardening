#!/usr/bin/env bash
set -euo pipefail

# Clean non-existent log file entries from logrotate status file
cd /var/lib/logrotate
test -e status || touch status
head -1 status > status.clean
sed 's/"//g' status | while read logfile date; do
    [ -e "$logfile" ] && echo "\"$logfile\" $date"
done >> status.clean
mv status.clean status

HOSTNAME=$(hostname -f)
HOSTIP=$(hostname -I | awk '{print $1}')
LOGROTATE=$(which logrotate)
LOGROTATEFILE="/etc/logrotate.conf"

test -x "$LOGROTATE" || exit 0

if ! "$LOGROTATE" "$LOGROTATEFILE"; then
    logger -t logrotate "Logrotation FAILED on $HOSTNAME ($HOSTIP)"
    exit 1
fi

logger -t logrotate "Logrotation completed successfully on $HOSTNAME ($HOSTIP)"
