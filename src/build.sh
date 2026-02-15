#!/bin/bash
# xdv-os build pipeline:
# - validates one compileable integration entry per required subsystem
# - builds a bare-metal kernel binary from a composed source bundle:
#   xdv-runtime/src/runtime_bridge.ds + xdv-kernel/sector/xdv_kernel/src/kernel.ds
# - assembles MBR boot sector and packs xdv-os.img

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$OS_ROOT/.." && pwd)"
KERNEL_SRC="$REPO_ROOT/xdv-kernel/sector/xdv_kernel/src/kernel.ds"
RUNTIME_BRIDGE_SRC="$REPO_ROOT/xdv-runtime/src/runtime_bridge.ds"
KERNEL_COMBINED_SRC="$SCRIPT_DIR/target/kernel_runtime_bundle.ds"

echo "=== XDV OS Build (Dust compiler + DPL) ==="
echo "  OS root: $OS_ROOT"
echo "  Repo root: $REPO_ROOT"
echo

# 1) Resolve dust compiler
DUST_CMD=""
if [ -x "$REPO_ROOT/dust/target/release/dust" ]; then
    DUST_CMD="$REPO_ROOT/dust/target/release/dust"
elif [ -x "$REPO_ROOT/dust/target/debug/dust" ]; then
    DUST_CMD="$REPO_ROOT/dust/target/debug/dust"
elif command -v dust >/dev/null 2>&1; then
    DUST_CMD="$(command -v dust)"
fi

if [ -z "$DUST_CMD" ]; then
    echo "Building dust compiler..."
    (cd "$REPO_ROOT/dust" && cargo build --release >/dev/null 2>&1 || cargo build >/dev/null 2>&1)
    if [ -x "$REPO_ROOT/dust/target/release/dust" ]; then
        DUST_CMD="$REPO_ROOT/dust/target/release/dust"
    elif [ -x "$REPO_ROOT/dust/target/debug/dust" ]; then
        DUST_CMD="$REPO_ROOT/dust/target/debug/dust"
    fi
fi

if [ -z "$DUST_CMD" ] || [ ! -x "$DUST_CMD" ]; then
    echo "ERROR: dust compiler not found. Build from $REPO_ROOT/dust with: cargo build"
    exit 1
fi

echo "[1/4] Validating required subsystem entrypoints..."
CHECK_TARGETS=(
    "$REPO_ROOT/xdv-boot/src/boot_stage1.ds"
    "$KERNEL_SRC"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_mount.ds"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_storage_device.ds"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_partition.ds"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_format.ds"
    "$RUNTIME_BRIDGE_SRC"
    "$REPO_ROOT/xdv-shell/src/shell_bridge.ds"
    "$REPO_ROOT/xdv-edx/src/edx_bridge.ds"
    "$REPO_ROOT/dustlib/sector/dustlib_core/src/xdv_os_bridge.ds"
    "$REPO_ROOT/dustlib_k/sector/dustlib_k/lib.ds"
    "$REPO_ROOT/dust_runtime/src/runtime_bridge.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_console_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_init_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_io_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_memory_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_process_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_scheduler_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_string_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_runtime_admin.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_sysmon_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_service_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_log_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_storage_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_security_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_recovery_app.ds"
    "$REPO_ROOT/xdv-core/src/xdv_core_cli.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_partition.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_mkfs.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_fsck.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_probe.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_dir.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_file.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_mount.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_space.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_perm.ds"
    "$REPO_ROOT/xdv-xdvfs-utils/src/xdvfs_utils_cli.ds"
)

for file in "${CHECK_TARGETS[@]}"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: missing required file: $file"
        exit 1
    fi
    echo "  - $(realpath --relative-to="$REPO_ROOT" "$file" 2>/dev/null || echo "$file")"
    "$DUST_CMD" check "$file" >/dev/null
done

echo "[2/4] Compiling kernel from DPL (kernel + runtime bridge)..."
cd "$SCRIPT_DIR"
mkdir -p "$SCRIPT_DIR/target"
cat "$RUNTIME_BRIDGE_SRC" "$KERNEL_SRC" > "$KERNEL_COMBINED_SRC"
"$DUST_CMD" obj "$KERNEL_COMBINED_SRC" --bare-metal -o kernel.bin

echo "[3/4] Assembling boot sector (NASM)..."
if ! command -v nasm >/dev/null 2>&1; then
    echo "ERROR: NASM required. Install with: sudo apt install nasm"
    exit 1
fi
nasm -f bin boot_sector.asm -o boot_sector.bin

echo "[4/4] Creating disk image..."
dd if=/dev/zero of=xdv-os.img bs=1M count=1 status=none
dd if=boot_sector.bin of=xdv-os.img conv=notrunc status=none
dd if=kernel.bin of=xdv-os.img bs=512 seek=2 conv=notrunc status=none
printf '\x80' | dd of=xdv-os.img bs=1 seek=446 count=1 conv=notrunc status=none
printf '\x83' | dd of=xdv-os.img bs=1 seek=450 count=1 conv=notrunc status=none

echo
echo "=== Build complete ==="
echo "  Output: $SCRIPT_DIR/xdv-os.img"
echo "  Run in VirtualBox: Other/64-bit, 64MB RAM, attach xdv-os.img as disk."
echo
