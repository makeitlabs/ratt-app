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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"

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

    echo "" >> "$CONFIG_TXT"
    echo "# --- RATT App Hardware Configuration ---" >> "$CONFIG_TXT"
    append_if_missing "dtparam=i2c_arm=on"
    append_if_missing "dtoverlay=ratt"
    append_if_missing "dtparam=spi=on"
    append_if_missing "dtoverlay=fbtft,st7789v,speed=32000000,dc_pin=24,reset_pin=23,cs_pin=8,rotate=270"
    append_if_missing "dtparam=i2s=on"
    append_if_missing "dtoverlay=hifiberry-dac"
    append_if_missing "dtoverlay=i2s-mmap"
else
    echo "  -> WARNING: Could not find boot config.txt at /boot/firmware/config.txt or /boot/config.txt"
fi

CMDLINE_TXT="/boot/firmware/cmdline.txt"
if [ ! -f "$CMDLINE_TXT" ]; then
    CMDLINE_TXT="/boot/cmdline.txt"
fi

if [ -f "$CMDLINE_TXT" ]; then
    if ! grep -qF "vt.global_cursor_default=0" "$CMDLINE_TXT"; then
        sed -i 's/$/ vt.global_cursor_default=0/' "$CMDLINE_TXT"
        echo "  + Disabled blinking cursor in $CMDLINE_TXT"
    fi
fi

# 4. Display Driver Module Config & Boot Splash (/etc/modprobe.d, /etc/modules, Plymouth)
echo "[4/7] Configuring display kernel drivers and boot splash..."
# Removed blacklist since we need these modules to load at boot!
rm -f /etc/modprobe.d/blacklist-st7789.conf

if ! grep -qF "fb_st7789v" /etc/modules 2>/dev/null; then
    echo "fb_st7789v" >> /etc/modules
    echo "  + Added fb_st7789v to /etc/modules"
fi

BOOT_SPLASH="${SCRIPT_DIR}/gui/images/ratt_bootscreen.png"
if [ -f "$BOOT_SPLASH" ]; then
    for splash_dest in \
        /usr/share/plymouth/themes/pix/splash.png \
        /etc/alternatives/default.plymouth/splash.png \
        /usr/share/plymouth/themes/spinner/watermark.png
    do
        if [ -d "$(dirname "$splash_dest")" ]; then
            cp -f "$BOOT_SPLASH" "$splash_dest" 2>/dev/null || true
            echo "  + Installed boot splash to $splash_dest"
        fi
    done
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u 2>/dev/null || true
    fi
fi

# 5. Disable Serial Getty and Desktop GUI
echo "[5/7] Disabling serial-getty and console GUI..."
systemctl stop serial-getty@ttyAMA0.service 2>/dev/null || true
systemctl disable serial-getty@ttyAMA0.service 2>/dev/null || true
systemctl mask serial-getty@ttyAMA0.service 2>/dev/null || true

systemctl stop getty@tty1.service 2>/dev/null || true
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true

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
echo "[7/7] Setting up RATT data directory and systemd service..."
mkdir -p /data/ratt

if [ ! -f /data/ratt/ratt.ini ]; then
    if [ -f "${SCRIPT_DIR}/conf/ratt.ini-example" ]; then
        cp "${SCRIPT_DIR}/conf/ratt.ini-example" /data/ratt/ratt.ini
        echo "  + Initialized default /data/ratt/ratt.ini from example template"
    fi
fi

# Install systemd service
cat << EOF > /etc/systemd/system/ratt.service
[Unit]
Description=RATT Access Control Application
ConditionPathExists=/data/ratt/ratt.ini
After=network.target

[Service]
Environment=QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0
Environment=QT_QUICK_BACKEND=software
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/usr/bin/python3 ${SCRIPT_DIR}/ratt.py --ini /data/ratt/ratt.ini
RestartSec=5
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ratt.service 2>/dev/null || true

echo ""
echo "========================================================"
echo " Setup complete!"
echo " "
echo " Summary of actions taken:"
echo "  1. Installed required Qt5, QML, gpiod, paho-mqtt, and ALSA packages."
echo "  2. Compiled and installed device tree overlay (ratt.dtbo)."
echo "  3. Configured /boot/firmware/config.txt for GPIO, SPI, ST7789 display & I2S Audio."
echo "  4. Configured video kernel drivers & blacklists."
echo "  5. Disabled serial-getty@ttyAMA0 to free RFID serial port."
echo "  6. Installed ALSA dmix software mixer configuration (/etc/asound.conf)."
echo "  7. Initialized /data/ratt/ratt.ini and registered systemd service (ratt.service)."
echo ""
echo " NOTE: A reboot is recommended to load boot config, device tree overlays,"
echo "       and display/audio drivers!"
echo ""
echo " To start RATT service manually now:"
echo "   sudo systemctl start ratt.service"
echo ""
echo " Or run interactively:"
echo "   QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0 QT_QUICK_BACKEND=software ./ratt.py"
echo "========================================================"
