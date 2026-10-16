# Packaging RATT into an OS Image

This doc is for people building a reusable Raspberry Pi OS **Lite** (Debian Trixie)
"golden" image that ships RATT. It covers things the **OS does for the app**, as opposed
to things the **app needs to install** ([`setup.sh`](setup.sh)).

---

## 1. Layering

| Layer | What | Script | Runs |
|---|---|---|---|
| **Platform** | Fixed root + 1 GB `/data` partition, fstab, `cmdline.txt`, LCD boot splash, user `ratt` + passwordless sudo, optional `authorized_keys`, no console on LCD | [`scripts/platform-setup.sh`](scripts/platform-setup.sh)<br>*(or [`scripts/pi-platform-setup.sh`](scripts/pi-platform-setup.sh))* | On a Linux **host** against unmounted card/image,<br>or **directly on the live Pi** |
| **App** | apt packages, `ratt.dtbo`, `config.txt` dtoverlays, `ratt.service`, `/boot/firmware/ratt/ratt.ini` (+ one-time migration from `/data`), ALSA dmix, user groups, freeing the RFID serial port | [`setup.sh`](setup.sh) | On the Pi |
| **Capture** | Wipe host keys, machine-id, leases, caches, history; trim image | [`scripts/sanitize-image.sh`](scripts/sanitize-image.sh) | On the host, against the unmounted card/image, right before capture |

Rule of thumb: if RATT can't start without it, it goes in `setup.sh`. If it's about how
the box boots, partitions, or gets cloned, it goes in the platform or capture layer.
`setup.sh` alone still works on a dev box with no `/data` partition (it warns, and
the caches go on the root filesystem).

## 2. Building a golden image

```bash
# 1. Host: flash Raspberry Pi OS Lite (Trixie) to a card, DON'T boot it, then:
#    (Pass --ssh-key to inject your SSH public key into ~ratt/.ssh/authorized_keys)
sudo scripts/platform-setup.sh /dev/sdX --ssh-key ~/.ssh/id_ed25519.pub
#    (or pass an .img file; ROOT_SIZE=6G DATA_SIZE=1G by default)

# 2. Pi: boot the card, SSH in as 'ratt' (passwordless sudo enabled):
ssh ratt@<pi-ip>
#    confirm `findmnt /data` shows the data partition, then:
git clone ... ratt-app && cd ratt-app && sudo ./setup.sh
#    configure /boot/firmware/ratt/ratt.ini as needed, test, then shut down cleanly

# 3. Host: card back in the reader:
sudo scripts/sanitize-image.sh /dev/sdX          # wipes keys/caches; prints exact dd command
#    (or pass an .img file: it gets truncated to the end of the last partition)
#    pass --reset-cloud-init if you want Raspberry Pi Imager user-data to re-apply per clone

# 4. Host: capture & compress for Raspberry Pi Imager:
# Capture ONLY through the end of the data partition (use the byte count from step 3):
sudo dd if=/dev/sdX of=ratt-golden.img bs=4M count=<BYTES> iflag=count_bytes status=progress

# Compress (Raspberry Pi Imager natively supports .xz, .zip, and .zst):
xz -T0 -v -9 ratt-golden.img                     # creates ratt-golden.img.xz (~1–2 GB)
#    (or: zip -9 ratt-golden.img.zip ratt-golden.img)

# Optional: generate checksum for distribution:
sha256sum ratt-golden.img.xz > ratt-golden.img.xz.sha256
```

### Flashing Clones with Raspberry Pi Imager
1. Open **Raspberry Pi Imager**.
2. **Choose Device**: Select **Raspberry Pi Zero 2 W** (or target Pi model).
3. **Choose OS**: Scroll to the very bottom, choose **Use custom**, and select `ratt-golden.img.xz`. (The Imager natively reads and decompresses `.xz` on the fly without needing manual extraction).
4. **Choose Storage**: Select your target SD card.
5. **OS Customization** (the gear icon / edit settings prompt):
   - If `--reset-cloud-init` was included during sanitization in Step 3, Imager's customization dialog can safely configure each card's unique hostname, Wi-Fi SSID/password, and user credentials on first boot.
6. Click **Write**.

> [!TIP]
> **Maximum compression:** Before running `dd` or `xz`, you can zero out deleted file space so empty blocks compress down to near zero. On the host:
> ```bash
> sudo zerofree /dev/sdX2
> sudo zerofree /dev/sdX3
> ```
> (Requires `sudo apt install zerofree`). With unallocated space already truncated and free space zeroed, the compressed image is typically under 1.5 GB.

---

## 3. Decisions

### 3.1 Data partition: fixed 1 GB, created at image-build time
| # | FS | Size | Mount |
|---|---|---|---|
| p1 | FAT32 | stock | `/boot/firmware` |
| p2 | ext4 | `ROOT_SIZE` (default 6 GB) | `/` |
| p3 | ext4, `LABEL=data` | `DATA_SIZE` (default 1 GB) | `/data` (`defaults,noatime,nofail`) |

- **Static vs disposable storage.** Anything that must never change or be lost is
  read-only. Only state that can be rebuilt goes on the writable `/data`:

  | What | Where | Mount | If lost |
  |---|---|---|---|
  | `ratt.ini` (`--ini` default) | `/boot/firmware/ratt/ratt.ini` | p1 FAT, **ro** | node unconfigured |
  | TLS CA/client cert + key | `/boot/firmware/ratt/certs/*` | p1 FAT, **ro** | can't reach MQTT/auth |
  | ACL cache, remote config cache | `/data/ratt/ratt.acl`, `ratt-remote.conf` | p3 ext4, rw | re-downloaded from auth server |
  | Logs, journal | `/data/log` (bind on `/var/log`) | p3 ext4, rw | gone (fine) |
  | Clock file | `/data/fake-hwclock.data` | p3 ext4, rw | NTP resets it |

  Defaults are in `RattConfig.py` / `RattAppEngine.py`. Because config lives on the FAT
  boot partition, a cloned card can be provisioned by putting it in **any PC (Windows
  included)** and dropping `ratt/ratt.ini` + `ratt/certs/*` onto the boot drive.
- **Permissions on FAT.** FAT has no per-file owners or modes; one `fmask`/`dmask` applies
  to the whole mount. The platform scripts add `fmask=0077,dmask=0077` to the
  `/boot/firmware` fstab entry, so only root can read it (and the client key in it).
  `ratt.service` runs as root. Firmware and kernel updates also run as root, so they're
  unaffected. Anyone with physical access to the card can still read the key. That's
  true of ext4 too.
- **Editing from Windows.** CRLF line endings are fine. `RattConfig` reads the ini as
  `utf-8-sig`, so a Notepad BOM is harmless too.
- `ratt.service` has `RequiresMountsFor=/data /boot/firmware` and
  `ConditionPathExists=/boot/firmware/ratt/ratt.ini`.
- **Root expansion is blocked by layout, not by flags.** p3 sits directly after p2, so
  whatever does first-boot expansion on Trixie (legacy `init_resize.sh`, initramfs hooks,
  or cloud-init `growpart`) has no free space to grow root into. `platform-setup.sh`
  also strips the legacy `resize` / `init_resize.sh` cmdline tokens if they're present.
  Neither of our cards had them.
- Space after p3 on bigger cards is left unused, which is intentional. 1 GB is far more than
  RATT needs.
- **Why not grow root and carve `/data` on first boot** (the original proposal, Appendix A.2):
  it resizes the mounted root unattended on every card. It's not idempotent if it fails
  halfway, and it would make provisioning order-dependent.

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
  else PyQt5. fbtft applies `rotate=90` itself, so the fb is already 320×240.
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
- In `/boot/firmware/ratt`, `ratt.ini` is **kept**. The script **warns if `certs/` isn't
  empty** (client certs/keys are usually per-node).
- On `/data`, the downloaded `ratt.acl` / `ratt-remote.conf` are cleared. It warns if a
  legacy `/data/ratt/ratt.ini` or `/data/certs` is still around.
- `--reset-cloud-init` (off by default) wipes `/var/lib/cloud`, so cloud-init re-applies
  Imager user-data (user, Wi-Fi, hostname) on every clone.

### 3.6 User `ratt`, passwordless sudo, and SSH keys
- **User `ratt` is created offline** by `platform-setup.sh` directly in the target root filesystem (`/etc/passwd`, `/etc/shadow`, `/etc/group`), along with `/home/ratt` skeleton files.
- **Passwordless sudo:** `platform-setup.sh` installs `/etc/sudoers.d/010_ratt-nopasswd`:
  ```sudoers
  ratt ALL=(ALL) NOPASSWD: ALL
  ```
  with mode `0440` and root ownership, allowing `ratt` to execute sudo commands without a password prompt.
- **Hardware groups:** `ratt` is added to `sudo`, `input`, `video`, `gpio`, `i2c`, and `spi` groups (in `platform-setup.sh` and confirmed by `setup.sh`).
- **Adding SSH keys to `~ratt/.ssh/authorized_keys`:**
  - **Option A (during `platform-setup.sh`):** Pass your public key file directly to the script on the host:
    ```bash
    sudo scripts/platform-setup.sh /dev/sdX --ssh-key ~/.ssh/id_ed25519.pub
    # or pass an existing authorized_keys file:
    sudo scripts/platform-setup.sh /dev/sdX ~/.ssh/authorized_keys
    ```
    The script creates `~ratt/.ssh/authorized_keys` with mode `0600` and `ratt:ratt` ownership, appending any non-duplicate keys.
  - **Option B (manual copy on host):** If the SD card is mounted on your workstation:
    ```bash
    mkdir -p <mount-root>/home/ratt/.ssh
    cat ~/.ssh/id_ed25519.pub >> <mount-root>/home/ratt/.ssh/authorized_keys
    chmod 700 <mount-root>/home/ratt/.ssh
    chmod 600 <mount-root>/home/ratt/.ssh/authorized_keys
    chown -R 1000:1000 <mount-root>/home/ratt/.ssh
    ```
  - **Option C (via network after first boot):**
    ```bash
    ssh-copy-id -i ~/.ssh/id_ed25519.pub ratt@<pi-ip>
    ```

### 3.7 Native Read-Only Root & Maintenance Workflow
Instead of `raspi-config`'s RAM-heavy OverlayFS (which requires two reboots to make changes and exhausts the 512 MB RAM on a Pi Zero 2 W), RATT uses **Native Read-Only Root**:

* **Filesystem mounts in `/etc/fstab`:**
  * `/` & `/boot/firmware`: Mounted **`ro`** by default.
  * `/tmp` & `/var/tmp`: Mounted on `tmpfs` (RAM).
  * `/data`: Persistent ext4 partition on `p3` (`defaults,noatime,nofail`).
  * `/var/log`: Bind-mounted to `/data/log` (`none bind,nofail`).
* **Persistent, bounded logging:**
  * `systemd-journald` flushes early-boot logs to `/var/log` (physically `/data/log`).
  * Capped at 50 MB max in `/etc/systemd/journald.conf.d/00-ratt.conf` (`SystemMaxUse=50M`), so logs never exhaust `/data`.
* **Self-Healing `/data` Auto-Recovery:**
  * `ratt-data-check.service` runs before `local-fs.target`.
  * If the `/data` partition ever suffers severe corruption, it automatically reformats it with `mkfs.ext4` and re-creates empty directories (`/data/ratt`, `/data/log`, `/data/timesync`). The node **always boots** without hanging at an emergency console. This is safe because `/data` only holds disposable state. `ratt.ini` and certs are on the read-only boot partition, and the ACL cache is re-downloaded on the next sync.
  * Caveat: until that first sync, the node has **no offline ACL**. If the auth server is unreachable right after a reformat, nobody can badge in.
* **Clock persistence:** `fake-hwclock` writes to `/data/fake-hwclock.data` instead of the read-only root.
* **Maintenance & In-Place Updates (Zero Reboots):**
  Tracked in [`scripts/`](scripts/):
  * `sudo scripts/ratt-rw` (or `sudo ratt-rw`): unlocks `/` and `/boot/firmware` to **read-write**.
  * `sudo scripts/ratt-ro` (or `sudo ratt-ro`): locks the filesystem back down to **read-only**.
  * `sudo scripts/ratt-rw <cmd>`: executes `<cmd>` in read-write mode and automatically re-locks upon exit (e.g. `sudo scripts/ratt-rw git pull`).
  * [`setup.sh`](setup.sh) automatically detects when root is read-only, remounts read-write during installation, and re-locks read-only when done.
* **Automatic Hostname Provisioning from Boot Partition:**
  * `ratt-hostname.service` runs early in boot (before network interfaces, avahi, and ssh start).
  * If `/boot/firmware/hostname.txt` (or `/boot/firmware/hostname`, or `HostName=` in `ratt.ini`) contains a hostname different from `/etc/hostname`, it temporarily unlocks root, updates `/etc/hostname` and `/etc/hosts`, invokes `hostname`, and re-locks root read-only.
  * To name or rename any node, pop the card into any PC (Windows, Mac, or Linux) and create/edit `hostname.txt` on the FAT boot drive!

---

## 4. Still open
- **Per-node certs** in `/boot/firmware/ratt/certs`: provision after flashing (from any PC), not in the image.

## 5. Gotchas
- `platform-setup.sh` refuses a card that has **already been booted**, because root has
  usually auto-expanded to fill it. Reflash and run it before the first boot.
- If `/data` isn't mounted when `setup.sh` runs, the `/data/ratt` cache dir lands on the root
  filesystem and gets hidden when the partition mounts later. That's harmless now, since
  the caches are rebuilt. `setup.sh` still warns about it.
- **Upgrading an existing node:** re-run `scripts/pi-platform-setup.sh` (adds the FAT
  masks and replaces the old `ratt-data-check`, which restored a *template* `ratt.ini`
  after a reformat). Then re-run `setup.sh`. It copies `/data/ratt/ratt.ini` and
  `/data/certs/*` to `/boot/firmware/ratt/` once, rewriting `/data/certs/` paths in the ini.
  Delete the old copies after verifying.
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
