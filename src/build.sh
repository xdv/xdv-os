#!/bin/bash
# xdv-os build pipeline:
# - cleans prior generated xdv-os artifacts
# - validates one compileable integration entry per required subsystem
# - builds a bare-metal kernel binary from a composed source bundle:
#   xdv-os/src/xdv_os_boot_contract.ds
#   + xdv-boot/src/boot_loader_profile.ds
#   + xdv-runtime/src/runtime_bridge.ds
#   + xdv-kernel/sector/xdv_kernel/src/kernel.ds
# - assembles MBR boot sector
# - generates partitioned 64MB images:
#     xdv-os-mbr-64m.img (MBR)
#     xdv-os-uefi-64m.img (GPT/ESP + xdvfs)
#   and xdv-os.img as alias to the MBR artifact

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$OS_ROOT/.." && pwd)"
OS_BOOT_CONTRACT_SRC="$SCRIPT_DIR/xdv_os_boot_contract.ds"
BOOT_PROFILE_SRC="$REPO_ROOT/xdv-boot/src/boot_loader_profile.ds"
KERNEL_SRC="$REPO_ROOT/xdv-kernel/sector/xdv_kernel/src/kernel.ds"
RUNTIME_BRIDGE_SRC="$REPO_ROOT/xdv-runtime/src/runtime_bridge.ds"
KERNEL_COMBINED_SRC="$SCRIPT_DIR/target/xdv_os_kernel_bundle.ds"

echo "=== XDV OS Build (Dust compiler + DPL) ==="
echo "  OS root: $OS_ROOT"
echo "  Repo root: $REPO_ROOT"
echo

echo "[0/4] Cleaning previous xdv-os artifacts..."
CLEAN_SCRIPT="$OS_ROOT/scripts/clean_xdv_os.ps1"
if [ ! -f "$CLEAN_SCRIPT" ]; then
    echo "ERROR: cleanup script missing: $CLEAN_SCRIPT"
    exit 1
fi
if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File "$CLEAN_SCRIPT" -Apply
elif command -v powershell >/dev/null 2>&1; then
    powershell -NoProfile -ExecutionPolicy Bypass -File "$CLEAN_SCRIPT" -Apply
else
    echo "ERROR: clean_xdv_os.ps1 requires pwsh or powershell in PATH"
    exit 1
fi

if [ -f "$REPO_ROOT/dust/Cargo.toml" ]; then
    echo "[dust] Refreshing compiler..."
    (cd "$REPO_ROOT/dust" && cargo build --release >/dev/null 2>&1 || cargo build >/dev/null 2>&1)
fi

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
    "$OS_BOOT_CONTRACT_SRC"
    "$BOOT_PROFILE_SRC"
    "$REPO_ROOT/xdv-boot/src/boot_mbr.ds"
    "$REPO_ROOT/xdv-boot/src/boot_uefi.ds"
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

echo "[2/4] Compiling Dust boot chain bundle..."
cd "$SCRIPT_DIR"
mkdir -p "$SCRIPT_DIR/target"
cat \
    "$OS_BOOT_CONTRACT_SRC" \
    "$BOOT_PROFILE_SRC" \
    "$RUNTIME_BRIDGE_SRC" \
    "$KERNEL_SRC" > "$KERNEL_COMBINED_SRC"
"$DUST_CMD" obj "$KERNEL_COMBINED_SRC" --bare-metal -o kernel.bin

echo "[3/4] Assembling boot sector (NASM)..."
if ! command -v nasm >/dev/null 2>&1; then
    echo "ERROR: NASM required. Install with: sudo apt install nasm"
    exit 1
fi
nasm -f bin boot_sector.asm -o boot_sector.bin

echo "[4/4] Creating 64MB partitioned images..."
if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File build_images.ps1 \
        -BootSectorPath "boot_sector.bin" \
        -KernelPath "kernel.bin" \
        -RepoRoot "$REPO_ROOT" \
        -OutputDir "$SCRIPT_DIR" \
        -ImageSizeMB 64
elif command -v powershell >/dev/null 2>&1; then
    powershell -NoProfile -ExecutionPolicy Bypass -File build_images.ps1 \
        -BootSectorPath "boot_sector.bin" \
        -KernelPath "kernel.bin" \
        -RepoRoot "$REPO_ROOT" \
        -OutputDir "$SCRIPT_DIR" \
        -ImageSizeMB 64
else
    echo "ERROR: build_images.ps1 requires pwsh or powershell in PATH"
    exit 1
fi

echo
echo "=== Build complete ==="
echo "  Output (MBR):  $SCRIPT_DIR/xdv-os-mbr-64m.img"
echo "  Output (UEFI): $SCRIPT_DIR/xdv-os-uefi-64m.img"
echo "  Alias:         $SCRIPT_DIR/xdv-os.img"
echo "  VirtualBox BIOS: attach xdv-os-mbr-64m.img (or xdv-os.img)"
echo "  VirtualBox UEFI: enable EFI and attach xdv-os-uefi-64m.img"
echo
