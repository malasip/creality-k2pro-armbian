#!/bin/bash
# Configure USB OTG Gadget for ADB FunctionFS
set -e

# Ensure /bin/adb_shell symlink exists for adbd
if [ ! -L /bin/adb_shell ] || [ ! -e /bin/adb_shell ]; then
    if [ -e /usr/local/bin/adb_shell ]; then
        ln -sf /usr/local/bin/adb_shell /bin/adb_shell 2>/dev/null || true
    fi
fi

modprobe configfs 2>/dev/null || true
modprobe libcomposite 2>/dev/null || true
modprobe usb_f_fs 2>/dev/null || true

mkdir -p /sys/kernel/config
mount -t configfs none /sys/kernel/config 2>/dev/null || true

GADGET="/sys/kernel/config/usb_gadget/g1"
if [ ! -d "$GADGET" ]; then
    mkdir -p "$GADGET"
    echo "0x18d1" > "$GADGET/idVendor"
    echo "0xd002" > "$GADGET/idProduct"
    mkdir -p "$GADGET/strings/0x409"
    echo "Creality" > "$GADGET/strings/0x409/manufacturer"
    echo "K2 Pro" > "$GADGET/strings/0x409/product"
    echo "k2pro" > "$GADGET/strings/0x409/serialnumber"

    mkdir -p "$GADGET/configs/c.1/strings/0x409"
    echo 0xc0 > "$GADGET/configs/c.1/bmAttributes"
    echo 500 > "$GADGET/configs/c.1/MaxPower"

    mkdir -p "$GADGET/functions/ffs.adb"
    ln -sf "$GADGET/functions/ffs.adb" "$GADGET/configs/c.1/ffs.adb"
fi

mkdir -p /dev/usb-ffs/adb
mount -t functionfs adb /dev/usb-ffs/adb 2>/dev/null || true

# Wait for adbd to write descriptors to /dev/usb-ffs/adb/ep0, then bind to UDC
(
    for i in $(seq 1 30); do
        sleep 0.3
        UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
        if [ -n "$UDC" ]; then
            CURRENT_UDC=$(cat "$GADGET/UDC" 2>/dev/null || true)
            if [ -z "$CURRENT_UDC" ]; then
                echo "$UDC" > "$GADGET/UDC" 2>/dev/null || true
            fi
            break
        fi
    done
) &
