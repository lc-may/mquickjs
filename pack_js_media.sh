#!/bin/bash
# Pack JavaScript test files into LittleFS media partition image
# Usage: ./pack_js_media.sh [DIR...] [--flash COMX]
#
# This script:
# 1. Copies JS files from one or more source directories (default: tests/)
# 2. Generates a LittleFS filesystem image (media_lfs.bin in this directory)
# 3. Optionally flashes it to the media partition
#
# Requirements:
# - Bouffalo SDK with mklfs tool
# - For flashing: BLFlashCommand tool and UART connection

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SDK_BASE=$(cd "${SCRIPT_DIR}/../.." && pwd)
MKLFS="${SDK_BASE}/tools/genlfs/mklfs-ubuntu"

# Media partition config (from partition_cfg_8M.toml for BL616)
MEDIA_ADDR=0x610000
MEDIA_SIZE=$((0x180000))  # 1.5MB = 1572864 bytes

# LittleFS parameters (matching SDK defaults)
BLOCK_SIZE=4096
READ_SIZE=256
PROG_SIZE=256

# Paths
FLASH_TOOL="${SDK_BASE}/tools/bflb_tools/bouffalo_flash_cube/BLFlashCommand-ubuntu"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Process arguments
FLASH_COMX=""
SOURCE_DIRS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --flash)
            FLASH_COMX="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [DIR...] [OPTIONS]"
            echo ""
            echo "Arguments:"
            echo "  DIR             Source directory name(s) to pack (relative to this script)."
            echo "                  Defaults to 'tests' if none specified."
            echo "                  Multiple directories can be specified and are merged."
            echo ""
            echo "Options:"
            echo "  --flash COMX    Flash to device via UART port COMX"
            echo "  -h, --help      Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                           # Pack tests/ (default)"
            echo "  $0 tests2                    # Pack tests2/ only"
            echo "  $0 tests tests2              # Pack both tests/ and tests2/"
            echo "  $0 tests2 --flash /dev/ttyUSB0  # Pack tests2/ and flash"
            echo ""
            echo "Output: media_lfs.bin (in same directory as this script)"
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            ;;
        *)
            SOURCE_DIRS+=("$1")
            shift
            ;;
    esac
done

# Default to tests/ if no directories specified
if [ ${#SOURCE_DIRS[@]} -eq 0 ]; then
    SOURCE_DIRS=("tests")
fi

# Check mklfs tool
if [ ! -x "$MKLFS" ]; then
    # Try to find any mklfs variant
    for variant in mklfs-ubuntu mklfs-macos mklfs.exe; do
        if [ -x "${SDK_BASE}/tools/genlfs/$variant" ]; then
            MKLFS="${SDK_BASE}/tools/genlfs/$variant"
            break
        fi
    done
    if [ ! -x "$MKLFS" ]; then
        error "mklfs tool not found. Please compile it first:\n  gcc -std=c99 components/fs/littlefs/littlefs/lfs.c components/fs/littlefs/littlefs/lfs_util.c tools/genlfs/mklfs.c -Icomponents/fs/littlefs/littlefs -o tools/genlfs/mklfs-ubuntu"
    fi
fi
info "Using mklfs: $MKLFS"

# Create temporary pack directory
# mklfs expects a directory; files in "lfs/file.js" become "/file.js" in LittleFS
PACK_DIR_NAME="lfs"
rm -rf "${SCRIPT_DIR}/${PACK_DIR_NAME}"
mkdir -p "${SCRIPT_DIR}/${PACK_DIR_NAME}"

# Output image placed directly in the mquickjs directory
OUTPUT_IMAGE="${SCRIPT_DIR}/media_lfs.bin"

# Copy JS files from each specified source directory
for dir in "${SOURCE_DIRS[@]}"; do
    SRC="${SCRIPT_DIR}/${dir}"
    if [ ! -d "$SRC" ]; then
        error "Directory not found: $SRC"
    fi
    JS_FILES=$(ls "${SRC}/"*.js 2>/dev/null || true)
    if [ -z "$JS_FILES" ]; then
        warn "No JS files in ${dir}/, skipping"
        continue
    fi
    cp "${SRC}/"*.js "${SCRIPT_DIR}/${PACK_DIR_NAME}/"
    info "Packed from ${dir}/"
done

# Count and list packed files
FILE_COUNT=$(ls -1 "${SCRIPT_DIR}/${PACK_DIR_NAME}/"*.js 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
    rm -rf "${SCRIPT_DIR}/${PACK_DIR_NAME}"
    error "No JS files were packed. Aborting."
fi
info "Total $FILE_COUNT JS files to pack:"
for f in "${SCRIPT_DIR}/${PACK_DIR_NAME}/"*.js; do
    echo "  - $(basename "$f")"
done

# Generate LittleFS image
info "Generating LittleFS image..."
echo "  Block size: $BLOCK_SIZE bytes"
echo "  Read size:  $READ_SIZE bytes"
echo "  Prog size:  $PROG_SIZE bytes"
echo "  FS size:    $MEDIA_SIZE bytes ($(($MEDIA_SIZE / 1024)) KB)"
echo "  Output:     $OUTPUT_IMAGE"

# mklfs must run from the parent of the pack dir so paths resolve correctly
cd "${SCRIPT_DIR}"

"$MKLFS" -c "$PACK_DIR_NAME" \
    -b $BLOCK_SIZE \
    -r $READ_SIZE \
    -p $PROG_SIZE \
    -s $MEDIA_SIZE \
    -i "$OUTPUT_IMAGE"

if [ $? -ne 0 ]; then
    error "Failed to generate LittleFS image"
fi

IMAGE_SIZE=$(stat -c%s "$OUTPUT_IMAGE" 2>/dev/null || stat -f%z "$OUTPUT_IMAGE" 2>/dev/null)
info "LittleFS image generated: $OUTPUT_IMAGE"
info "Image size: $IMAGE_SIZE bytes ($(($IMAGE_SIZE / 1024)) KB)"

# Flash to media partition if requested
if [ -n "$FLASH_COMX" ]; then
    info ""
    info "Flashing to media partition..."
    echo "  Port:    $FLASH_COMX"
    echo "  Address: $MEDIA_ADDR"
    echo "  Chip:    BL616"

    # Check flash tool
    if [ ! -x "$FLASH_TOOL" ]; then
        for variant in BLFlashCommand-ubuntu BLFlashCommand-macos BLFlashCommand.exe BLFlashCommand-arm; do
            if [ -x "${SDK_BASE}/tools/bflb_tools/bouffalo_flash_cube/$variant" ]; then
                FLASH_TOOL="${SDK_BASE}/tools/bflb_tools/bouffalo_flash_cube/$variant"
                break
            fi
        done
        if [ ! -x "$FLASH_TOOL" ]; then
            error "Flash tool not found: $FLASH_TOOL"
        fi
    fi

    # Use /tmp for the temporary flash config to avoid build/ dependency
    FLASH_CFG="/tmp/flash_media_cfg_$$.ini"
    cat > "$FLASH_CFG" << EOF
[cfg]
# 0: no erase, 1:programmed section erase, 2: chip erase
erase = 1
# skip mode set first para is skip addr, second para is skip len
skip_mode = 0x0, 0x0
# 0: not use isp mode, 1: isp mode
boot2_isp_mode = 0

[media]
filedir = ${OUTPUT_IMAGE}
address = ${MEDIA_ADDR}
EOF

    info "Flash config: $FLASH_CFG"

    "$FLASH_TOOL" --interface=uart --baudrate=2000000 \
        --port="$FLASH_COMX" --chipname=bl616 \
        --config="$FLASH_CFG"

    if [ $? -eq 0 ]; then
        info "Flash complete!"
    else
        rm -f "$FLASH_CFG"
        error "Flash failed"
    fi

    rm -f "$FLASH_CFG"
fi

# Cleanup temporary pack directory
rm -rf "${SCRIPT_DIR}/${PACK_DIR_NAME}"

info ""
info "============================================"
info "Done!"
info "============================================"
if [ -z "$FLASH_COMX" ]; then
    info "Image created: $OUTPUT_IMAGE"
    info "To flash to device:"
    echo "  $0 ${SOURCE_DIRS[*]} --flash /dev/ttyUSB0"
    info ""
    info "On device, run JS files with:"
    echo "  js_run /lfs/run_es5.js"
fi
