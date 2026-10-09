#!/usr/bin/env bash
#
# RATT platform/OS prep for a Raspberry Pi OS Lite (Trixie) SD card or .img
#
# Runs on a Linux HOST against an UNMOUNTED, NEVER-BOOTED card or image file.
# This is "stuff the OS does for RATT" (see OS_PACKAGING.md); the app itself is
# installed afterwards, on the Pi, with setup.sh.
#
#   sudo scripts/platform-setup.sh /dev/sdX            # SD card in a reader
#   sudo scripts/platform-setup.sh raspios-lite.img    # image file (grown as needed)
#
# What it does:
#   1. Grows root (p2) to ROOT_SIZE and creates p3 (DATA_SIZE, ext4, LABEL=data)
#      right after it. Because p3 sits directly after root, the stock first-boot
#      root expansion has no room to grow into, so it can't eat the data partition.
#   2. Adds LABEL=data -> /data to /etc/fstab.
#   3. cmdline.txt: keeps it one line, strips legacy resize tokens, adds
#      fbcon=map:9 vt.global_cursor_default=0 consoleblank=0.
#   4. LCD boot splash: converts gui/images/ratt_bootscreen.png to raw RGB565 and
#      installs a udev rule that draws it as soon as the fbtft framebuffer appears.
#   5. Masks getty@tty1 so no console login lands on the LCD.
#
# Env overrides: ROOT_SIZE (default 6G), DATA_SIZE (default 1G),
#                SPLASH_SRC (default gui/images/ratt_bootscreen.png)
#
# Safe to re-run: partitioning is skipped if p3 is already LABEL=data.

set -euo pipefail

ROOT_SIZE="${ROOT_SIZE:-6G}"
DATA_SIZE="${DATA_SIZE:-1G}"
LCD_W=320
LCD_H=240
SPLASH_BYTES=$((LCD_W * LCD_H * 2))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SPLASH_SRC="${SPLASH_SRC:-${REPO_DIR}/gui/images/ratt_bootscreen.png}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$#" -eq 1 ] || die "usage: sudo $0 <block-device | image-file>"
[ "$EUID" -eq 0 ] || die "must run as root"
TARGET="$1"

for c in parted partprobe partx e2fsck resize2fs mkfs.ext4 blkid blockdev losetup numfmt udevadm; do
    command -v "$c" >/dev/null 2>&1 || die "missing host tool: $c"
done

to_sectors() { echo $(( $(numfmt --from=iec "$1") / 512 )); }
p_field()    { parted -sm "$1" unit s print | awk -F: -v n="$2" -v f="$3" '$1==n {sub("s","",$f); print $f}'; }

DEV=""; LOOP=""; MNT=""
cleanup() {
    set +e
    if [ -n "$MNT" ]; then
        umount "$MNT/boot" 2>/dev/null
        umount "$MNT/root" 2>/dev/null
        rmdir "$MNT/boot" "$MNT/root" "$MNT" 2>/dev/null
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
mkdir -p "$MNT/root" "$MNT/boot"
mount "$P2" "$MNT/root"
mount "$P1" "$MNT/boot"
ROOT="$MNT/root"
BOOT="$MNT/boot"
[ -f "$BOOT/cmdline.txt" ] || die "no cmdline.txt on $P1 (not a Raspberry Pi OS boot partition?)"

# ---------------------------------------------------------------- 2. fstab
info "fstab: LABEL=data -> /data"
mkdir -p "$ROOT/data"
if ! grep -q '^LABEL=data[[:space:]]' "$ROOT/etc/fstab"; then
    echo "LABEL=data  /data  ext4  defaults,noatime,nofail  0  2" >> "$ROOT/etc/fstab"
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

# ---------------------------------------------------------------- 5. no console on the LCD
info "Masking getty@tty1"
ln -sf /dev/null "$ROOT/etc/systemd/system/getty@tty1.service"

sync
info "Done. Layout:"
parted -s "$DEV" unit MiB print | sed 's/^/    /'
cat <<EOF

Next steps:
  1. Boot the card in the Pi. /data should be mounted (check: findmnt /data).
  2. Clone the app and run:  sudo ./setup.sh
     (ratt.ini, the ACL cache and certs go to /data/ratt and /data/certs on p3)
  3. Shut down, put the card back in the host, and run:
       sudo scripts/sanitize-image.sh <device | image>
EOF
