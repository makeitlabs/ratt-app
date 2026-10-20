#!/usr/bin/env bash
#
# RATT App Setup Script for Orange Pi Zero 2W (Ubuntu Noble / Linux 6.1.x)
# Automates system setup for Orange Pi Zero 2W plugged into RATT shield.
#

set -euo pipefail

# Check root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script as root or with sudo:"
  echo "  sudo ./setup-orangepi.sh"
  exit 1
fi

IS_RO=0
if ! [ -w / ]; then
  echo "  -> Root filesystem is read-only; remounting read-write for setup..."
  mount -o remount,rw /
  IS_RO=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"

echo "========================================================"
echo " RATT Application Automated Setup (Orange Pi Zero 2W)"
echo " Target OS: Ubuntu Noble (24.04 LTS) / Linux 6.1-sun50iw9"
echo " Installation Directory: ${SCRIPT_DIR}"
echo "========================================================"

# 1. Update APT and Install Dependencies
echo "[1/8] Installing system dependencies via apt..."
apt-get update -y
apt-get install -y --no-install-recommends \
    python3 \
    python3-pyqt5 \
    python3-pyqt5.qtmultimedia \
    python3-pyqt5.qtserialport \
    python3-pyqt5.qtquick \
    qml-module-qtquick-controls \
    qml-module-qtquick-controls2 \
    qml-module-qtquick-layouts \
    qml-module-qtquick-window2 \
    qml-module-qtmultimedia \
    python3-paho-mqtt \
    python3-libgpiod \
    gpiod \
    device-tree-compiler \
    alsa-utils \
    i2c-tools \
    mosquitto

# 2. Build and Install Device Tree Overlay
echo "[2/8] Building and installing Orange Pi Device Tree Overlay (ratt.dtbo)..."
DTS_FILE="${SCRIPT_DIR}/device-tree/ratt-orangepi.dts"
OVERLAY_DIR="/boot/overlay-user"
mkdir -p "$OVERLAY_DIR"

if [ -f "$DTS_FILE" ]; then
    dtc -@ -I dts -O dtb -o "${OVERLAY_DIR}/ratt.dtbo" "$DTS_FILE"
    echo "  -> Compiled ${DTS_FILE} to ${OVERLAY_DIR}/ratt.dtbo"
else
    echo "  -> WARNING: ${DTS_FILE} not found! Skipping overlay compilation."
fi

# Clean up stale udev gpio-keys rules if any
rm -f /etc/udev/rules.d/99-gpio-keys.rules

for u in "$REAL_USER" "ratt" "bkg"; do
    if [ -n "$u" ] && id "$u" >/dev/null 2>&1; then
        usermod -a -G input,video,gpio,i2c,spi,audio,dialout "$u" 2>/dev/null || true
        echo "  -> Added $u to input, video, gpio, i2c, spi, audio, and dialout groups"
    fi
done

# 3. Configure Orange Pi Boot Environment (/boot/orangepiEnv.txt)
echo "[3/8] Updating /boot/orangepiEnv.txt..."
ENV_TXT="/boot/orangepiEnv.txt"

if [ -f "$ENV_TXT" ]; then
    set_env_param() {
        local key="$1"
        local val="$2"
        if grep -qE "^[[:space:]]*${key}=" "$ENV_TXT"; then
            sed -i "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$ENV_TXT"
            echo "  + Updated: ${key}=${val}"
        else
            echo "${key}=${val}" >> "$ENV_TXT"
            echo "  + Added: ${key}=${val}"
        fi
    }

    # Ensure user_overlays includes ratt
    CURRENT_USER_OVERLAYS="$(grep -E "^[[:space:]]*user_overlays=" "$ENV_TXT" | cut -d= -f2- | tr -d ' \r\t\n' || true)"
    if [ -z "$CURRENT_USER_OVERLAYS" ]; then
        set_env_param "user_overlays" "ratt"
    elif ! echo "$CURRENT_USER_OVERLAYS" | grep -qw "ratt"; then
        set_env_param "user_overlays" "${CURRENT_USER_OVERLAYS} ratt"
    fi

    # Silence console text, enable boot logo, and keep fbcon off LCD
    set_env_param "verbosity" "0"
    set_env_param "bootlogo" "true"
    set_env_param "console" "none"
    set_env_param "extraargs" "console=tty1 fbcon=map:9 vt.global_cursor_default=0"
else
    echo "  -> WARNING: Could not find /boot/orangepiEnv.txt"
fi

# 4. Display Driver Module Config (/etc/modprobe.d, /etc/modules)
echo "[4/8] Configuring display kernel drivers..."
rm -f /etc/modprobe.d/blacklist-st7789.conf

for mod in fbtft fb_st7789v; do
    if ! grep -qF "$mod" /etc/modules 2>/dev/null; then
        echo "$mod" >> /etc/modules
        echo "  + Added $mod to /etc/modules"
    fi
done

# 5. Free RFID serial port (ttyS0) and disable serial getty
echo "[5/8] Disabling serial console/getty on RFID UART (/dev/ttyS0)..."
for tty in ttyS0 serial0; do
    systemctl stop "serial-getty@${tty}.service" 2>/dev/null || true
    systemctl disable "serial-getty@${tty}.service" 2>/dev/null || true
    systemctl mask "serial-getty@${tty}.service" 2>/dev/null || true
done

systemctl set-default multi-user.target 2>/dev/null || true

# 6. Audio Mixer Configuration (/etc/asound.conf)
echo "[6/8] Configuring ALSA software mixer (/etc/asound.conf)..."
cat << 'EOF' > /etc/asound.conf
pcm.!default {
    type plug
    slave.pcm "dmixer"
}

pcm.dmixer {
    type dmix
    ipc_key 1024
    slave {
        pcm "hw:CARD=sndrpihifiberry,DEV=0"
        period_time 0
        period_size 1024
        buffer_size 4096
        rate 44100
    }
    bindings {
        0 0
        1 1
    }
}

ctl.dmixer {
    type hw
    card sndrpihifiberry
}
EOF

# 7. Application Configuration & Systemd Service
echo "[7/8] Setting up RATT config, paths, and systemd service..."

# Create /boot/firmware symlink to /boot for uniform path compatibility across Pi and Orange Pi
if [ ! -e /boot/firmware ]; then
    ln -sfn /boot /boot/firmware
    echo "  + Created symlink /boot/firmware -> /boot"
fi

RATT_CONF_DIR=/boot/firmware/ratt
mkdir -p "$RATT_CONF_DIR/certs"

if [ ! -f "$RATT_CONF_DIR/ratt.ini" ]; then
    if [ -f "${SCRIPT_DIR}/conf/ratt.ini-example" ]; then
        cp "${SCRIPT_DIR}/conf/ratt.ini-example" "$RATT_CONF_DIR/ratt.ini"
        echo "  + Initialized default $RATT_CONF_DIR/ratt.ini from example template"
    fi
fi

mkdir -p /data/ratt

# Install systemd service
cat << EOF > /etc/systemd/system/ratt.service
[Unit]
Description=RATT Access Control Application
ConditionPathExists=${RATT_CONF_DIR}/ratt.ini
After=network.target

[Service]
Environment=QT_QPA_PLATFORM=linuxfb:fb=/dev/fb1
Environment=QT_QUICK_BACKEND=software
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/usr/bin/python3 ${SCRIPT_DIR}/ratt.py --ini ${RATT_CONF_DIR}/ratt.ini
RestartSec=5
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Install ratt-hostname service
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
Description=RATT Apply Hostname from Boot Configuration
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

systemctl daemon-reload
systemctl enable ratt.service 2>/dev/null || true
systemctl enable ratt-hostname.service 2>/dev/null || true

# 8. LCD Boot Splash Configuration (/etc/splash.raw, udev rule, systemd service)
echo "[8/8] Configuring LCD boot splash screen..."
LCD_W=320
LCD_H=240
SPLASH_BYTES=$((LCD_W * LCD_H * 2))
SPLASH_SRC="${SCRIPT_DIR}/gui/images/ratt_bootscreen.png"

if [ -f "${SCRIPT_DIR}/gui/images/splash.raw" ] && [ "$(stat -c %s "${SCRIPT_DIR}/gui/images/splash.raw" 2>/dev/null)" -eq "$SPLASH_BYTES" ]; then
    cp "${SCRIPT_DIR}/gui/images/splash.raw" /etc/splash.raw
    echo "  + Installed /etc/splash.raw from pre-built image"
elif command -v ffmpeg >/dev/null 2>&1 && [ -f "$SPLASH_SRC" ]; then
    ffmpeg -loglevel error -y -i "$SPLASH_SRC" \
        -filter_complex "color=black:s=${LCD_W}x${LCD_H} [bg]; [0:v] scale=${LCD_W}:${LCD_H} [fg]; [bg][fg] overlay=shortest=1" \
        -f rawvideo -pix_fmt rgb565le /etc/splash.raw
    echo "  + Generated /etc/splash.raw using ffmpeg"
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
    echo "  + Generated /etc/splash.raw using PyQt5"
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
# Draw the RATT boot splash as soon as the fbtft LCD framebuffer registers
ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb[0-9]*", RUN+="/usr/local/sbin/show-splash.sh %k"
EOF
    chown root:root /etc/udev/rules.d/99-st7789-splash.rules
    chmod 0644 /etc/udev/rules.d/99-st7789-splash.rules

    # Install early systemd splash service as well so it triggers even if udev already settled
    cat > /etc/systemd/system/ratt-splash.service <<'EOF'
[Unit]
Description=RATT LCD Boot Splash
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service
Before=ratt.service
ConditionPathExists=/etc/splash.raw

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/show-splash.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
    systemctl daemon-reload
    systemctl enable ratt-splash.service 2>/dev/null || true

    echo "  + Installed /usr/local/sbin/show-splash.sh, udev rule, and ratt-splash.service"

    # Install U-Boot 320x240 boot.bmp
    if [ -f "${SCRIPT_DIR}/gui/images/boot.bmp" ]; then
        cp "${SCRIPT_DIR}/gui/images/boot.bmp" /boot/boot.bmp
        echo "  + Installed RATT boot logo to /boot/boot.bmp"
    fi

    # Update Plymouth Ubuntu logos with RATT logo if Plymouth is installed
    if [ -d /usr/share/plymouth ] && [ -f "${SCRIPT_DIR}/gui/images/plymouth_ratt.png" ]; then
        cp "${SCRIPT_DIR}/gui/images/plymouth_ratt.png" /usr/share/plymouth/ubuntu-logo.png
        if [ -d /usr/share/plymouth/themes/spinner ]; then
            cp "${SCRIPT_DIR}/gui/images/plymouth_ratt.png" /usr/share/plymouth/themes/spinner/watermark.png 2>/dev/null || true
            cp "${SCRIPT_DIR}/gui/images/plymouth_ratt.png" /usr/share/plymouth/themes/spinner/bgrt-fallback.png 2>/dev/null || true
        fi
        echo "  + Updated Plymouth splash logos with RATT logo"
    fi

    # Test/show immediately if framebuffer already active
    /usr/local/sbin/show-splash.sh 2>/dev/null || true
fi

if [ "$IS_RO" -eq 1 ]; then
    sync
    echo "  -> Remounting root filesystem back to read-only..."
    mount -o remount,ro /
fi

echo ""
echo "========================================================"
echo " Setup complete for Orange Pi Zero 2W!"
echo " "
echo " Summary of actions taken:"
echo "  1. Installed required Qt5, QML, gpiod, paho-mqtt, and ALSA packages."
echo "  2. Compiled and installed Device Tree Overlay (/boot/overlay-user/ratt.dtbo)."
echo "  3. Configured /boot/orangepiEnv.txt (user_overlays=ratt, console=none)."
echo "  4. Configured ST7789 display kernel drivers in /etc/modules."
echo "  5. Disabled serial console/getty on /dev/ttyS0 for RFID."
echo "  6. Configured ALSA dmix software mixer (/etc/asound.conf) for sndrpihifiberry."
echo "  7. Initialized /boot/firmware symlink, ratt.ini, and registered ratt.service."
echo "  8. Configured LCD boot splash screen (/etc/splash.raw & udev rule)."
echo ""
echo " NOTE: A reboot is required to load boot overlays and display/audio drivers!"
echo "       sudo reboot"
echo ""
echo " To start RATT service manually after reboot:"
echo "   sudo systemctl start ratt.service"
echo "========================================================"
