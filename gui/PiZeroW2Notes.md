# Raspberry Pi Trixie on Pi Zero W2
## Build Device Tree Overlay
Configure GPIO Expander

```
dtc -@ -I dts -O dtb -o ratt.dtbo ratt.dts
```

### Add to Config
Add lines to `/boot/fimrware/config.txt`:
```
dtparam=i2c_arm=on
dtoverlay=ratt
``

### Test/Debug GPIO
```
gpiodetect
gpiochip0 [pinctrl-bcm2835] (54 lines)
gpiochip1 [1-0074] (16 lines)  <---- RATT MUX
```

# Video Config and Drivers
```
echo "blacklist fb_st7789v" | sudo tee /etc/modprobe.d/blacklist-st7789.conf
echo "blacklist fbtft" | sudo tee -a /etc/modprobe.d/blacklist-st7789.conf
```


# Overlay

Add following to `/boot/firmware/config.txt`
```
dtparam=spi=on
dtoverlay=fbtft,st7789v,speed=32000000,dc_pin=24,reset_pin=23,cs_pin=8,rotate=270
```

`modprobe fb_st7789v` to manually load video driver
to automatically load, add:

```
fb_st7789v
```
To the end of `/etc/modules`

# Serial Interface Cleanup (CRITICAL)
By default, the OS starts a login prompt (getty) on the serial port which will corrupt any RFID data. You must disable it:

```bash
# Stop and disable the service:
sudo systemctl stop serial-getty@ttyAMA0.service
sudo systemctl disable serial-getty@ttyAMA0.service
```

# Run Application
```
QT_QPA_PLATFORM=linuxfb:fb=/dev/fb1 QT_QUICK_BACKEND=software ./ratt.py
```

# Experemental Disk Stuff
```text
cd /boot/firmware/
mkdir ratt
cd ratt
dd if=/dev/zero of=ratt.acl bs=1M count=1
mount -o remount,ro /boot/firmware/
hdparm --verbose --fibmap ratt.acl 
# Use RAW FILE
dd if=/dev/mmcblk0p bs=512  skip=35033 count=1 | xxd 

## DANGER!
# echo "test" | dd of=/dev/mmcblk0  bs=512  seek=37135 count=1
```


## Note "seek" vs "skip"!



root@ratt-test:/home/bkg# vi PiZeroW2Notes.md 
root@ratt-test:/home/bkg# cat PiZeroW2Notes.md 
# Raspberry Pi Trixie on Pi Zero W2
## Build Device Tree Overlay
Configure GPIO Expander

```
dtc -@ -I dts -O dtb -o ratt.dtbo ratt.dts
```

### Add to Config
Add lines to `/boot/fimrware/config.txt`:
```
dtparam=i2c_arm=on
dtoverlay=ratt
``

### Test/Debug GPIO
```
gpiodetect
gpiochip0 [pinctrl-bcm2835] (54 lines)
gpiochip1 [1-0074] (16 lines)  <---- RATT MUX
```

# Video Config and Drivers
```
echo "blacklist fb_st7789v" | sudo tee /etc/modprobe.d/blacklist-st7789.conf
echo "blacklist fbtft" | sudo tee -a /etc/modprobe.d/blacklist-st7789.conf
```


# Overlay

Add following to `/boot/firmware/config.txt`
```
dtparam=spi=on
dtoverlay=fbtft,st7789v,speed=32000000,dc_pin=24,reset_pin=23,cs_pin=8,rotate=270
```

`modprobe fb_st7789v` to manually load video driver
to automatically load, add:

```
fb_st7789v
```
To the end of `/etc/modules`

# Serial Interface Cleanup (CRITICAL)
Note: Use `systemctl disable serial-getty@ttyAMA0.service` to prevent the OS from taking over the RFID serial port.

# Run Application
```
QT_QPA_PLATFORM=linuxfb:fb=/dev/fb1 QT_QUICK_BACKEND=software ./ratt.py
```

# Audio

Add following to `/boot/firmware/config.txt`
```
# RATT i2s audio
dtparam=i2s=on
dtoverlay=hifiberry-dac
dtoverlay=i2s-mmap
```

## Audio (ALSA & aplay)

The RATT app on Pi Zero 2W uses `aplay` directly to bypass PulseAudio/GStreamer issues.

1.  **Configure dmix (Crucial):** To allow multiple sounds (beeps + silence loop), create `/etc/asound.conf`:
    ```text
    pcm.!default { type plug; slave.pcm "dmixer" }
    pcm.dmixer {
        type dmix
        ipc_key 1024
        slave { pcm "hw:0,0"; rate 44100 }
    }
    ```
2.  **Verify Module:** Ensure `hifiberry-dac` is loaded and not blacklisted.
3.  **Test:** Run `alsamixer` to ensure levels are up and not muted.

## Troubleshooting
*   **HDMI Blinking:** This is often caused by `QtMultimedia` probing the HDMI sink. Solution: Ensure `import QtMultimedia` is removed from QML and use the `AudioPlayer` python class which uses `aplay`.
*   **Device Busy:** Occurs if `dmix` is not configured and multiple `aplay` instances try to run.

# Experemental Disk Stuff
```text
cd /boot/firmware/
mkdir ratt
cd ratt
dd if=/dev/zero of=ratt.acl bs=1M count=1
mount -o remount,ro /boot/firmware/
hdparm --verbose --fibmap ratt.acl 
# Use RAW FILE
dd if=/dev/mmcblk0p bs=512  skip=35033 count=1 | xxd 

## DANGER!
# echo "test" | dd of=/dev/mmcblk0  bs=512  seek=37135 count=1

## Note "seek" vs "skip"!
```