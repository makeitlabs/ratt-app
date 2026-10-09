# Packaging RATT into an OS Image

This doc is for people building a reusable Raspberry Pi OS **Lite** (Debian Trixie)
"golden" image that ships RATT. It covers things the **OS does for the app**, as opposed
to things the **app needs to install** ([`setup.sh`](setup.sh)).

---

## 1. Layering

| Layer | What | Script | Runs |
|---|---|---|---|
| **Platform** | Fixed root + 1 GB `/data` partition, fstab, `cmdline.txt`, LCD boot splash, no console on LCD | [`scripts/platform-setup.sh`](scripts/platform-setup.sh) | On a Linux **host**, against the unmounted, **never-booted** card/image |
| **App** | apt packages, `ratt.dtbo`, `config.txt` dtoverlays, `ratt.service`, `/data/ratt/ratt.ini`, ALSA dmix, user groups, freeing the RFID serial port | [`setup.sh`](setup.sh) | On the Pi |
| **Capture** | Wipe host keys, machine-id, leases, caches, history; trim image | [`scripts/sanitize-image.sh`](scripts/sanitize-image.sh) | On the host, against the unmounted card/image, right before capture |

Rule of thumb: if RATT can't start without it, it goes in `setup.sh`. If it's about how
the box boots, partitions, or gets cloned, it goes in the platform or capture layer.
`setup.sh` alone still works on a dev box with no `/data` partition (it warns, and
the data goes on the root filesystem).

## 2. Building a golden image

```bash
# 1. Host: flash Raspberry Pi OS Lite (Trixie) to a card, DON'T boot it, then:
sudo scripts/platform-setup.sh /dev/sdX          # or an .img file
#    (ROOT_SIZE=6G DATA_SIZE=1G by default; override via env)

# 2. Pi: boot the card, confirm `findmnt /data` shows the data partition, then:
git clone ... ratt-app && cd ratt-app && sudo ./setup.sh
#    configure /data/ratt/ratt.ini as needed, test, then shut down cleanly

# 3. Host: card back in the reader:
sudo scripts/sanitize-image.sh /dev/sdX          # prints the dd command to capture
#    (or pass an .img file: it gets truncated to the end of the last partition)
```

---

## 3. Decisions

### 3.1 Data partition: fixed 1 GB, created at image-build time
| # | FS | Size | Mount |
|---|---|---|---|
| p1 | FAT32 | stock | `/boot/firmware` |
| p2 | ext4 | `ROOT_SIZE` (default 6 GB) | `/` |
| p3 | ext4, `LABEL=data` | `DATA_SIZE` (default 1 GB) | `/data` (`defaults,noatime,nofail`) |

- **Everything RATT persists lives on `/data`:** `ratt.ini` (`--ini` default),
  `ratt.acl` (ACL cache), `ratt-remote.conf` (remote config cache), and `/data/certs/*`.
  Defaults are in `RattConfig.py` / `RattAppEngine.py`.
- `ratt.service` has `RequiresMountsFor=/data` and `ConditionPathExists=/data/ratt/ratt.ini`.
- **Root expansion is blocked by layout, not by flags.** p3 sits directly after p2, so
  whatever does first-boot expansion on Trixie (legacy `init_resize.sh`, initramfs hooks,
  or cloud-init `growpart`) has no free space to grow root into. `platform-setup.sh`
  also strips the legacy `resize` / `init_resize.sh` cmdline tokens if they're present.
  Neither of our cards had them.
- Space after p3 on bigger cards is left unused, which is intentional. 1 GB is far more than
  RATT needs.
- **Why not grow root and carve `/data` on first boot** (the original proposal, Appendix A.2):
  it resizes the mounted root unattended on every card. It's not idempotent if it fails
  halfway. And mounting a fresh empty p3 over `/data` would **hide the `ratt.ini` that
  `setup.sh` wrote**, so `ratt.service` would silently never start.

### 3.2 Boot splash: udev raw splash on the LCD, no Plymouth
Deployments are Lite (no desktop, no Plymouth), and Plymouth draws on KMS/HDMI, not the
fbtft LCD anyway. The Plymouth step was removed from `setup.sh`.

- `fb_st7789v` registers its framebuffer about 12 s into boot, after the initramfs. A udev
  `graphics` add rule draws `/etc/splash.raw` the moment it appears.
- The rule matches **by driver name** (`/sys/class/graphics/fbN/name` contains `st7789` or
  `fbtft`), not by `fb1`. That's `fb1` with vc4-kms (HDMI takes `fb0`) but `fb0` headless.
  It's the same detection `ratt.py` uses.
- `splash.raw` is `gui/images/ratt_bootscreen.png` scaled to 320×240, RGB565 little-endian,
  exactly **153600** bytes (the script asserts this). It uses ffmpeg if the host has it,
  else PyQt5. fbtft applies `rotate=270` itself, so the fb is already 320×240.
- The splash stays up until RATT draws. On stop, RATT leaves `ratt_exitscreen.png` up.

### 3.3 `cmdline.txt`
Kept to **one line**. Duplicate tokens removed. `fbcon=map:9` maps the framebuffer console
to a non-existent fb, so kernel/getty text never draws on the LCD.
`vt.global_cursor_default=0` and `consoleblank=0` stop cursor blink and blanking.
This moved out of `setup.sh`.

### 3.4 Console
`platform-setup.sh` masks `getty@tty1` (moved out of `setup.sh`). `setup.sh` still masks
`serial-getty@ttyAMA0`, because RFID uses that UART.

### 3.5 Capture / sanitization (`sanitize-image.sh`)
- **SSH host keys** are wiped (that's why every re-flash gave "REMOTE HOST IDENTIFICATION
  HAS CHANGED"). The script also installs `ratt-ssh-hostkeys.service`
  (`ssh-keygen -A` when keys are missing), so clones never come up without sshd, regardless
  of whether `raspberrypi-sys-mods`' regenerator is present.
- `/etc/machine-id` is emptied (not deleted); systemd regenerates it. The
  `/var/lib/dbus/machine-id` symlink is left alone.
- Leases, apt `.deb` cache, `/tmp`, `/var/tmp`, the journal, and shell history are cleared.
- On `/data`, `ratt.ini` is **kept**, and the downloaded `ratt.acl` / `ratt-remote.conf`
  are cleared. The script **warns if `/data/certs` isn't empty** (client certs/keys are
  usually per-node).
- `--reset-cloud-init` (off by default) wipes `/var/lib/cloud`, so cloud-init re-applies
  Imager user-data (user, Wi-Fi, hostname) on every clone.

---

## 4. Still open
- **Unique hostnames.** Every clone boots with the template's hostname (the script warns).
  Options: Imager settings per card, cloud-init user-data with `--reset-cloud-init`, or a
  first-boot rename (e.g. from the MAC address).
- **Per-node certs** in `/data/certs`: provision after flashing, not in the image.
- **Read-only root** (README suggests it). Separate project. `/data` being its own partition
  is the prerequisite, and that's now done.

## 5. Gotchas
- `platform-setup.sh` refuses a card that has **already been booted**, because root has
  usually auto-expanded to fill it. Reflash and run it before the first boot.
- If `/data` isn't mounted when `setup.sh` runs, `ratt.ini` lands on the root filesystem.
  When the partition later mounts over `/data`, the file is hidden and the service won't
  start. `setup.sh` warns about this.
- The hand-installed splash files on ratt-test3 (`/etc/splash.raw`, `show-splash.sh`,
  `99-st7789-splash.rules`) predate this script. Re-running `platform-setup.sh` on a
  fresh card replaces that setup.

---

## Appendix A: Original proposal from the OS-image agent (preserved verbatim)

Context given to that agent: pre-configure a mounted Raspberry Pi OS (Debian Trixie)
image before it is shrunk and captured as a golden template. ST7789 SPI LCD on `/dev/fb1`.
Env vars: `BOOT_MOUNT` (FAT32 boot), `ROOT_MOUNT` (ext4 rootfs),
`SOURCE_SPLASH=gui/images/ratt_bootscreen.png`.

### A.1 Kernel command line (`${BOOT_MOUNT}/cmdline.txt`)
- Single continuous line, no line breaks.
- Strip the `resize` token and any `init=/usr/lib/raspi-config/init_resize.sh`.
- Append `fbcon=map:9 vt.global_cursor_default=0 consoleblank=0`
  (mapping fbcon to index 9 keeps virtual console text and login gettys off the SPI display).

### A.2 Dynamic first-boot partitioning (`firstboot-ratt`)
Flashed to SD cards of unknown size. On first boot: resize rootfs live to fill the media
while reserving 4 GB at the tail, create p3 in that 4 GB, format ext4 `LABEL=data`, mount
at `/data`, persist in `/etc/fstab`, then permanently disable itself.

`${ROOT_MOUNT}/usr/local/sbin/firstboot-ratt.sh` (root:root, 0755):
```bash
#!/bin/bash
set -euo pipefail

ROOT_PART="$(findmnt -n -o SOURCE /)"
DISK_DEV="/dev/$(lsblk -no PKNAME "$ROOT_PART")"

DISK_SECTORS=$(blockdev --getsz "$DISK_DEV")
PART2_START=$(cat /sys/class/block/$(basename "$ROOT_PART")/start)

# Reserve 4GB for partition 3 (4 * 1024 * 1024 * 1024 / 512 = 8388608 sectors)
RESERVE_SECTORS=8388608
TARGET_END=$((DISK_SECTORS - RESERVE_SECTORS - 1))

# Resize root partition boundary and live ext4 filesystem
parted -s "$DISK_DEV" resizepart 2 "${TARGET_END}s"
resize2fs "$ROOT_PART"

# Create partition 3 spanning remaining sectors
parted -s -a optimal "$DISK_DEV" mkpart primary ext4 "$((TARGET_END + 1))s" 100%
partprobe "$DISK_DEV" || udevadm settle
sleep 1

# Identify partition 3 (handles mmcblk0p3 vs sda3 naming)
if [[ "$DISK_DEV" =~ [0-9]$ ]]; then
    DATA_PART="${DISK_DEV}p3"
else
    DATA_PART="${DISK_DEV}3"
fi

# Format, label, create mountpoint, and persist to fstab
mkfs.ext4 -F -L data "$DATA_PART"
mkdir -p /data
if ! grep -q 'LABEL=data' /etc/fstab; then
    echo "LABEL=data /data ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
fi
mount /data

# Disable and delete unit so it never executes again
systemctl disable firstboot-ratt.service
rm -f /etc/systemd/system/firstboot-ratt.service
exit 0
```

`${ROOT_MOUNT}/etc/systemd/system/firstboot-ratt.service` (root:root, 0644):
```ini
[Unit]
Description=First Boot Custom Partitioning and Setup
After=local-fs.target
DefaultDependencies=no
Conflicts=shutdown.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-ratt.sh
RemainAfterExit=yes

[Install]
WantedBy=basic.target
```

Enable offline:
```bash
mkdir -p "${ROOT_MOUNT}/etc/systemd/system/basic.target.wants"
ln -sf ../firstboot-ratt.service "${ROOT_MOUNT}/etc/systemd/system/basic.target.wants/firstboot-ratt.service"
```

### A.3 Splash conversion and udev trigger
`fb_st7789v` loads asynchronously about 12 s into boot. Initramfs hooks finish before
`/dev/fb1` exists, so the splash must trigger via udev when `fb1` registers.
320×240 RGB565 means exactly 153,600 bytes.

```bash
ffmpeg -y -i "${SOURCE_SPLASH}" -vcodec rawvideo -f rawvideo -pix_fmt rgb565 "${ROOT_MOUNT}/etc/splash.raw"
chmod 644 "${ROOT_MOUNT}/etc/splash.raw"; chown root:root "${ROOT_MOUNT}/etc/splash.raw"
# assert size == 153600
```

`${ROOT_MOUNT}/usr/local/sbin/show-splash.sh` (root:root, 0755):
```bash
#!/bin/sh
if [ -e /dev/fb1 ] && [ -f /etc/splash.raw ]; then
    usleep 100000 2>/dev/null || sleep 0.1
    cat /etc/splash.raw > /dev/fb1
fi
```

`${ROOT_MOUNT}/etc/udev/rules.d/99-st7789-splash.rules` (root:root, 0644):
```udev
ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb1", RUN+="/usr/local/sbin/show-splash.sh"
```

### A.4 Master image sanitization
```bash
# Wipe SSH host keys so targets generate fresh keys on boot
rm -f "${ROOT_MOUNT}/etc/ssh/ssh_host_"*key*

# Clear machine IDs to force re-initialization
truncate -s 0 "${ROOT_MOUNT}/etc/machine-id"
rm -f "${ROOT_MOUNT}/var/lib/dbus/machine-id"

# Clear network leases, package archives, temp files, and history
rm -rf "${ROOT_MOUNT}/var/lib/dhcp/"* "${ROOT_MOUNT}/var/lib/NetworkManager/"*.lease
rm -rf "${ROOT_MOUNT}/var/cache/apt/archives/"*.deb
rm -rf "${ROOT_MOUNT}/tmp/"* "${ROOT_MOUNT}/var/tmp/"*
rm -f "${ROOT_MOUNT}/root/.bash_history" "${ROOT_MOUNT}"/home/*/.bash_history
```

Deliverable requested of that agent: a unified, idempotent bash script under
`set -euo pipefail` that validates file sizes, checks symlink paths, and keeps `cmdline.txt`
on a single line.
