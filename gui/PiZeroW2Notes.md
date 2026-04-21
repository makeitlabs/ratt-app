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
``


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

## Test
Run `alsamixer` to test

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