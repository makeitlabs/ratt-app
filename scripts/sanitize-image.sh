#!/usr/bin/env bash
#
# RATT golden-image sanitization + capture
#
# Runs on a Linux HOST against the UNMOUNTED card/image of a fully set-up RATT
# node (platform-setup.sh + setup.sh done, Pi shut down cleanly), right before
# it is captured as a reusable template. NEVER run this against a live system.
#
#   sudo scripts/sanitize-image.sh /dev/sdX [--reset-cloud-init]
#   sudo scripts/sanitize-image.sh golden.img [--reset-cloud-init]
#
# What it does:
#   - Wipes SSH host keys, and installs a oneshot unit that regenerates them on
#     first boot (so clones never come up without sshd).
#   - Empties /etc/machine-id (systemd regenerates it on boot).
#   - Clears DHCP/NM leases, apt .deb cache, /tmp, /var/tmp, journal, shell history.
#   - /data: KEEPS ratt.ini, CLEARS the downloaded ACL + remote-config caches.
#   - --reset-cloud-init: wipes /var/lib/cloud so cloud-init re-runs on every clone
#     (re-applies Imager user-data: user, Wi-Fi, hostname). Off by default.
#   - Image file: truncates it to the end of the last partition.
#     Block device: prints the dd command to capture just the used part.

set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

TARGET=""
RESET_CLOUD_INIT=0
for a in "$@"; do
    case "$a" in
        --reset-cloud-init) RESET_CLOUD_INIT=1 ;;
        -*) die "unknown option $a" ;;
        *)  TARGET="$a" ;;
    esac
done
[ -n "$TARGET" ] || die "usage: sudo $0 <block-device | image-file> [--reset-cloud-init]"
[ "$EUID" -eq 0 ] || die "must run as root"

DEV=""; LOOP=""; MNT=""
cleanup() {
    set +e
    if [ -n "$MNT" ]; then
        umount "$MNT/data" 2>/dev/null
        umount "$MNT/root" 2>/dev/null
        rmdir "$MNT/data" "$MNT/root" "$MNT" 2>/dev/null
    fi
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

if [ -f "$TARGET" ]; then
    LOOP=$(losetup -P --find --show "$TARGET")
    DEV="$LOOP"
elif [ -b "$TARGET" ]; then
    DEV="$TARGET"
    if lsblk -nro MOUNTPOINT "$DEV" | grep -q .; then
        die "$DEV has mounted partitions; unmount them first"
    fi
else
    die "$TARGET is neither a block device nor a file"
fi

part() { if [[ "$DEV" =~ [0-9]$ ]]; then echo "${DEV}p$1"; else echo "${DEV}$1"; fi; }
P2=$(part 2); P3=$(part 3)

MNT=$(mktemp -d /tmp/ratt-sanitize.XXXXXX)
mkdir -p "$MNT/root" "$MNT/data"
mount "$P2" "$MNT/root"
R="$MNT/root"
[ -f "$R/etc/os-release" ] || die "$P2 doesn't look like a root filesystem"

# ---------------------------------------------------------------- SSH host keys
info "SSH host keys"
rm -f "$R"/etc/ssh/ssh_host_*key*
# Always install our own regenerator; it's a no-op if keys already exist,
# so it's harmless alongside raspberrypi-sys-mods' regenerate_ssh_host_keys.
cat > "$R/etc/systemd/system/ratt-ssh-hostkeys.service" <<'EOF'
[Unit]
Description=Generate missing SSH host keys (RATT clone first boot)
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service sshd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf ../ratt-ssh-hostkeys.service "$R/etc/systemd/system/multi-user.target.wants/ratt-ssh-hostkeys.service"

# ---------------------------------------------------------------- identity
info "machine-id"
truncate -s 0 "$R/etc/machine-id"
# On Debian this is normally a symlink to /etc/machine-id; only remove a real copy
[ -f "$R/var/lib/dbus/machine-id" ] && [ ! -L "$R/var/lib/dbus/machine-id" ] && rm -f "$R/var/lib/dbus/machine-id"

# ---------------------------------------------------------------- caches / logs
info "Leases, apt cache, tmp, journal, history"
rm -rf "$R"/var/lib/dhcp/* "$R"/var/lib/NetworkManager/*.lease
rm -f  "$R"/var/cache/apt/archives/*.deb
rm -rf "$R"/tmp/* "$R"/var/tmp/*
rm -rf "$R"/var/log/journal/*
rm -f  "$R"/root/.bash_history "$R"/home/*/.bash_history

if [ "$RESET_CLOUD_INIT" -eq 1 ]; then
    info "Resetting cloud-init state (will re-run on each clone)"
    rm -rf "$R"/var/lib/cloud/*
    rm -f  "$R"/var/log/cloud-init*.log
fi

# ---------------------------------------------------------------- /data
if [ -b "$P3" ] && [ "$(blkid -s LABEL -o value "$P3" 2>/dev/null)" = "data" ]; then
    mount "$P3" "$MNT/data"
    D="$MNT/data"
    info "/data: keeping ratt.ini, clearing downloaded caches"
    [ -f "$D/ratt/ratt.ini" ] || warn "/data/ratt/ratt.ini missing; ratt.service won't start on clones"
    rm -f "$D/ratt/ratt.acl" "$D/ratt/ratt-remote.conf"
    if [ -d "$D/certs" ] && [ -n "$(ls -A "$D/certs" 2>/dev/null)" ]; then
        warn "/data/certs is not empty. Client certs/keys are usually per-node; every clone will share them:"
        ls -l "$D/certs" | sed 's/^/    /'
    fi
    umount "$MNT/data"
else
    warn "no LABEL=data partition (p3); was platform-setup.sh run?"
fi

# ---------------------------------------------------------------- reminders
HOST=$(cat "$R/etc/hostname" 2>/dev/null || echo '?')
warn "every clone will boot with hostname '$HOST' unless something renames it"

umount "$MNT/root"
sync

# ---------------------------------------------------------------- capture
LAST_END=$(parted -sm "$DEV" unit s print | awk -F: '$1 ~ /^[0-9]+$/ {sub("s","",$3); e=$3} END {print e}')
BYTES=$(( (LAST_END + 1) * 512 ))
if [ -n "$LOOP" ]; then
    losetup -d "$LOOP"; LOOP=""
    truncate -s "$BYTES" "$TARGET"
    info "Truncated $TARGET to $(numfmt --to=iec "$BYTES") (end of last partition)"
    echo "    Compress it with e.g.:  xz -T0 -v \"$TARGET\""
else
    info "Capture only the used part of the card ($(numfmt --to=iec "$BYTES")):"
    echo "    sudo dd if=$DEV of=ratt-golden.img bs=4M count=$BYTES iflag=count_bytes status=progress"
fi
