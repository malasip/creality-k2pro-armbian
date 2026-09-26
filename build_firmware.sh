#!/bin/bash
# ==============================================================================
# Creality K2 Pro (Allwinner T113-i) - Firmware Packager
#
# Generates a flashable PhoenixSuit / OpenIXSuit A/B firmware image:
#   output/k2pro_debian_ab.img
#
# Inputs required (Approach A - Clean Room):
#   1. Creality Factory Sunxi Image (e.g. t113_i_linux_*.img)
#      Provides boot0, fes1, boot-resource, DRAM config, and PhoenixSuit container.
#   2. Creality K2 Pro OTA Update Image (e.g. CR0CN*ota_img*.img)
#      Provides K2 Pro U-Boot package (uboot -> boot_package.fex).
#   3. Armbian Base OS Image (Armbian_*.img)
#      Provides the mainline kernel, DTB, and Debian rootfs.
#
# Output:
#   A/B dual-slot image with 3.5 GB rootfs slots, 22 GB /data,
#   immutable OverlayFS and direct Micro-USB OTG ADB debugging.
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
OVERLAY_DIR="${SCRIPT_DIR}/overlay"
TOOLS_DIR="${SCRIPT_DIR}/tools"
INPUT_DIR="${SCRIPT_DIR}/input"
OUTPUT_DIR="${SCRIPT_DIR}/output"
IMAGEWTY="${TOOLS_DIR}/imagewty-tool"

FACTORY_IMG=""
OTA_IMG=""
UBOOT_BIN=""
ARMBIAN_IMG=""
CUSTOM_DTB=""
CUSTOM_KERNEL=""
FINAL_IMG="${OUTPUT_DIR}/k2pro_debian_ab.img"
KEEP_TMP=0

function print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Source Options:"
    echo "  -f, --factory <path>   Creality factory sunxi image (e.g. t113_i_linux_*.img)"
    echo "  --ota <path>           Creality K2 Pro OTA image (e.g. CR0CN*_ota_img_*.img)"
    echo "  --uboot <path>         Pre-extracted K2 Pro uboot binary (alternative to --ota)"
    echo "  -a, --armbian <path>   Built Armbian raw image (Armbian_*.img)"
    echo ""
    echo "Customization Options:"
    echo "  -d, --dtb <path>       Custom device tree blob (sun8i-t113i.dtb)"
    echo "  -k, --kernel <path>    Custom kernel zImage"
    echo "  -o, --output <path>    Output firmware path (default: output/k2pro_debian_ab.img)"
    echo "  --keep-tmp             Do not delete temporary build working directory"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example (defaults look in input/ directory):"
    echo "  $0"
    echo ""
    echo "  # Or specify explicit paths:"
    echo "  $0 --factory path/to/t113_i_linux_*.img \\"
    echo "     --ota path/to/CR0CN*.img \\"
    echo "     --armbian path/to/Armbian_k2prot113.img"
    exit 1
}

# Parse CLI options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--factory)
            FACTORY_IMG="$2"
            shift 2
            ;;
        --ota)
            OTA_IMG="$2"
            shift 2
            ;;
        --uboot)
            UBOOT_BIN="$2"
            shift 2
            ;;
        -a|--armbian)
            ARMBIAN_IMG="$2"
            shift 2
            ;;
        -d|--dtb)
            CUSTOM_DTB="$2"
            shift 2
            ;;
        -k|--kernel)
            CUSTOM_KERNEL="$2"
            shift 2
            ;;
        -o|--output)
            FINAL_IMG="$2"
            shift 2
            ;;
        --keep-tmp)
            KEEP_TMP=1
            shift
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            echo "Unknown argument: $1"
            print_usage
            ;;
    esac
done

echo "=========================================================="
echo " Creality K2 Pro - A/B Firmware Builder                   "
echo "=========================================================="

# 1. Auto-discover inputs if not specified
mkdir -p "${INPUT_DIR}"

if [[ -z "${FACTORY_IMG}" ]]; then
    for candidate in \
        "${INPUT_DIR}/"t113_i_linux_*.img \
        "${INPUT_DIR}/"*factory*.img; do
        if [[ -f "${candidate}" ]]; then
            FACTORY_IMG="${candidate}"
            echo "Auto-detected Factory Sunxi image: ${FACTORY_IMG}"
            break
        fi
    done
fi

if [[ -z "${OTA_IMG}" && -z "${UBOOT_BIN}" ]]; then
    for candidate in \
        "${INPUT_DIR}/"*ota_img*.img \
        "${INPUT_DIR}/"CR0CN*.img \
        "${INPUT_DIR}/uboot" \
        "${INPUT_DIR}/boot_package.fex"; do
        if [[ -f "${candidate}" ]]; then
            if [[ "$(basename "${candidate}")" == "uboot" || "$(basename "${candidate}")" == "boot_package.fex" ]]; then
                UBOOT_BIN="${candidate}"
                echo "Auto-detected K2 Pro U-Boot file:  ${UBOOT_BIN}"
            else
                OTA_IMG="${candidate}"
                echo "Auto-detected K2 Pro OTA image:    ${OTA_IMG}"
            fi
            break
        fi
    done
fi

if [[ -z "${ARMBIAN_IMG}" ]]; then
    for candidate in "${INPUT_DIR}/"Armbian*.img; do
        if [[ -f "${candidate}" ]]; then
            ARMBIAN_IMG="${candidate}"
            echo "Auto-detected Armbian image:       ${ARMBIAN_IMG}"
            break
        fi
    done
fi

# Validation
if [[ -z "${FACTORY_IMG}" ]]; then
    echo "ERROR: Factory sunxi image not found in ${INPUT_DIR}."
    echo "       Please place it in 'input/' or specify with -f / --factory <path>"
    exit 1
fi

if [[ -z "${OTA_IMG}" && -z "${UBOOT_BIN}" ]]; then
    echo "ERROR: K2 Pro OTA image or uboot binary not found in ${INPUT_DIR}."
    echo "       Please place it in 'input/' or specify with --ota <path> or --uboot <path>"
    exit 1
fi

if [[ -z "${ARMBIAN_IMG}" ]]; then
    echo "ERROR: Armbian base image not found in ${INPUT_DIR}."
    echo "       Please place it in 'input/' or specify with -a / --armbian <path>"
    exit 1
fi

# 2. Check dependencies
if [[ ! -x "${IMAGEWTY}" ]]; then
    echo "ERROR: imagewty-tool not found or not executable at ${IMAGEWTY}"
    exit 1
fi

for bin in debugfs e2fsck mkbootimg fdisk dd; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
        echo "ERROR: Required utility '${bin}' is not installed or not in PATH."
        exit 1
    fi
done

if [[ -n "${OTA_IMG}" && -z "${UBOOT_BIN}" ]]; then
    if ! command -v 7z >/dev/null 2>&1 && ! command -v cpio >/dev/null 2>&1; then
        echo "ERROR: 7z or cpio is required to extract U-Boot from the OTA image."
        exit 1
    fi
fi

mkdir -p "${OUTPUT_DIR}"
BUILD_TMP=$(mktemp -d -p "${SCRIPT_DIR}" build_tmp_XXXXXX)
WORK_DUMP="${BUILD_TMP}/firmware.dump"

cleanup() {
    if [[ ${KEEP_TMP} -eq 0 && -d "${BUILD_TMP}" ]]; then
        rm -rf "${BUILD_TMP}"
    fi
}
trap cleanup EXIT

# 3. Extract Factory Firmware Container
echo ""
echo "--- [1/6] Extracting Factory Sunxi Template ---"
if [[ -d "${FACTORY_IMG}" ]]; then
    echo "Using directory template: ${FACTORY_IMG}"
    cp -r "${FACTORY_IMG}" "${WORK_DUMP}"
else
    echo "Extracting ${FACTORY_IMG}..."
    # imagewty-tool extracts to <image_basename>.dump in the current working directory
    (
        cd "${BUILD_TMP}"
        "${IMAGEWTY}" extract "${FACTORY_IMG}" >/dev/null
        EXTRACTED_DUMP=$(find "${BUILD_TMP}" -maxdepth 1 -type d -name "*.dump" | head -n 1)
        if [[ -d "${EXTRACTED_DUMP}" && "${EXTRACTED_DUMP}" != "${WORK_DUMP}" ]]; then
            mv "${EXTRACTED_DUMP}" "${WORK_DUMP}"
        fi
    )
fi

if [[ ! -d "${WORK_DUMP}" ]]; then
    echo "ERROR: Failed to extract factory template."
    exit 1
fi

# 4. Extract & Inject Genuine K2 Pro U-Boot
echo ""
echo "--- [2/6] Injecting K2 Pro U-Boot from OTA ---"
if [[ -n "${UBOOT_BIN}" && -f "${UBOOT_BIN}" ]]; then
    echo "Installing uboot directly from ${UBOOT_BIN}..."
    cp -f "${UBOOT_BIN}" "${WORK_DUMP}/boot_package.fex"
elif [[ -n "${OTA_IMG}" && -f "${OTA_IMG}" ]]; then
    echo "Extracting uboot from OTA image: ${OTA_IMG}..."
    mkdir -p "${BUILD_TMP}/ota_extracted"
    if command -v 7z >/dev/null 2>&1; then
        7z e -y "${OTA_IMG}" -o"${BUILD_TMP}/ota_extracted" uboot >/dev/null
    else
        (cd "${BUILD_TMP}/ota_extracted" && cpio -idmv < "${OTA_IMG}" 2>/dev/null)
    fi

    if [[ ! -f "${BUILD_TMP}/ota_extracted/uboot" ]]; then
        echo "ERROR: Failed to extract 'uboot' from OTA package."
        exit 1
    fi
    cp -f "${BUILD_TMP}/ota_extracted/uboot" "${WORK_DUMP}/boot_package.fex"
fi
echo "Updated boot_package.fex with K2 Pro U-Boot ($(stat -c%s "${WORK_DUMP}/boot_package.fex") bytes)."

# 5. Inject Custom Partition Tables
echo ""
echo "--- [3/6] Applying 3.5 GB A/B & 22 GB Data Partition Layout ---"
for fex in sys_partition.fex dlinfo.fex sunxi_mbr.fex sunxi_gpt.fex; do
    if [[ -f "${CONFIGS_DIR}/${fex}" ]]; then
        cp -f "${CONFIGS_DIR}/${fex}" "${WORK_DUMP}/${fex}"
    fi
done

# 6. Prepare Mainline Kernel & DTB
echo ""
echo "--- [4/6] Packaging Mainline Kernel & DTB (bootA / bootB) ---"
ZIMAGE="${CUSTOM_KERNEL}"
if [[ -z "${ZIMAGE}" ]]; then
    for candidate in \
        "${INPUT_DIR}/zImage" \
        "${INPUT_DIR}/vmlinuz"*; do
        if [[ -f "${candidate}" ]]; then
            ZIMAGE="${candidate}"
            break
        fi
    done
fi

DTB="${CUSTOM_DTB}"
if [[ -z "${DTB}" ]]; then
    for candidate in \
        "${INPUT_DIR}/sun8i-creality-k2pro-t113i.dtb" \
        "${INPUT_DIR}/"*.dtb; do
        if [[ -f "${candidate}" ]]; then
            DTB="${candidate}"
            break
        fi
    done
fi

# If kernel or DTB not provided in input/, extract them directly from the Armbian image (partition 1)
if [[ -z "${ZIMAGE}" || ! -f "${ZIMAGE}" || -z "${DTB}" || ! -f "${DTB}" ]]; then
    echo "Extracting mainline kernel and DTB from ${ARMBIAN_IMG}..."
    BOOT_START=$(fdisk -l "${ARMBIAN_IMG}" | grep -E "\.img1|\.imgp1" | awk '{print $2}')
    BOOT_SECTORS=$(fdisk -l "${ARMBIAN_IMG}" | grep -E "\.img1|\.imgp1" | awk '{print $4}')
    [[ -z "${BOOT_START}" ]] && BOOT_START=8192
    [[ -z "${BOOT_SECTORS}" ]] && BOOT_SECTORS=262144

    BOOT_PART_IMG="${BUILD_TMP}/boot_partition.img"
    dd if="${ARMBIAN_IMG}" of="${BOOT_PART_IMG}" bs=512 skip="${BOOT_START}" count="${BOOT_SECTORS}" status=none
    
    mkdir -p "${BUILD_TMP}/extracted_boot"
    7z e -y "${BOOT_PART_IMG}" -o"${BUILD_TMP}/extracted_boot" zImage dtb/sun8i-creality-k2pro-t113i.dtb sun8i-creality-k2pro-t113i.dtb >/dev/null 2>&1 || true

    if [[ -z "${ZIMAGE}" && -f "${BUILD_TMP}/extracted_boot/zImage" ]]; then
        ZIMAGE="${BUILD_TMP}/extracted_boot/zImage"
    fi

    if [[ -z "${DTB}" && -f "${BUILD_TMP}/extracted_boot/sun8i-creality-k2pro-t113i.dtb" ]]; then
        DTB="${BUILD_TMP}/extracted_boot/sun8i-creality-k2pro-t113i.dtb"
    fi
fi

if [[ -z "${ZIMAGE}" || ! -f "${ZIMAGE}" ]]; then
    echo "ERROR: Kernel image (zImage) not found in ${INPUT_DIR} or inside ${ARMBIAN_IMG}."
    echo "       Please place it in 'input/' or specify with -k / --kernel <path>"
    exit 1
fi

if [[ -z "${DTB}" || ! -f "${DTB}" ]]; then
    echo "ERROR: DTB (sun8i-t113i.dtb) not found in ${INPUT_DIR} or inside ${ARMBIAN_IMG}."
    echo "       Please place it in 'input/' or specify with -d / --dtb <path>"
    exit 1
fi

echo "Kernel: ${ZIMAGE}"
echo "DTB:    ${DTB}"

ZIMAGE_DTB="${BUILD_TMP}/zImage_dtb"
cat "${ZIMAGE}" "${DTB}" > "${ZIMAGE_DTB}"

BOOT_IMG="${BUILD_TMP}/boot_mainline.img"
mkbootimg \
    --kernel "${ZIMAGE_DTB}" \
    --base 0x40000000 \
    --kernel_offset 0x05000000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "earlycon=uart8250,mmio32,0x02500000 console=ttyS0,115200 fbcon=rotate:1 root=/dev/mmcblk0p6 rw rootwait clk_ignore_unused panic=10 init=/init" \
    -o "${BOOT_IMG}"

cp -f "${BOOT_IMG}" "${WORK_DUMP}/boot.fex"
cp -f "${BOOT_IMG}" "${WORK_DUMP}/boot__2.fex"
echo "Generated boot.fex (Slot A) and boot__2.fex (Slot B)."

# 7. Extract & Customize Armbian Rootfs
echo ""
echo "--- [5/6] Customizing Debian Rootfs (OverlayFS & System Tools) ---"
ROOTFS_BASE="${BUILD_TMP}/rootfs_base.img"
echo "Extracting rootfs partition from ${ARMBIAN_IMG}..."
PART_START=$(fdisk -l "${ARMBIAN_IMG}" | grep -E "\.img2|\.imgp2" | awk '{print $2}')
PART_SECTORS=$(fdisk -l "${ARMBIAN_IMG}" | grep -E "\.img2|\.imgp2" | awk '{print $4}')
[[ -z "${PART_START}" ]] && PART_START=270336
[[ -z "${PART_SECTORS}" ]] && PART_SECTORS=3489792
dd if="${ARMBIAN_IMG}" of="${ROOTFS_BASE}" bs=512 skip="${PART_START}" count="${PART_SECTORS}" status=none

ROOTFS_FEX="${WORK_DUMP}/rootfs.fex"
cp -f "${ROOTFS_BASE}" "${ROOTFS_FEX}"

# Fix /etc/fstab
TMP_FSTAB=$(mktemp)
printf "/dev/mmcblk0p6 / ext4 defaults,noatime,errors=remount-ro 0 1\ntmpfs /tmp tmpfs defaults,nosuid 0 0\n" > "${TMP_FSTAB}"
debugfs -w -R "rm etc/fstab" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
debugfs -w -R "write ${TMP_FSTAB} etc/fstab" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
debugfs -w -R "sif etc/fstab mode 0100644" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
debugfs -w -R "sif etc/fstab uid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
debugfs -w -R "sif etc/fstab gid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
rm -f "${TMP_FSTAB}"

# Create mount points
for d in overlay_tmpfs new_root rom data usr/local/bin; do
    debugfs -w -R "mkdir ${d}" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
done

# Install early init
if [[ -f "${OVERLAY_DIR}/init" ]]; then
    debugfs -w -R "rm init" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "write ${OVERLAY_DIR}/init init" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif init mode 0100755" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif init uid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif init gid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
fi

# Install overlay-ctl
if [[ -f "${OVERLAY_DIR}/usr/local/bin/overlay-ctl" ]]; then
    debugfs -w -R "rm usr/local/bin/overlay-ctl" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "write ${OVERLAY_DIR}/usr/local/bin/overlay-ctl usr/local/bin/overlay-ctl" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/overlay-ctl mode 0100755" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/overlay-ctl uid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/overlay-ctl gid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true

    for alias in overlay-status overlay-rw overlay-ro overlay-lock overlay-unlock slot-sync; do
        debugfs -w -R "rm usr/local/bin/${alias}" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
        debugfs -w -R "symlink usr/local/bin/${alias} overlay-ctl" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    done
fi

# Mask armbian-resize-filesystem
EMPTY_FILE=$(mktemp)
debugfs -w -R "rm lib/systemd/system/armbian-resize-filesystem.service" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
debugfs -w -R "write ${EMPTY_FILE} lib/systemd/system/armbian-resize-filesystem.service" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
debugfs -w -R "sif lib/systemd/system/armbian-resize-filesystem.service mode 0100644" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
rm -f "${EMPTY_FILE}"

# Install ADB tooling
if [[ -f "${OVERLAY_DIR}/usr/local/bin/adbd" ]]; then
    debugfs -w -R "rm usr/local/bin/adbd" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "write ${OVERLAY_DIR}/usr/local/bin/adbd usr/local/bin/adbd" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/adbd mode 0100755" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/adbd uid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/adbd gid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true

    debugfs -w -R "rm usr/local/bin/adb_shell" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "write ${OVERLAY_DIR}/usr/local/bin/adb_shell usr/local/bin/adb_shell" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/adb_shell mode 0100755" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/adb_shell uid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/adb_shell gid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true

    debugfs -w -R "rm usr/bin/adb_shell" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "symlink usr/bin/adb_shell /usr/local/bin/adb_shell" "${ROOTFS_FEX}" >/dev/null 2>&1 || true

    debugfs -w -R "rm usr/local/bin/k2-setup-adb.sh" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "write ${OVERLAY_DIR}/usr/local/bin/k2-setup-adb.sh usr/local/bin/k2-setup-adb.sh" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/k2-setup-adb.sh mode 0100755" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/k2-setup-adb.sh uid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif usr/local/bin/k2-setup-adb.sh gid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true

    debugfs -w -R "rm lib/systemd/system/adbd.service" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "write ${OVERLAY_DIR}/etc/systemd/system/adbd.service lib/systemd/system/adbd.service" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif lib/systemd/system/adbd.service mode 0100644" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif lib/systemd/system/adbd.service uid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "sif lib/systemd/system/adbd.service gid 0" "${ROOTFS_FEX}" >/dev/null 2>&1 || true

    debugfs -w -R "mkdir etc/systemd/system/multi-user.target.wants" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "rm etc/systemd/system/multi-user.target.wants/adbd.service" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
    debugfs -w -R "symlink etc/systemd/system/multi-user.target.wants/adbd.service /lib/systemd/system/adbd.service" "${ROOTFS_FEX}" >/dev/null 2>&1 || true
fi

# Verify filesystem integrity
e2fsck -f -y "${ROOTFS_FEX}" >/dev/null 2>&1 || true

# Mirror to Slot B
cp -f "${ROOTFS_FEX}" "${WORK_DUMP}/rootfs__2.fex"
echo "Prepared rootfs.fex (Slot A) and rootfs__2.fex (Slot B)."

# 8. Repack Full Firmware
echo ""
echo "--- [6/6] Repacking PhoenixSuit Firmware Container ---"
"${IMAGEWTY}" repack "${WORK_DUMP}/" "${FINAL_IMG}"

IMG_SIZE=$(ls -lh "${FINAL_IMG}" | awk '{print $5}')
SHA256=$(sha256sum "${FINAL_IMG}" | awk '{print $1}')

echo ""
echo "=========================================================="
echo " BUILD SUCCESSFUL!"
echo " Image:  ${FINAL_IMG}"
echo " Size:   ${IMG_SIZE}"
echo " SHA256: ${SHA256}"
echo "=========================================================="
echo " Flash this image using OpenIXSuit or PhoenixSuit in FEL mode."
