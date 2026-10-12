#!/bin/bash
DATA_DEV="$(readlink -f /dev/disk/by-label/data 2>/dev/null || true)"
if [ -z "$DATA_DEV" ] || [ ! -b "$DATA_DEV" ]; then
    exit 0
fi

# If already mounted, nothing to do
if grep -qs "$DATA_DEV" /proc/mounts || mountpoint -q /data 2>/dev/null; then
    exit 0
fi

set +e
e2fsck -p "$DATA_DEV"
rc=$?
set -e

# rc=4: File system errors left uncorrected
if [ "$rc" -ge 4 ] && [ "$rc" -ne 8 ]; then
    echo "WARNING: /data partition ($DATA_DEV) corrupted (e2fsck code $rc); auto-reformatting..."
    mkfs.ext4 -F -q -L data "$DATA_DEV"
    TMPMNT=$(mktemp -d)
    mount "$DATA_DEV" "$TMPMNT"
    mkdir -p "$TMPMNT/ratt" "$TMPMNT/certs" "$TMPMNT/log" "$TMPMNT/timesync"
    chown -R 1000:1000 "$TMPMNT/ratt" "$TMPMNT/certs" 2>/dev/null || true
    for ini in /home/*/ratt-app/conf/ratt.ini-example; do
        if [ -f "$ini" ]; then
            cp "$ini" "$TMPMNT/ratt/ratt.ini"
            chown 1000:1000 "$TMPMNT/ratt/ratt.ini" 2>/dev/null || true
            break
        fi
    done
    umount "$TMPMNT"
    rmdir "$TMPMNT"
fi
exit 0
