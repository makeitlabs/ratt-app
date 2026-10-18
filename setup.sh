#!/usr/bin/env bash
#
# RATT App Setup Script for Raspberry Pi (Debian / Raspbian Trixie & newer)
# Automates system setup for Pi Zero W2 & related hardware platforms.
#

set -euo pipefail

# Check root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run this script as root or with sudo:"
  echo "  sudo ./setup.sh"
  exit 1
fi

IS_RO=0
if ! [ -w / ]; then
  echo "  -> Root filesystem is read-only; remounting read-write for setup..."
  mount -o remount,rw /
  mount -o remount,rw /boot/firmware 2>/dev/null || mount -o remount,rw /boot 2>/dev/null || true
  IS_RO=1
fi

# The boot partition holds config.txt and the static RATT config (/boot/firmware/ratt);
# make sure it's writable even if only it (and not /) is mounted read-only.
BOOT_RO=0
BOOT_MNT=/boot/firmware
[ -d "$BOOT_MNT" ] || BOOT_MNT=/boot
if mountpoint -q "$BOOT_MNT" && ! [ -w "$BOOT_MNT" ]; then
  mount -o remount,rw "$BOOT_MNT"
  BOOT_RO=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"

# Check for Orange Pi platform and delegate
if [ -f /etc/orangepi-release ] || grep -qi "OrangePi" /proc/device-tree/model 2>/dev/null; then
    echo "========================================================"
    echo " Detected Orange Pi platform ($(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'OrangePi'))"
    echo " Delegating setup to setup-orangepi.sh..."
    echo "========================================================"
    exec "${SCRIPT_DIR}/setup-orangepi.sh" "$@"
fi

echo "========================================================"
echo " RATT Application Automated Setup"
echo " Target OS: Raspbian / Debian Trixie (or newer)"
echo " Installation Directory: ${SCRIPT_DIR}"
echo "========================================================"

# 1. Update APT and Install Dependencies
echo "[1/7] Installing system dependencies via apt..."
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
echo "[2/7] Building and installing Device Tree Overlay (ratt.dtbo)..."
DTS_FILE="${SCRIPT_DIR}/device-tree/ratt.dts"
if [ -f "$DTS_FILE" ]; then
    OVERLAY_DIR="/boot/firmware/overlays"
    if [ ! -d "$OVERLAY_DIR" ]; then
        OVERLAY_DIR="/boot/overlays"
    fi
    mkdir -p "$OVERLAY_DIR"
    dtc -@ -I dts -O dtb -o "${OVERLAY_DIR}/ratt.dtbo" "$DTS_FILE"
    echo "  -> Compiled ${DTS_FILE} to ${OVERLAY_DIR}/ratt.dtbo"
else
    echo "  -> WARNING: ${DTS_FILE} not found! Skipping overlay compilation."
fi

# Keypad is polled over I2C by the app (no kernel gpio-keys); remove any stale rule
rm -f /etc/udev/rules.d/99-gpio-keys.rules

for u in "$REAL_USER" "ratt"; do
    if [ -n "$u" ] && id "$u" >/dev/null 2>&1; then
        usermod -a -G input,video,gpio,i2c,spi "$u" 2>/dev/null || true
        echo "  -> Added $u to input, video, gpio, i2c, and spi groups"
    fi
done

# 3. Configure Raspberry Pi Boot Config (/boot/firmware/config.txt or /boot/config.txt)
echo "[3/7] Updating boot config.txt..."
CONFIG_TXT="/boot/firmware/config.txt"
if [ ! -f "$CONFIG_TXT" ]; then
    CONFIG_TXT="/boot/config.txt"
fi

if [ -f "$CONFIG_TXT" ]; then
    append_if_missing() {
        local line="$1"
        if ! grep -qF "$line" "$CONFIG_TXT"; then
            echo "$line" >> "$CONFIG_TXT"
            echo "  + Added: $line"
        fi
    }

    if ! grep -qF "# --- RATT App Hardware Configuration ---" "$CONFIG_TXT"; then
        echo "" >> "$CONFIG_TXT"
        echo "# --- RATT App Hardware Configuration ---" >> "$CONFIG_TXT"
    fi
    append_if_missing "dtparam=i2c_arm=on"
    append_if_missing "dtoverlay=ratt"
    append_if_missing "dtparam=spi=on"
    # Update older rotate=270 config to rotate=90 if already present
    sed -i -E 's/(dtoverlay=fbtft,st7789v.*rotate=)270/\190/' "$CONFIG_TXT"
    append_if_missing "dtoverlay=fbtft,st7789v,speed=32000000,dc_pin=24,reset_pin=23,cs_pin=8,rotate=90"
    append_if_missing "dtparam=i2s=on"
    append_if_missing "dtoverlay=hifiberry-dac"
    # NOTE: dtoverlay=i2s-mmap is deprecated/removed on modern kernels (built into bcm2835-i2s)
else
    echo "  -> WARNING: Could not find boot config.txt at /boot/firmware/config.txt or /boot/config.txt"
fi

# NOTE: cmdline.txt tweaks (fbcon=map:9, cursor, consoleblank) live in
# scripts/platform-setup.sh, not here. See OS_PACKAGING.md.

# 4. Display Driver Module Config (/etc/modprobe.d, /etc/modules)
echo "[4/7] Configuring display kernel drivers..."
# Removed blacklist since we need these modules to load at boot!
rm -f /etc/modprobe.d/blacklist-st7789.conf

if ! grep -qF "fb_st7789v" /etc/modules 2>/dev/null; then
    echo "fb_st7789v" >> /etc/modules
    echo "  + Added fb_st7789v to /etc/modules"
fi

# NOTE: No Plymouth here. Deployments use Raspberry Pi OS Lite (no desktop/Plymouth),
# and Plymouth draws on KMS/HDMI, not the fbtft LCD. The LCD boot splash
# (gui/images/ratt_bootscreen.png -> /dev/fb1 via udev) is a platform/image item;
# see OS_PACKAGING.md.

# 5. Free the RFID serial port and boot to console
# On boards with Bluetooth (e.g. Pi Zero 2 W) serial0 -> ttyS0 (mini UART);
# on others it may be ttyAMA0. Free all of them so nothing competes with RATT.
echo "[5/7] Disabling serial console/getty on RFID UART (serial0/ttyS0/ttyAMA0)..."
for tty in ttyS0 ttyAMA0 serial0; do
    systemctl stop "serial-getty@${tty}.service" 2>/dev/null || true
    systemctl disable "serial-getty@${tty}.service" 2>/dev/null || true
    systemctl mask "serial-getty@${tty}.service" 2>/dev/null || true
done
# Remove the kernel serial console from cmdline.txt (it also writes to / reconfigures the UART)
CMDLINE_TXT="/boot/firmware/cmdline.txt"
[ -f "$CMDLINE_TXT" ] || CMDLINE_TXT="/boot/cmdline.txt"
if [ -f "$CMDLINE_TXT" ]; then
    sed -i -E 's/[[:space:]]*console=(serial0|ttyS0|ttyAMA0)(,[0-9]+)?//g' "$CMDLINE_TXT"
    echo "  -> Removed serial console from $CMDLINE_TXT (takes effect after reboot)"
fi
# NOTE: masking getty@tty1 (console on the LCD) is done by scripts/platform-setup.sh.

systemctl set-default multi-user.target 2>/dev/null || true
# 6. Audio Mixer Configuration (/etc/asound.conf)
echo "[6/7] Configuring ALSA software mixer (/etc/asound.conf)..."
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
echo "[7/7] Setting up RATT config, data directory and systemd service..."
# STATIC per-node config is read-only, on the FAT boot partition (editable from
# any PC by mounting the SD card):
#   /boot/firmware/ratt/ratt.ini
#   /boot/firmware/ratt/certs/{ca.crt,client.crt,client.key}
# /data holds ONLY disposable, re-downloadable state (ACL + remote-config caches,
# logs, clock file). ratt-data-check may reformat it if it's corrupt.
RATT_CONF_DIR=/boot/firmware/ratt
mkdir -p "$RATT_CONF_DIR/certs"

# One-time migration from the old layout (ratt.ini + certs on /data).
# Originals are left in place; delete them once the node is verified.
if [ ! -f "$RATT_CONF_DIR/ratt.ini" ] && [ -f /data/ratt/ratt.ini ]; then
    cp /data/ratt/ratt.ini "$RATT_CONF_DIR/ratt.ini"
    sed -i 's#/data/certs/#/boot/firmware/ratt/certs/#g' "$RATT_CONF_DIR/ratt.ini"
    echo "  + Migrated /data/ratt/ratt.ini -> $RATT_CONF_DIR/ratt.ini (cert paths rewritten)"
fi
if [ -d /data/certs ]; then
    for f in /data/certs/*; do
        [ -f "$f" ] || continue
        if [ ! -e "$RATT_CONF_DIR/certs/$(basename "$f")" ]; then
            cp "$f" "$RATT_CONF_DIR/certs/"
            echo "  + Migrated $f -> $RATT_CONF_DIR/certs/"
        fi
    done
fi

if [ ! -f "$RATT_CONF_DIR/ratt.ini" ]; then
    if [ -f "${SCRIPT_DIR}/conf/ratt.ini-example" ]; then
        cp "${SCRIPT_DIR}/conf/ratt.ini-example" "$RATT_CONF_DIR/ratt.ini"
        echo "  + Initialized default $RATT_CONF_DIR/ratt.ini from example template"
    fi
fi

# On production images /data is its own partition (LABEL=data, created by
# scripts/platform-setup.sh). Warn if it isn't, so caches don't silently land on rootfs.
if ! mountpoint -q /data; then
    echo "  -> WARNING: /data is not a mounted partition; RATT caches/logs will live on the root filesystem."
    echo "     (Fine for dev boxes. For production, prepare the card with scripts/platform-setup.sh.)"
fi
mkdir -p /data/ratt

# Install systemd service
cat << EOF > /etc/systemd/system/ratt.service
[Unit]
Description=RATT Access Control Application
ConditionPathExists=${RATT_CONF_DIR}/ratt.ini
RequiresMountsFor=/data /boot/firmware
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

# Install ratt-hostname service (applies hostname from /boot/firmware/hostname.txt)
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

systemctl daemon-reload
systemctl enable ratt.service 2>/dev/null || true
systemctl enable ratt-hostname.service 2>/dev/null || true

if [ "$IS_RO" -eq 1 ]; then
    sync
    echo "  -> Remounting root filesystem back to read-only..."
    mount -o remount,ro /boot/firmware 2>/dev/null || mount -o remount,ro /boot 2>/dev/null || true
    mount -o remount,ro /
elif [ "$BOOT_RO" -eq 1 ]; then
    sync
    mount -o remount,ro "$BOOT_MNT" 2>/dev/null || true
fi

echo ""
echo "========================================================"
echo " Setup complete!"
echo " "
echo " Summary of actions taken:"
echo "  1. Installed required Qt5, QML, gpiod, paho-mqtt, and ALSA packages."
echo "  2. Compiled and installed device tree overlay (ratt.dtbo)."
echo "  3. Configured /boot/firmware/config.txt for GPIO, SPI, ST7789 display & I2S Audio."
echo "  4. Configured video kernel drivers & blacklists."
echo "  5. Disabled serial getty + kernel console on serial0/ttyS0/ttyAMA0 to free RFID serial port."
echo "  6. Installed ALSA dmix software mixer configuration (/etc/asound.conf)."
echo "  7. Initialized /boot/firmware/ratt/ratt.ini (+ certs/) and registered systemd service (ratt.service)."
echo ""
echo " NOTE: A reboot is recommended to load boot config, device tree overlays,"
echo "       and display/audio drivers!"
echo ""
echo " To start RATT service manually now:"
echo "   sudo systemctl start ratt.service"
echo ""
echo " Or run interactively:"
echo "   QT_QPA_PLATFORM=linuxfb:fb=/dev/fb1 QT_QUICK_BACKEND=software ./ratt.py"
echo "========================================================"
