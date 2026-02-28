#!/bin/bash
# xdv-os build pipeline:
# - cleans prior generated xdv-os artifacts
# - validates one compileable integration entry per required subsystem
# - compiles GCC-style object sets with dust obj for boot and kernel sources
# - links boot.bin with dustlink from xdv-boot object set
# - links kernel.bin with dustlink from xdv-kernel + xdv-runtime + xdv-xdvfs object set
# - composes a Dust kernel-chain bundle for traceability:
#   xdv-os/src/xdv_os_boot_contract.ds
#   + xdv-runtime/src/runtime_bridge.ds
#   + xdv-shell/src/shell_boot_units.ds
#   + xdv-shell/src/shell_bridge.ds
#   + xdv-dal/src/dal.ds
#   + xdv-cds/src/cds.ds
#   + xdv-umf/src/umf.ds
#   + xdv-hypervisor/src/hypervisor.ds
#   + xdv-sdbm/src/sdbm.ds
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
BOOT_SRC="$REPO_ROOT/xdv-boot/src/boot.ds"
BOOT_PROFILE_SRC="$REPO_ROOT/xdv-boot/src/boot_loader_profile.ds"
BOOT_SPLASH_PROFILE_SRC="$REPO_ROOT/xdv-boot/src/boot_splash_profile.ds"
XDV_LIB_MAIN_SRC="$REPO_ROOT/xdv-lib/sector/xdv_lib/lib.ds"
XDV_LIB_BOOT_RUNTIME_SRC="$REPO_ROOT/xdv-lib/sector/xdv_lib/boot_runtime.ds"
XDV_LIB_BOOT_RUNTIME_ASM="$REPO_ROOT/xdv-lib/asm/xdv_lib_boot_runtime.asm"
SHELL_BOOT_UNITS_SRC="$REPO_ROOT/xdv-shell/src/shell_boot_units.ds"
SHELL_BRIDGE_SRC="$REPO_ROOT/xdv-shell/src/shell_bridge.ds"
DAL_SRC="$REPO_ROOT/xdv-dal/src/dal.ds"
CDS_SRC="$REPO_ROOT/xdv-cds/src/cds.ds"
UMF_SRC="$REPO_ROOT/xdv-umf/src/umf.ds"
HYPERVISOR_SRC="$REPO_ROOT/xdv-hypervisor/src/hypervisor.ds"
SDBM_SRC="$REPO_ROOT/xdv-sdbm/src/sdbm.ds"
KERNEL_SRC="$REPO_ROOT/xdv-kernel/sector/xdv_kernel/src/kernel.ds"
RUNTIME_BRIDGE_SRC="$REPO_ROOT/xdv-runtime/src/runtime_bridge.ds"
BOOT_COMBINED_SRC="$SCRIPT_DIR/target/xdv_os_boot_bundle.ds"
KERNEL_COMBINED_SRC="$SCRIPT_DIR/target/xdv_os_kernel_bundle.ds"
BOOT_OBJ_STAGE_DIR="$SCRIPT_DIR/target/dust/obj_stage_boot"
KERNEL_OBJ_STAGE_DIR="$SCRIPT_DIR/target/dust/obj_stage_kernel"
XDV_LIB_BOOT_RUNTIME_OBJ="$SCRIPT_DIR/target/dust/xdv_lib_boot_runtime.o"
BOOT_MAP_PATH="$SCRIPT_DIR/target/dust/boot.map"
KERNEL_MAP_PATH="$SCRIPT_DIR/target/dust/kernel.map"
BOOT_ENTRY_OFFSET=0
KERNEL_ENTRY_OFFSET=0
BOOT_BIN_PATH="boot.bin"
KERNEL_BIN_PATH="kernel.bin"
DUSTLINK_CMD="$REPO_ROOT/dustlink/target/dust/dustlink"
BOOT_ENTRY_SYMBOL="XdvBoot::boot_main"
KERNEL_ENTRY_SYMBOL="XdvKernel::kernel_start"
BOOT_LINK_ENTRY="xdv_lib_boot_main"
KERNEL_LINK_ENTRY="kernel_start"
if [ -f "$REPO_ROOT/dustlink/target/dust/dustlink.exe" ]; then
    DUSTLINK_CMD="$REPO_ROOT/dustlink/target/dust/dustlink.exe"
fi

echo "=== XDV OS Build (Dust compiler + DPL) ==="
echo "  OS root: $OS_ROOT"
echo "  Repo root: $REPO_ROOT"
echo

echo "[0/7] Cleaning previous xdv-os artifacts..."
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

if [ ! -f "$DUSTLINK_CMD" ]; then
    echo "[dustlink] Building dustlink from Dust source..."
    "$DUST_CMD" build "$REPO_ROOT/dustlink/src" --out "$REPO_ROOT/dustlink/target/dust/dustlink"
    if [ -f "$REPO_ROOT/dustlink/target/dust/dustlink.exe" ]; then
        DUSTLINK_CMD="$REPO_ROOT/dustlink/target/dust/dustlink.exe"
    elif [ -f "$REPO_ROOT/dustlink/target/dust/dustlink" ]; then
        DUSTLINK_CMD="$REPO_ROOT/dustlink/target/dust/dustlink"
    fi
fi

if [ ! -f "$DUSTLINK_CMD" ]; then
    if command -v dustlink >/dev/null 2>&1; then
        DUSTLINK_CMD="$(command -v dustlink)"
    fi
fi

if [ ! -f "$DUSTLINK_CMD" ]; then
    echo "ERROR: dustlink not found at $DUSTLINK_CMD"
    echo "       Build with: $DUST_CMD build $REPO_ROOT/dustlink/src --out $REPO_ROOT/dustlink/target/dust/dustlink"
    exit 1
fi

echo "[1/7] Validating required subsystem entrypoints..."
CHECK_TARGETS=(
    "$BOOT_SRC"
    "$OS_BOOT_CONTRACT_SRC"
    "$BOOT_PROFILE_SRC"
    "$BOOT_SPLASH_PROFILE_SRC"
    "$XDV_LIB_MAIN_SRC"
    "$XDV_LIB_BOOT_RUNTIME_SRC"
    "$REPO_ROOT/xdv-boot/src/boot_mbr.ds"
    "$REPO_ROOT/xdv-boot/src/boot_uefi.ds"
    "$REPO_ROOT/xdv-boot/src/boot_stage1.ds"
    "$DAL_SRC"
    "$CDS_SRC"
    "$UMF_SRC"
    "$HYPERVISOR_SRC"
    "$SDBM_SRC"
    "$KERNEL_SRC"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_mount.ds"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_storage_device.ds"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_partition.ds"
    "$REPO_ROOT/xdv-xdvfs/src/xdvfs_format.ds"
    "$RUNTIME_BRIDGE_SRC"
    "$SHELL_BOOT_UNITS_SRC"
    "$SHELL_BRIDGE_SRC"
    "$REPO_ROOT/xdv-edx/src/edx_bridge.ds"
    "$REPO_ROOT/dustlib/sector/dustlib_core/src/xdv_os_bridge.ds"
    "$REPO_ROOT/dustlib-k/sector/dustlib-k/lib.ds"
    "$REPO_ROOT/dust-runtime/src/runtime_bridge.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_console_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_init_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_io_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_memory_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_process_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_scheduler_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_string_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_runtime_admin.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_sysmon_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_service_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_log_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_storage_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_security_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_recovery_app.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_cli.ds"
    "$REPO_ROOT/xdv-runtime-utils/src/xdv_core_command_profile.ds"
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
if [ ! -f "$XDV_LIB_BOOT_RUNTIME_ASM" ]; then
    echo "ERROR: missing required file: $XDV_LIB_BOOT_RUNTIME_ASM"
    exit 1
fi

echo "[2/7] Composing Dust boot/kernel source bundles..."
cd "$SCRIPT_DIR"
mkdir -p "$SCRIPT_DIR/target"
cat \
    "$BOOT_SRC" \
    "$BOOT_SPLASH_PROFILE_SRC" \
    "$BOOT_PROFILE_SRC" \
    "$REPO_ROOT/xdv-boot/src/boot_disk.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_gdt.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_idt.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_paging.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_xdvfs_mount.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_mbr.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_uefi.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_kernel_load.ds" \
    "$REPO_ROOT/xdv-boot/src/boot_stage1.ds" \
    "$XDV_LIB_MAIN_SRC" \
    "$XDV_LIB_BOOT_RUNTIME_SRC" > "$BOOT_COMBINED_SRC"
cat \
    "$OS_BOOT_CONTRACT_SRC" \
    "$RUNTIME_BRIDGE_SRC" \
    "$SHELL_BOOT_UNITS_SRC" \
    "$SHELL_BRIDGE_SRC" \
    "$DAL_SRC" \
    "$CDS_SRC" \
    "$UMF_SRC" \
    "$HYPERVISOR_SRC" \
    "$SDBM_SRC" \
    "$KERNEL_SRC" \
    "$XDV_LIB_MAIN_SRC" \
    "$XDV_LIB_BOOT_RUNTIME_SRC" > "$KERNEL_COMBINED_SRC"

echo "[3/7] Compiling boot object set via Dust obj..."
"$DUST_CMD" obj \
    "$BOOT_COMBINED_SRC" \
    --out-dir "$BOOT_OBJ_STAGE_DIR" \
    --target "x86_64-pc-none-elf" \
    --entry "$BOOT_ENTRY_SYMBOL" \
    --auto-entry true \
    --skip-tests true

echo "[4/7] Compiling kernel object set via Dust obj..."
"$DUST_CMD" obj \
    "$KERNEL_COMBINED_SRC" \
    "$REPO_ROOT/xdv-xdvfs/src" \
    --out-dir "$KERNEL_OBJ_STAGE_DIR" \
    --target "x86_64-pc-none-elf" \
    --entry "$KERNEL_ENTRY_SYMBOL" \
    --auto-entry true \
    --skip-tests true

if ! command -v nasm >/dev/null 2>&1; then
    echo "ERROR: NASM required. Install with: sudo apt install nasm"
    exit 1
fi
mkdir -p "$SCRIPT_DIR/target/dust"
nasm -f elf64 "$XDV_LIB_BOOT_RUNTIME_ASM" -o "$XDV_LIB_BOOT_RUNTIME_OBJ"

echo "[5/7] Linking boot.bin via dustlink..."
mapfile -t boot_stage_objs < <(find "$BOOT_OBJ_STAGE_DIR" -maxdepth 1 -type f -name '*.o' -print | LC_ALL=C sort)
if [ ${#boot_stage_objs[@]} -eq 0 ]; then
    echo "ERROR: no boot objects found in $BOOT_OBJ_STAGE_DIR"
    exit 1
fi
boot_objs=("${boot_stage_objs[@]}" "$XDV_LIB_BOOT_RUNTIME_OBJ")
echo "  [boot-link] frontend: $DUSTLINK_CMD"
"$DUSTLINK_CMD" \
    -m elf_x86_64 \
    -nostdlib \
    --oformat=binary \
    --image-base 0x10000 \
    -Ttext 0x10000 \
    -Map "$BOOT_MAP_PATH" \
    -e "$BOOT_LINK_ENTRY" \
    -o "$BOOT_BIN_PATH" \
    "${boot_objs[@]}"
boot_entry_hex="$(awk -v sym="$BOOT_LINK_ENTRY" '$0 ~ ("[[:space:]]" sym "$") {print $1; exit}' "$BOOT_MAP_PATH")"
if [ -z "$boot_entry_hex" ]; then
    echo "ERROR: Failed to resolve boot entry offset from $BOOT_MAP_PATH"
    exit 1
fi
BOOT_ENTRY_OFFSET=$((16#$boot_entry_hex - 0x10000))
echo "  [boot-link] entry offset: $BOOT_ENTRY_OFFSET"

echo "[6/7] Linking kernel.bin via dustlink + assembling boot sector (NASM)..."
mapfile -t kernel_objs < <(find "$KERNEL_OBJ_STAGE_DIR" -maxdepth 1 -type f -name '*.o' -print | LC_ALL=C sort)
if [ ${#kernel_objs[@]} -eq 0 ]; then
    echo "ERROR: no kernel objects found in $KERNEL_OBJ_STAGE_DIR"
    exit 1
fi
echo "  [kernel-link] frontend: $DUSTLINK_CMD"
"$DUSTLINK_CMD" \
    -m elf_x86_64 \
    -nostdlib \
    --oformat=binary \
    --image-base 0x20000 \
    -Ttext 0x20000 \
    --allow-multiple-definition \
    -Map "$KERNEL_MAP_PATH" \
    -e "$KERNEL_LINK_ENTRY" \
    -o "$KERNEL_BIN_PATH" \
    "${kernel_objs[@]}"
kernel_entry_hex="$(awk '/[[:space:]]kernel_start$/ {print $1; exit}' "$KERNEL_MAP_PATH")"
if [ -z "$kernel_entry_hex" ]; then
    echo "ERROR: Failed to resolve kernel entry offset from $KERNEL_MAP_PATH"
    exit 1
fi
KERNEL_ENTRY_OFFSET=$((16#$kernel_entry_hex - 0x20000))
echo "  [kernel-link] entry offset: $KERNEL_ENTRY_OFFSET"
nasm -f bin boot_sector.asm -o boot_sector.bin

echo "[7/7] Creating 64MB partitioned images..."
if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File build_images.ps1 \
        -BootSectorPath "boot_sector.bin" \
        -BootPath "$BOOT_BIN_PATH" \
        -KernelPath "$KERNEL_BIN_PATH" \
        -BootEntryOffset "$BOOT_ENTRY_OFFSET" \
        -KernelEntryOffset "$KERNEL_ENTRY_OFFSET" \
        -RepoRoot "$REPO_ROOT" \
        -OutputDir "$SCRIPT_DIR" \
        -ImageSizeMB 64
elif command -v powershell >/dev/null 2>&1; then
    powershell -NoProfile -ExecutionPolicy Bypass -File build_images.ps1 \
        -BootSectorPath "boot_sector.bin" \
        -BootPath "$BOOT_BIN_PATH" \
        -KernelPath "$KERNEL_BIN_PATH" \
        -BootEntryOffset "$BOOT_ENTRY_OFFSET" \
        -KernelEntryOffset "$KERNEL_ENTRY_OFFSET" \
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

