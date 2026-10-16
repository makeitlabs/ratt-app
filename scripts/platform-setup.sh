#!/usr/bin/env bash
#
# RATT platform/OS prep for a Raspberry Pi OS Lite (Trixie) SD card or .img
#
# Runs on a Linux HOST against an UNMOUNTED, NEVER-BOOTED card or image file.
# This is "stuff the OS does for RATT" (see OS_PACKAGING.md); the app itself is
# installed afterwards, on the Pi, with setup.sh.
#
#   sudo scripts/platform-setup.sh /dev/sdX [--ssh-key <pubkey-file>]
#   sudo scripts/platform-setup.sh raspios-lite.img [--ssh-key <pubkey-file>]
#   sudo scripts/platform-setup.sh /dev/sdX ~/.ssh/id_ed25519.pub
#
# What it does:
#   1. Grows root (p2) to ROOT_SIZE and creates p3 (DATA_SIZE, ext4, LABEL=data)
#      right after it. Because p3 sits directly after root, the stock first-boot
#      root expansion has no room to grow into, so it can't eat the data partition.
#   2. Configures NATIVE READ-ONLY ROOT: mounts / and /boot/firmware as 'ro' in fstab,
#      mounts /tmp and /var/tmp as tmpfs, bind-mounts /data/log over /var/log, and
#      configures systemd-journald to persist capped logs (50MB) to /data/log.
#      /boot/firmware also gets fmask=0077,dmask=0077 (root-only) because it holds
#      the static RATT config + TLS key in /boot/firmware/ratt.
#   3. Installs a self-healing health check service for /data: if the data partition
#      is corrupted, it auto-reformats on boot rather than halting. Safe because /data
#      only holds disposable state (ACL/remote-config caches, logs, clock file).
#   4. Installs ratt-rw and ratt-ro convenience utilities for zero-reboot maintenance.
#   5. Redirects fake-hwclock to /data/fake-hwclock.data so clock saves cleanly.
#   6. cmdline.txt: keeps it one line, strips legacy resize tokens, adds
#      fbcon=map:9 vt.global_cursor_default=0 consoleblank=0.
#   7. LCD boot splash: converts gui/images/ratt_bootscreen.png to raw RGB565 and
#      installs a udev rule that draws it as soon as the fbtft framebuffer appears.
#   8. Creates user 'ratt' with passwordless sudo (/etc/sudoers.d/010_ratt-nopasswd)
#      and optionally installs SSH authorized keys into ~ratt/.ssh/authorized_keys.
#   9. Masks getty@tty1 so no console login lands on the LCD.
#
# Env overrides: ROOT_SIZE (default 6G), DATA_SIZE (default 1G),
#                SSH_KEY_FILE (path to public key / authorized_keys file),
#                SPLASH_SRC (default gui/images/ratt_bootscreen.png)
#
# Safe to re-run: partitioning is skipped if p3 is already LABEL=data.

set -euo pipefail

ROOT_SIZE="${ROOT_SIZE:-6G}"
DATA_SIZE="${DATA_SIZE:-1G}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
LCD_W=320
LCD_H=240
SPLASH_BYTES=$((LCD_W * LCD_H * 2))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SPLASH_SRC="${SPLASH_SRC:-${REPO_DIR}/gui/images/ratt_bootscreen.png}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Check for explicit --local flag
for a in "$@"; do
    if [ "$a" = "--local" ]; then
        shift
        exec "${SCRIPT_DIR}/pi-platform-setup.sh" "$@"
    fi
done

TARGET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local)
            shift
            exec "${SCRIPT_DIR}/pi-platform-setup.sh" "$@"
            ;;
        --ssh-key|-k)
            [ "$#" -ge 2 ] || die "$1 requires a filename argument"
            SSH_KEY_FILE="$2"
            shift 2
            ;;
        --ssh-key=*)
            SSH_KEY_FILE="${1#*=}"
            shift
            ;;
        -*)
            die "unknown option $1"
            ;;
        *)
            if [ -z "$TARGET" ]; then
                TARGET="$1"
            elif [ -z "$SSH_KEY_FILE" ]; then
                SSH_KEY_FILE="$1"
            else
                die "unexpected extra argument: $1"
            fi
            shift
            ;;
    esac
done

# If no target specified and running on a live Raspberry Pi, delegate to pi-platform-setup.sh
if [ -z "$TARGET" ] && [ -f /proc/device-tree/model ]; then
    info "Detected local Raspberry Pi ($(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'Pi')). Running local setup..."
    exec "${SCRIPT_DIR}/pi-platform-setup.sh" ${SSH_KEY_FILE:+--ssh-key "$SSH_KEY_FILE"}
fi

[ -n "$TARGET" ] || die "usage: sudo $0 <block-device | image-file> [--ssh-key <authorized_key_file>]\n       sudo $0 --local (to run on live Pi directly)"
[ "$EUID" -eq 0 ] || die "must run as root"

for c in parted partprobe partx e2fsck resize2fs mkfs.ext4 blkid blockdev losetup numfmt udevadm; do
    command -v "$c" >/dev/null 2>&1 || die "missing host tool: $c"
done

to_sectors() { echo $(( $(numfmt --from=iec "$1") / 512 )); }
p_field()    { parted -sm "$1" unit s print | awk -F: -v n="$2" -v f="$3" '$1==n {sub("s","",$f); print $f}'; }

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

ROOT_SECT=$(to_sectors "$ROOT_SIZE")
DATA_SECT=$(to_sectors "$DATA_SIZE")

# ---------------------------------------------------------------- target setup
if [ -f "$TARGET" ]; then
    P2_START=$(p_field "$TARGET" 2 2)
    [ -n "$P2_START" ] || die "$TARGET has no partition 2 (not a Raspberry Pi OS image?)"
    # Make sure the image file is big enough for root + data (+ alignment slack)
    NEED_BYTES=$(( (P2_START + ROOT_SECT + 2048 + DATA_SECT + 2048) * 512 ))
    if [ "$(stat -c %s "$TARGET")" -lt "$NEED_BYTES" ]; then
        info "Growing image file to $(numfmt --to=iec "$NEED_BYTES")"
        truncate -s "$NEED_BYTES" "$TARGET"
    fi
    LOOP=$(losetup -P --find --show "$TARGET")
    DEV="$LOOP"
elif [ -b "$TARGET" ]; then
    DEV="$TARGET"
    if lsblk -nro MOUNTPOINT "$DEV" | grep -q .; then
        die "$DEV has mounted partitions; unmount them first (and double-check this is the SD card!)"
    fi
else
    die "$TARGET is neither a block device nor a file"
fi

part() { if [[ "$DEV" =~ [0-9]$ ]]; then echo "${DEV}p$1"; else echo "${DEV}$1"; fi; }
P1=$(part 1); P2=$(part 2); P3=$(part 3)

reread() {
    partprobe "$DEV" 2>/dev/null || true
    partx -u "$DEV" 2>/dev/null || true
    udevadm settle || true
}

# ---------------------------------------------------------------- 1. partitions
P3_LABEL=""
[ -b "$P3" ] && P3_LABEL=$(blkid -s LABEL -o value "$P3" 2>/dev/null || true)

if [ "$P3_LABEL" = "data" ]; then
    info "p3 already LABEL=data; skipping partitioning"
elif [ -b "$P3" ]; then
    die "$P3 exists but isn't LABEL=data; refusing to touch it"
else
    P2_START=$(p_field "$DEV" 2 2)
    P2_END=$(p_field "$DEV" 2 3)
    DISK_SECT=$(blockdev --getsz "$DEV")
    NEW_P2_END=$(( P2_START + ROOT_SECT - 1 ))
    DATA_START=$(( ( (NEW_P2_END + 1 + 2047) / 2048 ) * 2048 ))
    DATA_END=$(( DATA_START + DATA_SECT - 1 ))

    if [ "$NEW_P2_END" -lt "$P2_END" ]; then
        die "root is already bigger than ROOT_SIZE=$ROOT_SIZE. Was this card booted (and auto-expanded)? Reflash it, or raise ROOT_SIZE."
    fi
    [ "$DATA_END" -lt "$DISK_SECT" ] || die "target too small for ROOT_SIZE=$ROOT_SIZE + DATA_SIZE=$DATA_SIZE"

    info "Checking root filesystem"
    set +e; e2fsck -fy "$P2"; rc=$?; set -e
    [ "$rc" -le 1 ] || die "e2fsck failed on $P2 (rc=$rc)"

    if [ "$NEW_P2_END" -gt "$P2_END" ]; then
        info "Growing root (p2) to $ROOT_SIZE"
        parted -s "$DEV" unit s resizepart 2 "${NEW_P2_END}s"
        reread
        resize2fs "$P2"
    fi

    info "Creating data partition (p3, $DATA_SIZE, LABEL=data)"
    parted -s "$DEV" unit s mkpart primary ext4 "${DATA_START}s" "${DATA_END}s"
    reread
    for _ in $(seq 1 20); do [ -b "$P3" ] && break; sleep 0.5; done
    [ -b "$P3" ] || die "$P3 did not appear after mkpart"
    mkfs.ext4 -F -q -L data "$P3"
fi

# ---------------------------------------------------------------- mount
MNT=$(mktemp -d /tmp/ratt-platform.XXXXXX)
mkdir -p "$MNT/root" "$MNT/boot" "$MNT/data"
mount "$P2" "$MNT/root"
mount "$P1" "$MNT/boot"
mount "$P3" "$MNT/data"
ROOT="$MNT/root"
BOOT="$MNT/boot"
DATA="$MNT/data"
[ -f "$BOOT/cmdline.txt" ] || die "no cmdline.txt on $P1 (not a Raspberry Pi OS boot partition?)"

# Initialize /data directory skeleton on p3 (disposable state only)
mkdir -p "$DATA/ratt" "$DATA/log"
# Static per-node config lives read-only on the FAT boot partition
mkdir -p "$BOOT/ratt/certs"

# ---------------------------------------------------------------- 2. read-only fstab & runtime mounts
info "Configuring native read-only root & runtime mounts in /etc/fstab"
mkdir -p "$ROOT/data" "$ROOT/var/log" "$ROOT/tmp"

# Transform /etc/fstab safely via Python
python3 - "$ROOT/etc/fstab" <<'PY'
import sys

fstab_path = sys.argv[1]
with open(fstab_path, 'r') as f:
    lines = f.readlines()

new_lines = []
existing_mps = set()

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        new_lines.append(line)
        continue

    parts = line.split()
    if len(parts) >= 4:
        mp = parts[1]
        existing_mps.add(mp)
        opts = parts[3].split(',')

        if mp == '/':
            if 'ro' not in opts: opts.append('ro')
            if 'rw' in opts: opts.remove('rw')
            parts[3] = ','.join(opts)
            line = f"{parts[0]:<20}  {parts[1]:<15}  {parts[2]:<6}  {parts[3]:<24}  {parts[4]}  {parts[5]}\n"
        elif mp in ('/boot/firmware', '/boot'):
            if 'ro' not in opts: opts.append('ro')
            if 'rw' in opts: opts.remove('rw')
            if 'nofail' not in opts: opts.append('nofail')
            # Holds RATT TLS key: root-only (FAT has no per-file permissions)
            if not any(o.startswith(('fmask=', 'umask=')) for o in opts): opts.append('fmask=0077')
            if not any(o.startswith(('dmask=', 'umask=')) for o in opts): opts.append('dmask=0077')
            parts[3] = ','.join(opts)
            line = f"{parts[0]:<20}  {parts[1]:<15}  {parts[2]:<6}  {parts[3]:<24}  {parts[4]}  {parts[5]}\n"
        elif mp == '/data':
            parts[3] = 'defaults,noatime,nofail'
            line = f"{parts[0]:<20}  {parts[1]:<15}  {parts[2]:<6}  {parts[3]:<24}  {parts[4]}  {parts[5]}\n"

    new_lines.append(line)

extra_entries = [
    ('LABEL=data', '/data', 'ext4', 'defaults,noatime,nofail', '0', '2'),
    ('tmpfs', '/tmp', 'tmpfs', 'defaults,nosuid,nodev,size=64M', '0', '0'),
    ('tmpfs', '/var/tmp', 'tmpfs', 'defaults,nosuid,nodev,size=16M', '0', '0'),
    ('/data/log', '/var/log', 'none', 'bind,nofail', '0', '0')
]

for dev, mp, fstype, opts, d1, d2 in extra_entries:
    if mp not in existing_mps:
        new_lines.append(f"{dev:<20}  {mp:<15}  {fstype:<6}  {opts:<24}  {d1}  {d2}\n")
        existing_mps.add(mp)

with open(fstab_path, 'w') as f:
    f.writelines(new_lines)
PY

# Configure systemd-journald for persistent capped logs in /var/log (/data/log)
info "systemd-journald: persistent capped logs in /var/log (/data/log)"
mkdir -p "$ROOT/etc/systemd/journald.conf.d"
cat > "$ROOT/etc/systemd/journald.conf.d/00-ratt.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
SystemKeepFree=100M
SystemMaxFileSize=10M
MaxRetentionSec=1month
EOF

# Configure rpi-swap to pure zram (in-memory) to prevent /var/swap loop device locking rootfs
info "rpi-swap: configure pure zram swap (no disk swapfile on root)"
mkdir -p "$ROOT/etc/rpi/swap.conf.d"
cat > "$ROOT/etc/rpi/swap.conf.d/00-ratt.conf" <<'EOF'
[Main]
Mechanism=zram
EOF
rm -f "$ROOT/var/swap"

# Install /data self-healing check service (auto-reformat if severely corrupt so appliance always boots)
info "Installing /data partition auto-recovery service"
cat > "$ROOT/usr/local/sbin/ratt-data-check.sh" <<'EOF'
#!/bin/bash
# ratt-data-check v2
# /data holds ONLY disposable state: ACL + remote-config caches (re-downloaded
# from the auth server), logs, and the fake-hwclock file. Static config
# (ratt.ini, TLS certs) is on /boot/firmware/ratt, so reformatting is safe.
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

if [ "$rc" -ge 4 ] && [ "$rc" -ne 8 ]; then
    echo "WARNING: /data partition ($DATA_DEV) corrupted (e2fsck code $rc); reformatting (caches/logs only)..."
    mkfs.ext4 -F -q -L data "$DATA_DEV"
    TMPMNT=$(mktemp -d)
    mount "$DATA_DEV" "$TMPMNT"
    mkdir -p "$TMPMNT/ratt" "$TMPMNT/log" "$TMPMNT/timesync"
    umount "$TMPMNT"
    rmdir "$TMPMNT"
fi
exit 0
EOF
chmod 0755 "$ROOT/usr/local/sbin/ratt-data-check.sh"
chown root:root "$ROOT/usr/local/sbin/ratt-data-check.sh"

cat > "$ROOT/etc/systemd/system/ratt-data-check.service" <<'EOF'
[Unit]
Description=RATT /data Partition Health Check and Auto-Recovery
DefaultDependencies=no
Conflicts=shutdown.target
Before=local-fs.target data.mount
After=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ratt-data-check.sh
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
EOF
mkdir -p "$ROOT/etc/systemd/system/local-fs.target.wants"
ln -sf ../ratt-data-check.service "$ROOT/etc/systemd/system/local-fs.target.wants/ratt-data-check.service"

# Install ratt-hostname service: applies hostname from /boot/firmware/hostname.txt if present
info "Installing ratt-hostname service (auto-configures hostname from /boot/firmware)"
cat > "$ROOT/usr/local/sbin/ratt-hostname.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

NEW_HOST=""
for f in /boot/firmware/hostname.txt /boot/firmware/hostname \
         /boot/firmware/ratt/hostname.txt /boot/firmware/ratt/hostname \
         /boot/hostname.txt /boot/hostname; do
    if [ -f "$f" ]; then
        NEW_HOST="$(tr -d ' \r\t\n' < "$f")"
        break
    fi
done

if [ -z "$NEW_HOST" ]; then
    for ini in /boot/firmware/ratt/ratt.ini /boot/ratt/ratt.ini /data/ratt/ratt.ini; do
        if [ -f "$ini" ]; then
            h="$(grep -E '^[[:space:]]*HostName[[:space:]]*=' "$ini" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r\t\n' || true)"
            if [ -n "$h" ]; then
                NEW_HOST="$h"
                break
            fi
        fi
    done
fi

[ -n "$NEW_HOST" ] || exit 0

NEW_HOST="$(echo "$NEW_HOST" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')"
[ -n "$NEW_HOST" ] || exit 0

CURRENT_HOST="$(tr -d ' \r\t\n' < /etc/hostname 2>/dev/null || true)"

if [ "$NEW_HOST" != "$CURRENT_HOST" ]; then
    echo "ratt-hostname: updating hostname from '$CURRENT_HOST' to '$NEW_HOST'..."
    IS_RO=0
    if ! [ -w / ]; then
        mount -o remount,rw /
        IS_RO=1
    fi

    echo "$NEW_HOST" > /etc/hostname

    if [ -f /etc/hosts ]; then
        if [ -n "$CURRENT_HOST" ] && grep -q "\b${CURRENT_HOST}\b" /etc/hosts; then
            sed -i "s/\b${CURRENT_HOST}\b/${NEW_HOST}/g" /etc/hosts
        elif grep -q "^127\.0\.1\.1" /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOST}/" /etc/hosts
        else
            echo -e "127.0.1.1\t${NEW_HOST}" >> /etc/hosts
        fi
    fi

    hostname "$NEW_HOST" 2>/dev/null || true

    if [ "$IS_RO" -eq 1 ]; then
        sync
        mount -o remount,ro /
    fi
    echo "ratt-hostname: successfully applied hostname '$NEW_HOST'"
fi
exit 0
EOF
chmod 0755 "$ROOT/usr/local/sbin/ratt-hostname.sh"
chown root:root "$ROOT/usr/local/sbin/ratt-hostname.sh"

cat > "$ROOT/etc/systemd/system/ratt-hostname.service" <<'EOF'
[Unit]
Description=RATT Apply Hostname from Boot Partition
DefaultDependencies=no
Conflicts=shutdown.target
After=local-fs.target
Before=network-pre.target sys-subsystem-net-devices.target systemd-hostnamed.service avahi-daemon.service ssh.service ratt.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ratt-hostname.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
mkdir -p "$ROOT/etc/systemd/system/sysinit.target.wants"
ln -sf ../ratt-hostname.service "$ROOT/etc/systemd/system/sysinit.target.wants/ratt-hostname.service"

# Install convenience wrappers in /usr/local/bin delegating to scripts/ratt-rw and scripts/ratt-ro
info "Installing ratt-rw / ratt-ro convenience utilities"
cat > "$ROOT/usr/local/bin/ratt-rw" <<'EOF'
#!/usr/bin/env bash
for d in /home/*/ratt-app/scripts/ratt-rw; do
    if [ -x "$d" ]; then exec "$d" "$@"; fi
done
echo "==> Remounting root (/) as READ-WRITE..."
mount -o remount,rw /
mount -o remount,rw /boot/firmware 2>/dev/null || mount -o remount,rw /boot 2>/dev/null || true
echo "Filesystem is now READ-WRITE."
EOF
chmod 0755 "$ROOT/usr/local/bin/ratt-rw"

cat > "$ROOT/usr/local/bin/ratt-ro" <<'EOF'
#!/usr/bin/env bash
for d in /home/*/ratt-app/scripts/ratt-ro; do
    if [ -x "$d" ]; then exec "$d" "$@"; fi
done
sync
echo "==> Remounting root (/) as READ-ONLY..."
mount -o remount,ro /boot/firmware 2>/dev/null || mount -o remount,ro /boot 2>/dev/null || true
mount -o remount,ro /
echo "Filesystem is now locked READ-ONLY."
EOF
chmod 0755 "$ROOT/usr/local/bin/ratt-ro"

# fake-hwclock: store clock file on persistent /data instead of read-only rootfs
if [ -f "$ROOT/etc/default/fake-hwclock" ]; then
    sed -i 's|^#\?FILE=.*|FILE=/data/fake-hwclock.data|' "$ROOT/etc/default/fake-hwclock"
else
    mkdir -p "$ROOT/etc/default"
    echo 'FILE=/data/fake-hwclock.data' > "$ROOT/etc/default/fake-hwclock"
fi

# ---------------------------------------------------------------- 3. cmdline.txt
info "cmdline.txt"
set -f   # no globbing on tokens like ds=nocloud;i=...
NEW=""
for tok in $(tr '\n' ' ' < "$BOOT/cmdline.txt"); do
    case "$tok" in
        resize|init=/usr/lib/raspi-config/init_resize.sh) continue ;;
    esac
    [[ " $NEW " == *" $tok "* ]] || NEW="$NEW $tok"     # drop duplicates
done
for tok in fbcon=map:9 vt.global_cursor_default=0 consoleblank=0; do
    [[ " $NEW " == *" $tok "* ]] || NEW="$NEW $tok"
done
set +f
printf '%s\n' "${NEW# }" > "$BOOT/cmdline.txt"
[ "$(wc -l < "$BOOT/cmdline.txt")" -eq 1 ] || die "cmdline.txt is not a single line"
echo "    $(cat "$BOOT/cmdline.txt")"

# ---------------------------------------------------------------- 4. LCD splash
info "LCD boot splash from $SPLASH_SRC"
[ -f "$SPLASH_SRC" ] || die "splash source not found: $SPLASH_SRC"
RAW=$(mktemp /tmp/ratt-splash.XXXXXX)
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -loglevel error -y -i "$SPLASH_SRC" -vf "scale=${LCD_W}:${LCD_H}" \
        -f rawvideo -pix_fmt rgb565le "$RAW"
else
    python3 - "$SPLASH_SRC" "$RAW" "$LCD_W" "$LCD_H" <<'PY'
import sys
from PyQt5.QtCore import QCoreApplication, Qt
from PyQt5.QtGui import QImage
app = QCoreApplication(sys.argv)
src, dst, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
img = QImage(src)
if img.isNull():
    sys.exit("could not load " + src)
img = img.scaled(w, h, Qt.IgnoreAspectRatio, Qt.SmoothTransformation).convertToFormat(QImage.Format_RGB16)
ptr = img.constBits(); ptr.setsize(img.byteCount())
data = bytes(ptr)
bpl = img.bytesPerLine()
with open(dst, "wb") as f:
    for y in range(h):
        f.write(data[y * bpl : y * bpl + w * 2])
PY
fi
SIZE=$(stat -c %s "$RAW")
[ "$SIZE" -eq "$SPLASH_BYTES" ] || die "splash.raw is $SIZE bytes, expected $SPLASH_BYTES"
install -o root -g root -m 0644 "$RAW" "$ROOT/etc/splash.raw"
rm -f "$RAW"

# Match the fbtft framebuffer by driver name, not by fb number: it's fb1 with
# vc4-kms (HDMI takes fb0) but fb0 on a headless config. Same logic as ratt.py.
cat > "$ROOT/usr/local/sbin/show-splash.sh" <<'EOF'
#!/bin/sh
# Draw /etc/splash.raw on the ST7789 (fbtft) framebuffer. Called by udev.
FB="${1:-fb1}"
NAME=$(cat "/sys/class/graphics/$FB/name" 2>/dev/null | tr 'A-Z' 'a-z')
case "$NAME" in
    *st7789*|*fbtft*|*st7735*) ;;
    *) exit 0 ;;
esac
[ -e "/dev/$FB" ] && [ -f /etc/splash.raw ] || exit 0
sleep 0.1
cat /etc/splash.raw > "/dev/$FB"
EOF
chown root:root "$ROOT/usr/local/sbin/show-splash.sh"
chmod 0755 "$ROOT/usr/local/sbin/show-splash.sh"

cat > "$ROOT/etc/udev/rules.d/99-st7789-splash.rules" <<'EOF'
# Draw the RATT boot splash as soon as the fbtft LCD framebuffer registers (~12s into boot)
ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb[0-9]*", RUN+="/usr/local/sbin/show-splash.sh %k"
EOF
chown root:root "$ROOT/etc/udev/rules.d/99-st7789-splash.rules"
chmod 0644 "$ROOT/etc/udev/rules.d/99-st7789-splash.rules"

# ---------------------------------------------------------------- 5. user 'ratt' & passwordless sudo
info "Ensuring user 'ratt' exists with passwordless sudo"
RATT_IDS=$(python3 - "$ROOT" <<'PY'
import sys, os

root = sys.argv[1]
passwd_path = os.path.join(root, "etc/passwd")
shadow_path = os.path.join(root, "etc/shadow")
group_path = os.path.join(root, "etc/group")
gshadow_path = os.path.join(root, "etc/gshadow")

username = "ratt"

# Read passwd
with open(passwd_path, "r") as f:
    passwd_lines = f.readlines()
users = {line.split(":")[0]: line for line in passwd_lines}

# Read group
with open(group_path, "r") as f:
    group_lines = f.readlines()

groups = {}
max_gid = 999
for line in group_lines:
    parts = line.strip().split(":")
    if len(parts) >= 3:
        groups[parts[0]] = parts
        try:
            gid = int(parts[2])
            if gid > max_gid:
                max_gid = gid
        except ValueError:
            pass

if username in users:
    parts = users[username].split(":")
    uid = int(parts[2])
    gid = int(parts[3])
else:
    max_uid = 999
    for line in passwd_lines:
        try:
            u = int(line.split(":")[2])
            if u > max_uid:
                max_uid = u
        except ValueError:
            pass
    uid = max_uid + 1
    gid = uid

    if username not in groups:
        group_lines.append(f"{username}:x:{gid}:\n")
        groups[username] = [username, "x", str(gid), ""]

    passwd_lines.append(f"{username}:x:{uid}:{gid}:RATT User,,,:/home/{username}:/bin/bash\n")
    with open(passwd_path, "w") as f:
        f.writelines(passwd_lines)

    shadow_lines = []
    if os.path.exists(shadow_path):
        with open(shadow_path, "r") as f:
            shadow_lines = f.readlines()
    shadow_lines = [l for l in shadow_lines if not l.startswith(f"{username}:")]
    shadow_lines.append(f"{username}:*:19800:0:99999:7:::\n")
    with open(shadow_path, "w") as f:
        f.writelines(shadow_lines)

target_groups = ["sudo", "adm", "dialout", "audio", "video", "plugdev", "users", "input", "netdev", "gpio", "i2c", "spi"]
new_group_lines = []
for line in group_lines:
    parts = line.strip().split(":")
    if len(parts) >= 4:
        gname, gpwd, ggid, gmembers = parts[0], parts[1], parts[2], parts[3]
        m_list = [m for m in gmembers.split(",") if m]
        if gname in target_groups and username not in m_list:
            m_list.append(username)
        new_group_lines.append(f"{gname}:{gpwd}:{ggid}:{','.join(m_list)}\n")
    else:
        new_group_lines.append(line)

with open(group_path, "w") as f:
    f.writelines(new_group_lines)

if os.path.exists(gshadow_path):
    with open(gshadow_path, "r") as f:
        gshadow_lines = f.readlines()
    new_gshadow_lines = []
    for line in gshadow_lines:
        parts = line.strip().split(":")
        if len(parts) >= 4:
            gname, gpwd, gadm, gmembers = parts[0], parts[1], parts[2], parts[3]
            m_list = [m for m in gmembers.split(",") if m]
            if gname in target_groups and username not in m_list:
                m_list.append(username)
            new_gshadow_lines.append(f"{gname}:{gpwd}:{gadm}:{','.join(m_list)}\n")
        else:
            new_gshadow_lines.append(line)
    if not any(l.startswith(f"{username}:") for l in new_gshadow_lines):
        new_gshadow_lines.append(f"{username}:*::\n")
    with open(gshadow_path, "w") as f:
        f.writelines(new_gshadow_lines)

print(f"{uid}:{gid}")
PY
)
RATT_UID="${RATT_IDS%:*}"
RATT_GID="${RATT_IDS#*:}"

HOMEDIR="$ROOT/home/ratt"
mkdir -p "$HOMEDIR"
if [ -d "$ROOT/etc/skel" ]; then
    cp -r -n "$ROOT/etc/skel/." "$HOMEDIR/" 2>/dev/null || true
fi

# Passwordless sudo for ratt
mkdir -p "$ROOT/etc/sudoers.d"
cat > "$ROOT/etc/sudoers.d/010_ratt-nopasswd" <<'EOF'
ratt ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 "$ROOT/etc/sudoers.d/010_ratt-nopasswd"
chown root:root "$ROOT/etc/sudoers.d/010_ratt-nopasswd"

# ---------------------------------------------------------------- 6. SSH authorized_keys
if [ -n "$SSH_KEY_FILE" ]; then
    [ -f "$SSH_KEY_FILE" ] || die "SSH key file not found: $SSH_KEY_FILE"
    info "Installing SSH authorized_keys from $SSH_KEY_FILE into ~ratt/.ssh/authorized_keys"
    mkdir -p "$HOMEDIR/.ssh"
    chmod 0700 "$HOMEDIR/.ssh"
    touch "$HOMEDIR/.ssh/authorized_keys"
    while IFS= read -r keyline || [ -n "$keyline" ]; do
        [ -z "$keyline" ] && continue
        [[ "$keyline" =~ ^[[:space:]]*# ]] && continue
        if ! grep -qF "$keyline" "$HOMEDIR/.ssh/authorized_keys"; then
            echo "$keyline" >> "$HOMEDIR/.ssh/authorized_keys"
        fi
    done < "$SSH_KEY_FILE"
    chmod 0600 "$HOMEDIR/.ssh/authorized_keys"
fi

chown -R "${RATT_UID}:${RATT_GID}" "$HOMEDIR"

# ---------------------------------------------------------------- 7. no console on the LCD
info "Masking getty@tty1"
ln -sf /dev/null "$ROOT/etc/systemd/system/getty@tty1.service"

sync
info "Done. Layout:"
parted -s "$DEV" unit MiB print | sed 's/^/    /'
cat <<EOF

Next steps:
  1. Boot the card in the Pi. Log in as user 'ratt' (passwordless sudo enabled).
     Confirm /data and /var/log are mounted (check: findmnt /data /var/log).
  2. The root filesystem is NATIVE READ-ONLY. To clone and run setup:
       sudo ratt-rw
       git clone ... /home/ratt/ratt-app && cd /home/ratt/ratt-app && sudo ./setup.sh
     (setup.sh automatically handles read-write remounting and locks it back down)
  3. Shut down, put the card back in the host, and run:
       sudo scripts/sanitize-image.sh <device | image>
EOF
