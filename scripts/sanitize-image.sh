#!/usr/bin/env bash
#
# RATT golden-image sanitization + capture
#
# Runs on a Linux HOST against the UNMOUNTED card/image of a fully set-up RATT
# node (Raspberry Pi or Orange Pi), right before it is captured as a reusable template.
# NEVER run this against a live system.
#
#   sudo scripts/sanitize-image.sh /dev/sdX [--reset-cloud-init]
#   sudo scripts/sanitize-image.sh golden.img [--reset-cloud-init]
#
# Partition layouts automatically detected:
#   - Raspberry Pi (3 partitions):
#       p1: FAT32 (/boot/firmware)
#       p2: ext4 (/)
#       p3: ext4 (/data, logs/caches)
#   - Orange Pi (2 partitions):
#       p1: ext4 (rootfs, includes /boot)
#       p2: ext4 (/data, logs/caches)
#       (No separate FAT boot partition)
#
# What it does:
#   - Wipes SSH host keys, and installs a oneshot unit that regenerates them on
#     first boot (so clones never come up without sshd).
#   - Empties /etc/machine-id (systemd regenerates it on boot).
#   - Clears DHCP/NM leases, apt .deb cache, /tmp, /var/tmp, journals, shell history.
#   - Boot static config (p1 FAT on RPi, or /boot on Orange Pi):
#     KEEPS ratt.ini, WARNS if certs/ is non-empty (per-node), clears template hostname.
#   - /data (p3 on RPi, p2 on Orange Pi):
#     CLEARS downloaded ACL + remote-config caches, persistent journals, and logs.
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
        umount "$MNT/boot" 2>/dev/null
        umount "$MNT/root" 2>/dev/null
        rmdir "$MNT/data" "$MNT/boot" "$MNT/root" "$MNT" 2>/dev/null
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
P1=$(part 1); P2=$(part 2); P3=$(part 3)

[ -b "$P1" ] || die "$DEV has no partition 1"

P1_TYPE="$(blkid -s TYPE -o value "$P1" 2>/dev/null || true)"

if [[ "$P1_TYPE" =~ fat|msdos|FAT ]]; then
    # Raspberry Pi layout:
    #   p1: FAT boot (/boot/firmware)
    #   p2: ext4 root (/)
    #   p3: ext4 data (/data)
    info "Detected Raspberry Pi layout (p1: ${P1_TYPE} boot, p2: root, p3: data)"
    ROOT_PART="$P2"
    BOOT_PART="$P1"
    DATA_PART="$P3"
    HAS_SEPARATE_BOOT=1
else
    # Orange Pi (and single-root distributions) layout:
    #   p1: ext4 root (/), includes /boot
    #   p2: ext4 data/log (/data)
    #   no separate FAT boot partition
    info "Detected Orange Pi layout (p1: ${P1_TYPE:-ext4} root, p2: data/log - no separate FAT boot)"
    ROOT_PART="$P1"
    BOOT_PART=""
    DATA_PART="$P2"
    HAS_SEPARATE_BOOT=0
fi

MNT=$(mktemp -d /tmp/ratt-sanitize.XXXXXX)
mkdir -p "$MNT/root" "$MNT/data" "$MNT/boot"

mount "$ROOT_PART" "$MNT/root"
R="$MNT/root"

# Verify rootfs
if [ ! -f "$R/etc/os-release" ]; then
    # Fallback sanity check in case P1/P2 were inverted
    umount "$MNT/root" 2>/dev/null || true
    ALT_PART="$P2"
    [ "$ROOT_PART" = "$P2" ] && ALT_PART="$P1"
    if [ -b "$ALT_PART" ]; then
        info "Retrying rootfs detection on $ALT_PART..."
        if mount "$ALT_PART" "$MNT/root" 2>/dev/null; then
            if [ -f "$R/etc/os-release" ]; then
                ROOT_PART="$ALT_PART"
                if [ "$ROOT_PART" = "$P2" ]; then
                    BOOT_PART="$P1"
                    DATA_PART="$P3"
                    HAS_SEPARATE_BOOT=1
                else
                    BOOT_PART=""
                    DATA_PART="$P2"
                    HAS_SEPARATE_BOOT=0
                fi
            fi
        fi
    fi
fi
[ -f "$R/etc/os-release" ] || die "$ROOT_PART doesn't look like a root filesystem (no /etc/os-release)"

# ---------------------------------------------------------------- SSH host keys
info "SSH host keys"
rm -f "$R"/etc/ssh/ssh_host_*key*
# Install our own first-boot hostkey generator script that handles read-only root
cat > "$R/usr/local/sbin/ratt-ssh-hostkeys.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

MISSING=0
for t in rsa ecdsa ed25519; do
    if [ ! -f "/etc/ssh/ssh_host_${t}_key" ]; then
        MISSING=1
        break
    fi
done

[ "$MISSING" -eq 1 ] || exit 0

echo "ratt-ssh-hostkeys: generating missing SSH host keys..."
IS_RO=0
if ! [ -w / ]; then
    mount -o remount,rw /
    IS_RO=1
fi

/usr/bin/ssh-keygen -A

if [ "$IS_RO" -eq 1 ]; then
    sync
    mount -o remount,ro /
fi
echo "ratt-ssh-hostkeys: host keys generated successfully."
exit 0
EOF
chmod 0755 "$R/usr/local/sbin/ratt-ssh-hostkeys.sh"
chown root:root "$R/usr/local/sbin/ratt-ssh-hostkeys.sh"

cat > "$R/etc/systemd/system/ratt-ssh-hostkeys.service" <<'EOF'
[Unit]
Description=Generate missing SSH host keys (RATT clone first boot)
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
DefaultDependencies=no
Conflicts=shutdown.target
After=local-fs.target
Before=ssh.service sshd.service ssh.socket sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ratt-ssh-hostkeys.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
mkdir -p "$R/etc/systemd/system/sysinit.target.wants"
ln -sf ../ratt-ssh-hostkeys.service "$R/etc/systemd/system/sysinit.target.wants/ratt-ssh-hostkeys.service"
rm -f "$R/etc/systemd/system/multi-user.target.wants/ratt-ssh-hostkeys.service"

# Ensure fake-hwclock saves to /data instead of read-only root
if [ -f "$R/etc/default/fake-hwclock" ]; then
    sed -i 's|^#\?FILE=.*|FILE=/data/fake-hwclock.data|' "$R/etc/default/fake-hwclock"
elif [ -d "$R/etc/default" ]; then
    echo 'FILE=/data/fake-hwclock.data' > "$R/etc/default/fake-hwclock"
fi

# Ensure chrony driftfile points to /data if chrony is installed
if [ -f "$R/etc/chrony/chrony.conf" ]; then
    sed -i 's|^driftfile .*|driftfile /data/timesync/chrony.drift|' "$R/etc/chrony/chrony.conf"
fi

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
find "$R/var/log" -maxdepth 2 -type f ! -name "README*" -delete 2>/dev/null || true
rm -f  "$R"/root/.bash_history "$R"/home/*/.bash_history

if [ "$RESET_CLOUD_INIT" -eq 1 ]; then
    info "Resetting cloud-init state (will re-run on each clone)"
    rm -rf "$R"/var/lib/cloud/*
    rm -f  "$R"/var/log/cloud-init*.log
fi

# ---------------------------------------------------------------- static config (boot)
BOOT_DIR=""
MOUNTED_BOOT=0
if [ "$HAS_SEPARATE_BOOT" -eq 1 ]; then
    if [ -b "$BOOT_PART" ] && mount "$BOOT_PART" "$MNT/boot"; then
        BOOT_DIR="$MNT/boot"
        MOUNTED_BOOT=1
    else
        warn "could not mount boot partition ($BOOT_PART) to check RATT config"
    fi
else
    # On Orange Pi, /boot is part of the root filesystem
    BOOT_DIR="$R/boot"
fi

if [ -n "$BOOT_DIR" ] && [ -d "$BOOT_DIR" ]; then
    B="$BOOT_DIR/ratt"
    [ -d "$B" ] || [ ! -d "$BOOT_DIR/firmware/ratt" ] || B="$BOOT_DIR/firmware/ratt"

    info "Boot config directory: $BOOT_DIR (RATT config in $B)"
    if [ -f "$B/ratt.ini" ]; then
        info "$B/ratt.ini: keeping static configuration"
    else
        warn "$B/ratt.ini missing; ratt.service won't start on clones until configured"
    fi

    if [ -d "$B/certs" ] && [ -n "$(ls -A "$B/certs" 2>/dev/null)" ]; then
        warn "$B/certs is not empty. Client certs/keys are usually per-node; every clone will share them:"
        ls -l "$B/certs" | sed 's/^/    /'
    fi

    # Remove node-specific hostname file from template image if present
    rm -f "$BOOT_DIR/hostname.txt" "$BOOT_DIR/hostname" "$B/hostname.txt" "$B/hostname"

    if [ "$MOUNTED_BOOT" -eq 1 ]; then
        umount "$MNT/boot"
    fi
fi

# ---------------------------------------------------------------- /data (disposable)
if [ -n "$DATA_PART" ] && [ -b "$DATA_PART" ]; then
    if mount "$DATA_PART" "$MNT/data" 2>/dev/null; then
        D="$MNT/data"
        info "Data partition ($DATA_PART mounted at /data): clearing disposable caches and logs"
        rm -f "$D/ratt/ratt.acl" "$D/ratt/ratt-remote.conf"
        if [ -f "$D/ratt/ratt.ini" ] || [ -n "$(ls -A "$D/certs" 2>/dev/null)" ]; then
            warn "$DATA_PART still has a legacy ratt.ini and/or certs/."
            warn "Config lives in boot/ratt; run setup.sh to migrate, then remove $D/ratt/ratt.ini and $D/certs."
        fi
        if [ -d "$D/log" ]; then
            info "Clearing persistent logs and journal in $DATA_PART (/data/log)"
            rm -rf "$D"/log/journal/*
            rm -rf "$D"/log/apt/*
            find "$D/log" -maxdepth 2 -type f ! -name "README*" -delete 2>/dev/null || true
        fi
        rm -f "$D/fake-hwclock.data"
        umount "$MNT/data"
    else
        warn "could not mount data partition ($DATA_PART)"
    fi
else
    warn "no data partition ($DATA_PART) found; was platform setup run?"
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
