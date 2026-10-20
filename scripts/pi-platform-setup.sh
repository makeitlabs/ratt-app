#!/usr/bin/env bash
#
# RATT Platform/OS Setup for Raspberry Pi (LOCAL RUN)
#
# Runs DIRECTLY on a Raspberry Pi (e.g. via SSH or local console).
# Configures the OS platform environment for RATT with strict idempotency:
# every step checks whether it has already been completed and skips if so.
#
# Usage:
#   sudo scripts/pi-platform-setup.sh [--ssh-key <authorized_key_file>]
#   sudo scripts/pi-platform-setup.sh ~/.ssh/id_ed25519.pub
#

set -euo pipefail

LCD_W=320
LCD_H=240
SPLASH_BYTES=$((LCD_W * LCD_H * 2))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SPLASH_SRC="${SPLASH_SRC:-${REPO_DIR}/gui/images/ratt_bootscreen.png}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

[ "$EUID" -eq 0 ] || die "must run as root (use: sudo $0)"

SSH_KEY_FILE="${SSH_KEY_FILE:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
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
            die "unknown option: $1"
            ;;
        *)
            if [ -z "$SSH_KEY_FILE" ]; then
                SSH_KEY_FILE="$1"
            else
                die "unexpected extra argument: $1"
            fi
            shift
            ;;
    esac
done

echo "========================================================"
echo " RATT Local Platform / OS Setup"
echo " Running on live Raspberry Pi"
echo "========================================================"

# ---------------------------------------------------------------- 1. /data partition
info "[1/9] Checking /data partition..."
if mountpoint -q /data; then
    info "  -> /data is already mounted; skipping partitioning"
elif [ -b /dev/disk/by-label/data ]; then
    info "  -> Found partition with LABEL=data; mounting to /data..."
    mkdir -p /data
    mount /dev/disk/by-label/data /data
else
    ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    DISK_DEV=""
    [ -n "$ROOT_SRC" ] && DISK_DEV="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null || true)"
    P3=""
    if [ -n "$DISK_DEV" ]; then
        if [ -b "${DISK_DEV}p3" ]; then P3="${DISK_DEV}p3";
        elif [ -b "${DISK_DEV}3" ]; then P3="${DISK_DEV}3"; fi
    fi

    if [ -n "$P3" ]; then
        info "  -> Found 3rd partition $P3"
        if [ "$(blkid -s LABEL -o value "$P3" 2>/dev/null)" != "data" ]; then
            info "  -> Formatting $P3 as ext4 with LABEL=data..."
            mkfs.ext4 -F -q -L data "$P3"
        fi
        mkdir -p /data
        mount "$P3" /data
    else
        warn "  -> No /data partition found. Creating /data directory on root filesystem."
        warn "     (For a dedicated partition on a golden image, run platform-setup.sh on host before first boot.)"
        mkdir -p /data
    fi
fi
# /data: disposable state only (ACL/remote-config caches, logs, clock file)
mkdir -p /data/ratt /data/log

# ---------------------------------------------------------------- 2. read-only fstab
info "[2/9] Checking /etc/fstab for Native Read-Only Root..."
FSTAB_CONFIGURED=1
grep -q '/data/log[[:space:]]\+/var/log' /etc/fstab || FSTAB_CONFIGURED=0
grep -E '^[^\#].*[[:space:]]/[[:space:]].*\bro\b' /etc/fstab || FSTAB_CONFIGURED=0

if [ "$FSTAB_CONFIGURED" -eq 1 ]; then
    info "  -> /etc/fstab is already configured for read-only root; skipping"
else
    mkdir -p /data/log /var/log /tmp

    python3 - /etc/fstab <<'PY'
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
    info "  -> Configured /etc/fstab (takes effect on reboot or via ratt-ro)"
fi

# Static RATT config + TLS key live on the FAT boot partition (/boot/firmware/ratt).
# FAT has no per-file permissions, so restrict the whole mount to root.
# Separate from the block above so already-configured nodes get upgraded too.
if awk '$1 !~ /^#/ && $2=="/boot/firmware" && $4 !~ /(fmask|umask)=/ {f=1} END {exit !f}' /etc/fstab; then
    sed -i -E '/^[^#][^[:space:]]*[[:space:]]+\/boot\/firmware[[:space:]]/ s/^([^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)/\1\2,fmask=0077,dmask=0077/' /etc/fstab
    info "  -> Added fmask=0077,dmask=0077 to /boot/firmware in /etc/fstab (takes effect on reboot)"
else
    info "  -> /boot/firmware permissions already restricted in /etc/fstab; skipping"
fi
mkdir -p /boot/firmware/ratt/certs 2>/dev/null || warn "  -> could not create /boot/firmware/ratt/certs (boot partition read-only?); setup.sh will create it"

# ---------------------------------------------------------------- 3. systemd-journald
info "[3/9] Checking systemd-journald configuration..."
JOURNAL_CONF="/etc/systemd/journald.conf.d/00-ratt.conf"
if [ -f "$JOURNAL_CONF" ] && grep -q 'Storage=persistent' "$JOURNAL_CONF" && grep -q 'SystemMaxUse=50M' "$JOURNAL_CONF"; then
    info "  -> $JOURNAL_CONF already configured; skipping"
else
    mkdir -p /etc/systemd/journald.conf.d
    cat > "$JOURNAL_CONF" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
SystemKeepFree=100M
SystemMaxFileSize=10M
MaxRetentionSec=1month
EOF
    info "  -> Configured systemd-journald for persistent 50MB logs in /var/log (/data/log)"
fi

# Configure rpi-swap to pure zram (in-memory) to prevent /var/swap loop device locking rootfs
SWAP_CONF="/etc/rpi/swap.conf.d/00-ratt.conf"
if [ -f "$SWAP_CONF" ] && grep -q 'Mechanism=zram' "$SWAP_CONF"; then
    info "  -> $SWAP_CONF already configured; skipping"
else
    mkdir -p /etc/rpi/swap.conf.d
    cat > "$SWAP_CONF" <<'EOF'
[Main]
Mechanism=zram
EOF
    rm -f /var/swap
    info "  -> Configured rpi-swap to pure in-memory zram (removes /var/swap)"
fi

# ---------------------------------------------------------------- 4. /data auto-recovery service
info "[4/9] Checking /data auto-recovery health check service..."
# v1 of this script restored a template ratt.ini onto /data after reformatting;
# v2 only recreates empty dirs (config now lives on /boot/firmware/ratt).
if [ -f /etc/systemd/system/ratt-data-check.service ] && [ -x /usr/local/sbin/ratt-data-check.sh ] \
   && grep -q 'ratt-data-check v2' /usr/local/sbin/ratt-data-check.sh; then
    info "  -> ratt-data-check.service (v2) already installed; skipping"
else
    cat > /usr/local/sbin/ratt-data-check.sh <<'EOF'
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
    chmod 0755 /usr/local/sbin/ratt-data-check.sh
    chown root:root /usr/local/sbin/ratt-data-check.sh

    cat > /etc/systemd/system/ratt-data-check.service <<'EOF'
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
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable ratt-data-check.service 2>/dev/null || true
    info "  -> Installed and enabled ratt-data-check.service"
fi

# Install ratt-hostname service: applies hostname from /boot/firmware/hostname.txt if present
if [ -f /etc/systemd/system/ratt-hostname.service ] && [ -x /usr/local/sbin/ratt-hostname.sh ]; then
    info "  -> ratt-hostname.service already installed; skipping"
else
    cat > /usr/local/sbin/ratt-hostname.sh <<'EOF'
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
    chmod 0755 /usr/local/sbin/ratt-hostname.sh
    chown root:root /usr/local/sbin/ratt-hostname.sh

    cat > /etc/systemd/system/ratt-hostname.service <<'EOF'
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
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable ratt-hostname.service 2>/dev/null || true
    info "  -> Installed and enabled ratt-hostname.service"
fi

# ---------------------------------------------------------------- 5. ratt-rw / ratt-ro helpers
info "[5/9] Checking ratt-rw / ratt-ro utilities..."
if [ -x /usr/local/bin/ratt-rw ] && [ -x /usr/local/bin/ratt-ro ]; then
    info "  -> ratt-rw and ratt-ro already installed in /usr/local/bin; skipping"
else
    cat > /usr/local/bin/ratt-rw <<'EOF'
#!/usr/bin/env bash
for d in /home/*/ratt-app/scripts/ratt-rw; do
    if [ -x "$d" ]; then exec "$d" "$@"; fi
done
echo "==> Remounting root (/) as READ-WRITE..."
mount -o remount,rw /
mount -o remount,rw /boot/firmware 2>/dev/null || mount -o remount,rw /boot 2>/dev/null || true
echo "Filesystem is now READ-WRITE."
EOF
    chmod 0755 /usr/local/bin/ratt-rw

    cat > /usr/local/bin/ratt-ro <<'EOF'
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
    chmod 0755 /usr/local/bin/ratt-ro
    info "  -> Installed ratt-rw and ratt-ro wrappers in /usr/local/bin"
fi

# ---------------------------------------------------------------- 6. fake-hwclock
info "[6/9] Checking fake-hwclock..."
if grep -q '^FILE=/data/fake-hwclock.data' /etc/default/fake-hwclock 2>/dev/null; then
    info "  -> fake-hwclock already points to /data/fake-hwclock.data; skipping"
else
    mkdir -p /etc/default
    if [ -f /etc/default/fake-hwclock ]; then
        sed -i 's|^#\?FILE=.*|FILE=/data/fake-hwclock.data|' /etc/default/fake-hwclock
    else
        echo 'FILE=/data/fake-hwclock.data' > /etc/default/fake-hwclock
    fi
    info "  -> Configured fake-hwclock to save to /data/fake-hwclock.data"
fi

# ---------------------------------------------------------------- 7. cmdline.txt
info "[7/9] Checking cmdline.txt..."
CMDLINE="/boot/firmware/cmdline.txt"
[ -f "$CMDLINE" ] || CMDLINE="/boot/cmdline.txt"

if [ -f "$CMDLINE" ]; then
    if grep -q 'fbcon=map:9' "$CMDLINE"; then
        info "  -> fbcon=map:9 already configured in $CMDLINE; skipping"
    else
        set -f
        NEW=""
        for tok in $(tr '\n' ' ' < "$CMDLINE"); do
            case "$tok" in
                resize|init=/usr/lib/raspi-config/init_resize.sh) continue ;;
            esac
            [[ " $NEW " == *" $tok "* ]] || NEW="$NEW $tok"
        done
        for tok in fbcon=map:9 vt.global_cursor_default=0 consoleblank=0; do
            [[ " $NEW " == *" $tok "* ]] || NEW="$NEW $tok"
        done
        set +f
        printf '%s\n' "${NEW# }" > "$CMDLINE"
        info "  -> Added fbcon=map:9 vt.global_cursor_default=0 consoleblank=0 to $CMDLINE"
    fi
else
    warn "  -> $CMDLINE not found; skipping cmdline tweaks"
fi

# ---------------------------------------------------------------- 8. LCD splash
info "[8/9] Checking LCD boot splash..."
if [ -f /etc/splash.raw ] && [ "$(stat -c %s /etc/splash.raw 2>/dev/null)" -eq "$SPLASH_BYTES" ] && [ -f /etc/udev/rules.d/99-st7789-splash.rules ]; then
    info "  -> /etc/splash.raw ($SPLASH_BYTES B) and udev rule already installed; skipping"
else
    if [ -f "${REPO_DIR}/gui/images/splash.raw" ] && [ "$(stat -c %s "${REPO_DIR}/gui/images/splash.raw" 2>/dev/null)" -eq "$SPLASH_BYTES" ]; then
        cp "${REPO_DIR}/gui/images/splash.raw" /etc/splash.raw
        info "  -> Installed /etc/splash.raw from pre-built image"
    elif command -v ffmpeg >/dev/null 2>&1 && [ -f "$SPLASH_SRC" ]; then
        ffmpeg -loglevel error -y -i "$SPLASH_SRC" \
            -filter_complex "color=black:s=${LCD_W}x${LCD_H} [bg]; [0:v] scale=${LCD_W}:${LCD_H} [fg]; [bg][fg] overlay=shortest=1" \
            -f rawvideo -pix_fmt rgb565le /etc/splash.raw
        info "  -> Generated /etc/splash.raw using ffmpeg"
    elif [ -f "$SPLASH_SRC" ]; then
        python3 - "$SPLASH_SRC" /etc/splash.raw "$LCD_W" "$LCD_H" <<'PY'
import sys
from PyQt5.QtCore import QCoreApplication, Qt
from PyQt5.QtGui import QImage, QPainter
app = QCoreApplication(sys.argv)
src, dst, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
img = QImage(src)
if img.isNull():
    sys.exit("could not load " + src)
bg = QImage(w, h, QImage.Format_RGB32)
bg.fill(Qt.black)
painter = QPainter(bg)
scaled_img = img.scaled(w, h, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
painter.drawImage(0, 0, scaled_img)
painter.end()
bg = bg.convertToFormat(QImage.Format_RGB16)
ptr = bg.constBits(); ptr.setsize(bg.byteCount())
data = bytes(ptr)
bpl = bg.bytesPerLine()
with open(dst, "wb") as f:
    for y in range(h):
        f.write(data[y * bpl : y * bpl + w * 2])
PY
        info "  -> Generated /etc/splash.raw using PyQt5"
    else
        warn "  -> Cannot build /etc/splash.raw ($SPLASH_SRC missing); skipping splash"
    fi

    if [ -f /etc/splash.raw ]; then
        chmod 0644 /etc/splash.raw
        chown root:root /etc/splash.raw

        cat > /usr/local/sbin/show-splash.sh <<'EOF'
#!/bin/sh
# Draw /etc/splash.raw on the ST7789 framebuffer.
[ -f /etc/splash.raw ] || exit 0

TARGET_FB=""
if [ -n "$1" ] && [ -e "/dev/$1" ]; then
    TARGET_FB="$1"
fi

if [ -z "$TARGET_FB" ]; then
    for fb in fb0 fb1; do
        if [ -e "/dev/$fb" ]; then
            NAME=$(cat "/sys/class/graphics/$fb/name" 2>/dev/null | tr 'A-Z' 'a-z')
            case "$NAME" in
                *st7789*|*fbtft*|*st7735*|*sitronix*) TARGET_FB="$fb"; break ;;
            esac
        fi
    done
fi

if [ -z "$TARGET_FB" ]; then
    if [ -e /dev/fb0 ]; then
        TARGET_FB="fb0"
    elif [ -e /dev/fb1 ]; then
        TARGET_FB="fb1"
    fi
fi

DEV=""
if [ -n "$TARGET_FB" ] && [ -e "/dev/$TARGET_FB" ]; then
    DEV="/dev/$TARGET_FB"
elif [ -n "$TARGET_FB" ] && [ -e "$TARGET_FB" ]; then
    DEV="$TARGET_FB"
fi

if [ -n "$DEV" ]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$DEV" /etc/splash.raw <<'PY'
import sys, mmap
try:
    fb_path, raw_path = sys.argv[1], sys.argv[2]
    with open(raw_path, 'rb') as rf:
        raw_data = rf.read()
    with open(fb_path, 'r+b') as f:
        mm = mmap.mmap(f.fileno(), len(raw_data), mmap.MAP_SHARED, mmap.PROT_WRITE)
        mm.seek(0)
        mm.write(raw_data)
        mm.flush()
        mm.close()
except Exception:
    pass
PY
    else
        cat /etc/splash.raw > "$DEV" 2>/dev/null || true
    fi
fi
EOF
        chown root:root /usr/local/sbin/show-splash.sh
        chmod 0755 /usr/local/sbin/show-splash.sh

        cat > /etc/udev/rules.d/99-st7789-splash.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb[0-9]*", RUN+="/usr/local/sbin/show-splash.sh %k"
EOF
        chown root:root /etc/udev/rules.d/99-st7789-splash.rules
        chmod 0644 /etc/udev/rules.d/99-st7789-splash.rules
        info "  -> Installed /usr/local/sbin/show-splash.sh and udev rule"
    fi
fi

# ---------------------------------------------------------------- 9. user 'ratt', sudoers, SSH keys, getty
info "[9/9] Checking user 'ratt', sudoers, and console..."
if id ratt >/dev/null 2>&1; then
    info "  -> User 'ratt' already exists; skipping useradd"
else
    useradd -m -s /bin/bash -U ratt
    info "  -> Created user 'ratt'"
fi

# Ensure user ratt is in hardware groups
for g in sudo adm dialout audio video plugdev users input netdev gpio i2c spi; do
    if getent group "$g" >/dev/null 2>&1; then
        usermod -a -G "$g" ratt 2>/dev/null || true
    fi
done

# Passwordless sudo for ratt
if [ -f /etc/sudoers.d/010_ratt-nopasswd ]; then
    info "  -> Passwordless sudo already configured (/etc/sudoers.d/010_ratt-nopasswd); skipping"
else
    cat > /etc/sudoers.d/010_ratt-nopasswd <<'EOF'
ratt ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 0440 /etc/sudoers.d/010_ratt-nopasswd
    chown root:root /etc/sudoers.d/010_ratt-nopasswd
    info "  -> Installed /etc/sudoers.d/010_ratt-nopasswd"
fi

# Optional SSH authorized_keys
HOMEDIR="/home/ratt"
if [ -n "$SSH_KEY_FILE" ]; then
    [ -f "$SSH_KEY_FILE" ] || die "SSH key file not found: $SSH_KEY_FILE"
    info "  -> Checking SSH authorized_keys from $SSH_KEY_FILE..."
    mkdir -p "$HOMEDIR/.ssh"
    chmod 0700 "$HOMEDIR/.ssh"
    touch "$HOMEDIR/.ssh/authorized_keys"
    ADDED=0
    while IFS= read -r keyline || [ -n "$keyline" ]; do
        [ -z "$keyline" ] && continue
        [[ "$keyline" =~ ^[[:space:]]*# ]] && continue
        if ! grep -qF "$keyline" "$HOMEDIR/.ssh/authorized_keys"; then
            echo "$keyline" >> "$HOMEDIR/.ssh/authorized_keys"
            ADDED=$((ADDED + 1))
        fi
    done < "$SSH_KEY_FILE"
    chmod 0600 "$HOMEDIR/.ssh/authorized_keys"
    chown -R ratt:ratt "$HOMEDIR/.ssh"
    info "  -> Injected $ADDED new key(s) into ~ratt/.ssh/authorized_keys"
fi

# Mask getty@tty1
if [ -L /etc/systemd/system/getty@tty1.service ] && [ "$(readlink /etc/systemd/system/getty@tty1.service)" = "/dev/null" ]; then
    info "  -> getty@tty1 is already masked; skipping"
else
    systemctl mask getty@tty1.service 2>/dev/null || ln -sf /dev/null /etc/systemd/system/getty@tty1.service
    info "  -> Masked getty@tty1 (keeps console off LCD display)"
fi

echo ""
echo "========================================================"
echo " Local Platform Setup complete!"
echo " "
echo " Summary:"
echo "   - /data initialized for disposable state (/data/ratt caches, /data/log)"
echo "   - Static config dir /boot/firmware/ratt (ratt.ini, certs/), root-only FAT perms"
echo "   - Native Read-Only Root configured in /etc/fstab"
echo "   - systemd-journald configured to persist bounded logs to /data/log"
echo "   - /data auto-recovery health check service installed"
echo "   - Convenience helpers 'ratt-rw' and 'ratt-ro' installed in /usr/local/bin"
echo "   - fake-hwclock redirected to /data/fake-hwclock.data"
echo "   - User 'ratt' configured with passwordless sudo"
echo "   - LCD splash and boot options configured"
echo ""
echo " Next steps:"
echo "   - To install/update application: sudo ./setup.sh"
echo "   - To lock root read-only now:     sudo ratt-ro (or reboot)"
echo "   - To unlock root later:          sudo ratt-rw"
echo "========================================================"
