# Creality K2 Pro (Allwinner T113-i) - Armbian Firmware Packager

Firmware packer that creates flashable PhoenixSuit / OpenIXSuit A/B images for the **Creality K2 Pro compute board** (Allwinner T113-i / `sun8iw20p1`, dual-core ARM Cortex-A7).

---

* **A/B Boot and RootFS partitions**:
  * Slot A: `bootA` (`mmcblk0p5`, 32 MB) + `rootfsA` (`mmcblk0p6`, 3.5 GB)
  * Slot B: `bootB` (`mmcblk0p8`, 32 MB) + `rootfsB` (`mmcblk0p7`, 3.5 GB)
* **Persistent Storage**:
  * UDISK partition (`mmcblk0p14`, ext4) mounted persistently at `/data`.
  * `/home` automatically bind-mounted to `/data/home` so all user files and configurations persist across updates.
* **Immutable OverlayFS**:
  * Root filesystem is mounted read-only (`/rom`) with a RAM-based `tmpfs` upperdir.
  * Protects against filesystem corruption during sudden power losses, same as factory firmware.
* **Automatic First-Run & Slot B Sync**:
  * First boot: Guides user through Armbian root password and account setup, Wi-Fi configuration, and timezone/locale generation.
  * Second boot: Automatically copies credentials and settings to Slot B (`/dev/mmcblk0p7`).
* **Direct ADB Debugging over Micro-USB OTG**:
  * Configfs FunctionFS gadget (`0x18d1:0xd002`) starts `adbd` on boot.
  * Instant root shell access via `adb shell` without needing a USB-to-UART serial cable.
* **Mainline Linux Kernel Support**:
  * Currently tested with 6.18
* **No precompiled Creality blobs**:
  * All bootloaders (`boot0`, `fes1`, and genuine K2 Pro `u-boot`) are extracted on-the-fly from official Creality firmware and OTA packages during the build.

---

## 📦 Repository Structure

```text
creality-k2pro-armbian/
├── build_firmware.sh        # Main packaging script (automated extract/inject/repack)
├── configs/                 # Custom 3.5 GB A/B & 22 GB data partition tables
│   ├── dlinfo.fex
│   ├── sunxi_gpt.fex
│   ├── sunxi_mbr.fex
│   └── sys_partition.fex
├── overlay/                 # Rootfs overlay files
│   ├── init                 # Early init OverlayFS manager
│   ├── usr/local/bin/
│   │   ├── overlay-ctl      # Unified system management tool
│   │   ├── k2-setup-adb.sh  # Micro-USB OTG gadget initialization
│   │   ├── adb_shell        # ADB login launcher
│   │   └── adbd             # ADB daemon binary (ARM)
│   └── etc/systemd/system/
│       └── adbd.service     # Systemd service for Micro-USB ADB
└── tools/
    └── imagewty-tool        # Open-source Allwinner container unpacker/repacker
```

---

## 🚀 Prerequisites

### 1. Host Dependencies (Linux x86_64)
Ensure the following tools are installed on your host system:
```bash
sudo apt update && sudo apt install -y e2fsprogs android-sdk-libsparse-utils u-boot-tools fdisk p7zip-full
# mkbootimg is required:
sudo apt install -y mkbootimg || pip install mkbootimg
```

### 2. Required Input Files
You will need:
1. **Creality Factory Sunxi Image** (`.img`):
   * Provides the PhoenixSuit container, FEL boot0, fes1, and boot-resource (e.g. `t113_i_linux_cr0cn240110c10_uart0_v1.1.2.6.img`).
2. **Creality K2 Pro Official OTA Firmware Package** (`.img`):
   * Contains the genuine, fully compatible K2 Pro U-Boot package (e.g. `CR0CN200400C10_R_202609111634_ota_img_V1.1.7.0.img`).
3. **Armbian Base Image for K2 Pro**:
   * Build using the [Armbian build repository with K2 Pro support](https://github.com/malasip/build):
     ```bash
     ./compile.sh build BOARD=k2prot113 BRANCH=current BUILD_MINIMAL=yes BUILD_OPT=image RELEASE=bookworm
     ```

---

## 🛠️ Building the Flashable Firmware

Place your input files in the `input/` directory:
* Factory sunxi image (e.g. `t113_i_linux_*.img`)
* Official K2 Pro OTA image (e.g. `CR0CN*.img` or extracted `uboot`)
* Built Armbian image (e.g. `Armbian_*.img`)
* Mainline kernel (`zImage`) and device tree (`sun8i-t113i.dtb`)

Then simply run:
```bash
./build_firmware.sh
```

*(You can also explicitly pass custom file paths using `--factory`, `--ota`, `--armbian`, `--kernel`, and `--dtb` flags).*

The script will automatically:
1. Unpack boot0 and container structure from the factory Sunxi image.
2. Extract the genuine K2 Pro `uboot` from the OTA archive and inject it into `boot_package.fex`.
3. Apply the custom 3.5 GB A/B partition tables.
4. Package the mainline kernel and DTB into `boot.fex` and `boot__2.fex`.
5. Extract rootfs from Armbian, inject `/init`, `overlay-ctl`, and `adbd`.
6. Mirror to Slot B (`rootfs__2.fex`).
7. Repack the final PhoenixSuit container into:
   ```text
   output/k2pro_debian_ab.img
   ```

---

## ⚡ Flashing the Printer

1. Power off the Creality K2 Pro.
2. Connect a Micro-USB cable from your computer to the printer's compute board Micro-USB OTG port.
3. Put the board into **FEL mode** (hold the FEL/recovery button and press the onboard reset button).
4. Flash using **OpenIXSuit** or **PhoenixSuit**:
   ```bash
   # Select output/k2pro_debian_ab.img and choose "Allwinner IMG Flash option".
   ```

---

## 🔧 Managing the System (`overlay-ctl`)

On the running printer, manage storage and slots using the unified `overlay-ctl` command:

### Check Status
```bash
overlay-ctl status
# or alias: overlay-status
```
Displays active slot (A or B), OverlayFS status (locked/unlocked), and persistent storage usage.

### Install Packages / Maintenance Mode
To make permanent changes to the system rootfs (e.g. `apt update && apt install ...`):
```bash
overlay-ctl rw
sudo reboot
```
The root filesystem will mount read-write on the next boot. After updating:
```bash
overlay-ctl ro
sudo reboot
```
The system will return to protected read-only OverlayFS mode.

### Synchronize Slots (A ↔ B)
Clone your active slot to the alternate slot:
```bash
overlay-ctl sync
# or alias: slot-sync
```

---

## 📱 Micro-USB OTG ADB Shell

Connect the compute board to your computer with a Micro-USB cable:
```bash
adb devices
# List of devices attached
# 0123456789ABCDEF    device

adb shell
# Drops directly into an interactive root bash prompt!
```

---

## 📜 License

* The scripts, configurations, and documentation in this repository are licensed under the **GNU General Public License v3.0 (GPL-3.0)**.
* **Third-Party Notice**: Allwinner and Creality proprietary bootloader binaries (`boot0`, `fes1`, `u-boot`), DRAM parameters, and firmware blobs remain the intellectual property of their respective copyright holders.
