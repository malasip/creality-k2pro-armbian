# Creality K2 Pro (Allwinner T113-i) — Armbian Firmware Packager

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Target SOC](https://img.shields.io/badge/SoC-Allwinner%20T113--i-orange.svg)](#)
[![Architecture](https://img.shields.io/badge/Arch-ARM%20Cortex--A7%20(ARMv7--A)-green.svg)](#)
[![Kernel](https://img.shields.io/badge/Kernel-Mainline%206.18-informational.svg)](#)

Firmware packager that generates flashable PhoenixSuit / OpenIXSuit A/B container images for the **Creality K2 Pro compute board** (Allwinner T113-i / sun8iw20p1, dual-core ARM Cortex-A7).

---

## Highlights

* **A/B Dual-Slot Redundancy**: Dual boot and 3.5 GB rootfs slots (`bootA`/`rootfsA` and `bootB`/`rootfsB`) for seamless failover and upgrades. Or in case you brick the system.
* **Persistent Storage**: ~22 GB `/data` partition with automatic bind-mounting of `/home`, network connection configuration, and SSH host keys.
* **OverlayFS**: Root filesystem boots read-only (`/rom`) backed by a RAM `tmpfs` upperdir to prevent flash corruption during power cuts.
* **First-Boot RW mode & Auto-Sync**: Automatically launches the system in RW mode for initial Armbian first run wizard and syncs credentials to Slot B.
* **Micro-USB ADB Access**: USB OTG ADB daemon providing an root shell without need for a serial UART adapter.
* **No Creality blobs included**: No Creality proprietary pre-extracted blobs; extracts vendor bootloader components (`boot0`, `fes1`, `u-boot`) directly from official firmware during the build.

---

## Partition Architecture

The script expands the default factory sizing into larger A/B slots, keeping ~22GB of free space usable:

| Partition | Device Node | Size | Format | Description / Mountpoint |
| :--- | :--- | :--- | :--- | :--- |
| `bootA` | `/dev/mmcblk0p5` | 32 MB | Android Bootimg | Kernel `zImage` + DTB (Slot A) |
| `rootfsA` | `/dev/mmcblk0p6` | 3.5 GB | ext4 | Armbian Debian Bookworm (Slot A) |
| `bootB` | `/dev/mmcblk0p8` | 32 MB | Android Bootimg | Standby Kernel `zImage` + DTB (Slot B) |
| `rootfsB` | `/dev/mmcblk0p7` | 3.5 GB | ext4 | Standby rootfs (Slot B) |
| `UDISK` / `data` | `/dev/mmcblk0p14` | ~22 GB | ext4 | Persistent data (`/data`, bind `/home`) |

---

## Repository Structure

```text
creality-k2pro-armbian/
├── build_firmware.sh        # Repacking and image building script
├── configs/                 # Custom A/B & data partition definitions
│   ├── dlinfo.fex
│   ├── sunxi_gpt.fex
│   ├── sunxi_mbr.fex
│   └── sys_partition.fex
├── overlay/                 # Rootfs overlay injected into firmware images
│   ├── init                 # Early init script & OverlayFS manager
│   ├── usr/local/bin/
│   │   ├── overlay-ctl      # System management CLI (status, rw/ro, sync)
│   │   ├── k2-setup-adb.sh  # USB OTG FunctionFS initialization
│   │   ├── adb_shell        # ADB interactive login wrapper
│   │   └── adbd             # Embedded ADB daemon ARM binary (AOSP / Tina Linux)
│   └── etc/systemd/system/
│       └── adbd.service     # Systemd service for USB OTG ADB
└── tools/
    └── imagewty-tool        # Allwinner PhoenixSuit image unpacker/repacker (fuxdasec/imagewty-tool)
```

---

## Prerequisites

### 1. Host Dependencies (Linux x86_64)

Install the required filesystem and packaging utilities:

```bash
sudo apt update && sudo apt install -y \
    e2fsprogs \
    android-sdk-libsparse-utils \
    u-boot-tools \
    fdisk \
    p7zip-full

# mkbootimg is required to build the kernel boot image
sudo apt install -y mkbootimg || pip install mkbootimg
```

### 2. Required Input Files

Place the following files in the `input/` directory:

1. **Creality Factory Sunxi Image** (`.img`):
   * Factory image providing container metadata, DRAM configs, FEL `boot0`, `fes1`, and boot-resource (e.g., `t113_i_linux_cr0cn240110c10_uart0_v1.1.2.6.img`).
2. **Creality K2 Pro Official OTA Firmware** (`.img`):
   * Provides genuine K2 Pro U-Boot binary (e.g., `CR0CN200400C10_R_202609111634_ota_img_V1.1.7.0.img`).
3. **Armbian Base OS Image**:
   * Build using the [Custom Armbian build repository with K2 Pro support](https://github.com/malasip/build/tree/creality-k2pro-t113i):
     ```bash
     ./compile.sh build BOARD=creality-k2pro-t113i BRANCH=current BUILD_MINIMAL=yes BUILD_OPT=image RELEASE=bookworm
     ```

---

## Building the Firmware

### Quick Build

With input files placed in `input/`, run:

```bash
./build_firmware.sh
```

### Build Options

You can specify custom file paths and configurations using CLI flags:

| Flag | Parameter | Description |
| :--- | :--- | :--- |
| `-f`, `--factory` | `<path>` | Path to Creality factory sunxi image |
| `--ota` | `<path>` | Path to Creality K2 Pro OTA image |
| `--uboot` | `<path>` | Path to extracted K2 Pro u-boot binary |
| `-a`, `--armbian` | `<path>` | Path to compiled Armbian raw image |
| `-d`, `--dtb` | `<path>` | Custom device tree blob (`.dtb`) |
| `-k`, `--kernel` | `<path>` | Custom kernel `zImage` |
| `-o`, `--output` | `<path>` | Custom output image path |
| `--keep-tmp` | | Keep temporary build directory for debugging |

The build process outputs the repacked image to:
```text
output/k2pro_debian_ab.img
```

---

## Flashing the Printer

1. Power off the Creality K2 Pro.
2. Connect a Micro-USB cable from your PC to the compute board Micro-USB OTG port.
3. Put the board into **FEL mode**:
   * Hold the onboard **FEL / Recovery** button.
   * Press and release the **Reset** button (or power on the board).
   * Release the FEL button after 2 seconds.
4. Flash using **[PhoenixSuit](https://linux-sunxi.org/PhoenixSuit)** or **[OpenIXSuit](https://github.com/fuxdasec/OpenIXSuit)**:
   * Select `output/k2pro_debian_ab.img` and choose full upgrade/flash.

---

## System Management (`overlay-ctl`)

On the running printer, manage filesystem protection and A/B slots using `overlay-ctl`:

### Check Filesystem & Slot Status

```bash
overlay-ctl status
# or alias: overlay-status
```
Displays active slot (A or B), OverlayFS protection status (read-only/read-write), and partition usage.

### Maintenance Mode (Software Updates)

To make persistent changes to the root filesystem (e.g., `apt update && apt install ...`):

```bash
# Switch to direct Read-Write mode
overlay-ctl rw
sudo reboot

# After updates are completed, re-lock back to protected mode
overlay-ctl ro
sudo reboot
```

### Synchronize Slots (A ↔ B)

To mirror the active slot to the standby slot:

```bash
overlay-ctl sync
# or alias: slot-sync
```

---

## Micro-USB OTG ADB Shell

Connect the compute board to your PC via Micro-USB to open a direct root shell:

```bash
# Verify connection
adb devices

# Open interactive root shell
adb shell
```

---

## Upstream & Related Projects

This project relies on and integrates work from the following open-source tools and communities:

* **[imagewty-tool](https://github.com/fuxdasec/imagewty-tool)**: Open-source Allwinner firmware image (`.img`) unpacker and repacker by [@fuxdasec](https://github.com/fuxdasec).
* **[adbd](https://android.googlesource.com/platform/packages/modules/adb/)**: Android Debug Bridge daemon (embedded Linux ARM build with FunctionFS gadget support) for direct root shell access over USB OTG.
* **[OpenIXSuit](https://github.com/fuxdasec/OpenIXSuit)** / **[PhoenixSuit](https://linux-sunxi.org/PhoenixSuit)**: Cross-platform utilities for flashing Allwinner FEL mode firmware containers.
* **[Armbian](https://www.armbian.com/)** ([armbian/build](https://github.com/armbian/build)): Lightweight Debian Bookworm base system and mainline Linux kernel builder for ARM devices.
* **[linux-sunxi](https://linux-sunxi.org/)**: Community documentation, hardware reverse engineering, and bootloader resources for Allwinner processors.

---

## License & Third-Party Notice

* The packaging scripts, overlays, configurations, and documentation in this repository are licensed under the [GNU General Public License v3.0 (GPL-3.0)](LICENSE).
* **Third-Party Notice**: Allwinner and Creality proprietary bootloader binaries (`boot0`, `fes1`, `u-boot`), DRAM parameters, and firmware containers remain the intellectual property of their respective copyright holders.
