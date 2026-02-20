@echo off
REM xdv-os build pipeline:
REM - cleans prior generated xdv-os artifacts
REM - validates one compileable integration entry per required subsystem
REM - compiles GCC-style object sets with dust obj for boot and kernel sources
REM - links boot.bin with dustlink from xdv-boot object set
REM - links kernel.bin with dustlink from xdv-kernel + xdv-runtime + xdv-xdvfs object set
REM - composes a Dust kernel-chain bundle for traceability:
REM   xdv-os/src/xdv_os_boot_contract.ds
REM   + xdv-runtime/src/runtime_bridge.ds
REM   + xdv-shell/src/shell_boot_units.ds
REM   + xdv-shell/src/shell_bridge.ds
REM   + xdv-kernel/sector/xdv_kernel/src/kernel.ds
REM - assembles MBR boot sector
REM - generates partitioned 64MB images:
REM     xdv-os-mbr-64m.img (MBR)
REM     xdv-os-uefi-64m.img (GPT/ESP + xdvfs)
REM   and xdv-os.img as alias to the MBR artifact

goto :main

:check_file
set "TARGET=%~1"
if not exist "%TARGET%" (
    echo ERROR: missing required file: %TARGET%
    exit /b 1
)
echo   - %TARGET%
"%DUST_CMD%" check "%TARGET%" >nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: dust check failed for %TARGET%
    exit /b 1
)
exit /b 0

:main
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "OS_ROOT=%~dp0.."
set "REPO_ROOT=%~dp0..\.."
set "CLEAN_SCRIPT=%OS_ROOT%\scripts\clean_xdv_os.ps1"
set "OS_BOOT_CONTRACT_SRC=%~dp0xdv_os_boot_contract.ds"
set "BOOT_SRC=%REPO_ROOT%\xdv-boot\src\boot.ds"
set "BOOT_PROFILE_SRC=%REPO_ROOT%\xdv-boot\src\boot_loader_profile.ds"
set "BOOT_SPLASH_PROFILE_SRC=%REPO_ROOT%\xdv-boot\src\boot_splash_profile.ds"
set "XDV_LIB_MAIN_SRC=%REPO_ROOT%\xdv-lib\sector\xdv_lib\lib.ds"
set "XDV_LIB_BOOT_RUNTIME_SRC=%REPO_ROOT%\xdv-lib\sector\xdv_lib\boot_runtime.ds"
set "XDV_LIB_BOOT_RUNTIME_ASM=%REPO_ROOT%\xdv-lib\asm\xdv_lib_boot_runtime.asm"
set "SHELL_BOOT_UNITS_SRC=%REPO_ROOT%\xdv-shell\src\shell_boot_units.ds"
set "SHELL_BRIDGE_SRC=%REPO_ROOT%\xdv-shell\src\shell_bridge.ds"
set "KERNEL_SRC=%REPO_ROOT%\xdv-kernel\sector\xdv_kernel\src\kernel.ds"
set "RUNTIME_BRIDGE_SRC=%REPO_ROOT%\xdv-runtime\src\runtime_bridge.ds"
set "BOOT_COMBINED_SRC=%~dp0target\xdv_os_boot_bundle.ds"
set "KERNEL_COMBINED_SRC=%~dp0target\xdv_os_kernel_bundle.ds"
set "BOOT_OBJ_STAGE_DIR=%~dp0target\dust\obj_stage_boot"
set "KERNEL_OBJ_STAGE_DIR=%~dp0target\dust\obj_stage_kernel"
set "XDV_LIB_BOOT_RUNTIME_OBJ=%~dp0target\dust\xdv_lib_boot_runtime.o"
set "BOOT_MAP_PATH=%~dp0target\dust\boot.map"
set "KERNEL_MAP_PATH=%~dp0target\dust\kernel.map"
set "BOOT_ENTRY_OFFSET="
set "KERNEL_ENTRY_OFFSET="
set "BOOT_BIN_PATH=boot.bin"
set "KERNEL_BIN_PATH=kernel.bin"
set "MBR_IMAGE_PATH=%~dp0xdv-os-mbr-64m.img"
set "MBR_VDI_PATH=%~dp0xdv-os-mbr-64m.vdi"
set "SYNC_VDI_SCRIPT=%OS_ROOT%\scripts\sync_vdi.ps1"
set "DUSTLINK_CMD=%REPO_ROOT%\dustlink\target\dust\dustlink.exe"
set "BOOT_ENTRY_SYMBOL=XdvBoot::boot_main"
set "KERNEL_ENTRY_SYMBOL=XdvKernel::kernel_start"
set "BOOT_LINK_ENTRY=xdv_lib_boot_main"
set "KERNEL_LINK_ENTRY=kernel_start"

echo === XDV OS Build (Dust compiler + DPL) ===
echo   OS root: %OS_ROOT%
echo   Repo root: %REPO_ROOT%
echo.

echo [0/7] Cleaning previous xdv-os artifacts...
if not exist "%CLEAN_SCRIPT%" (
    echo ERROR: cleanup script missing: %CLEAN_SCRIPT%
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%CLEAN_SCRIPT%" -Apply
if %ERRORLEVEL% neq 0 (
    echo ERROR: cleanup script failed
    exit /b 1
)

if exist "%REPO_ROOT%\dust\Cargo.toml" (
    echo [dust] Refreshing compiler...
    pushd "%REPO_ROOT%\dust" >nul
    cargo build --release >nul 2>nul || cargo build >nul 2>nul
    popd >nul
)

REM 1) Resolve dust compiler
set "DUST_CMD="
if exist "%REPO_ROOT%\dust\target\release\dust.exe" (
    set "DUST_CMD=%REPO_ROOT%\dust\target\release\dust.exe"
    goto :dust_found
)
if exist "%REPO_ROOT%\dust\target\debug\dust.exe" (
    set "DUST_CMD=%REPO_ROOT%\dust\target\debug\dust.exe"
    goto :dust_found
)
for /f "delims=" %%I in ('where dust 2^>nul') do (
    set "DUST_CMD=%%I"
    goto :dust_found
)

echo Building dust compiler...
pushd "%REPO_ROOT%\dust" >nul
cargo build --release >nul 2>nul || cargo build >nul 2>nul
popd >nul
if exist "%REPO_ROOT%\dust\target\release\dust.exe" (
    set "DUST_CMD=%REPO_ROOT%\dust\target\release\dust.exe"
) else if exist "%REPO_ROOT%\dust\target\debug\dust.exe" (
    set "DUST_CMD=%REPO_ROOT%\dust\target\debug\dust.exe"
)

:dust_found
if not defined DUST_CMD (
    echo ERROR: dust compiler not found. Build from %REPO_ROOT%\dust with: cargo build
    exit /b 1
)

if not exist "%DUSTLINK_CMD%" (
    echo [dustlink] Building dustlink from Dust source...
    "%DUST_CMD%" build "%REPO_ROOT%\dustlink\src" --out "%REPO_ROOT%\dustlink\target\dust\dustlink"
    if exist "%REPO_ROOT%\dustlink\target\dust\dustlink.exe" (
        set "DUSTLINK_CMD=%REPO_ROOT%\dustlink\target\dust\dustlink.exe"
    ) else if exist "%REPO_ROOT%\dustlink\target\dust\dustlink" (
        set "DUSTLINK_CMD=%REPO_ROOT%\dustlink\target\dust\dustlink"
    )
)

if not exist "%DUSTLINK_CMD%" (
    for /f "delims=" %%I in ('where dustlink 2^>nul') do (
        set "DUSTLINK_CMD=%%I"
        goto :dustlink_found
    )
)

:dustlink_found
if not exist "%DUSTLINK_CMD%" (
    echo ERROR: dustlink not found at %DUSTLINK_CMD%
    echo        Build with: %DUST_CMD% build %REPO_ROOT%\dustlink\src --out %REPO_ROOT%\dustlink\target\dust\dustlink
    exit /b 1
)

echo [1/7] Validating required subsystem entrypoints...
call :check_file "%BOOT_SRC%" || exit /b 1
call :check_file "%OS_BOOT_CONTRACT_SRC%" || exit /b 1
call :check_file "%BOOT_PROFILE_SRC%" || exit /b 1
call :check_file "%BOOT_SPLASH_PROFILE_SRC%" || exit /b 1
call :check_file "%XDV_LIB_MAIN_SRC%" || exit /b 1
call :check_file "%XDV_LIB_BOOT_RUNTIME_SRC%" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-boot\src\boot_mbr.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-boot\src\boot_uefi.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-boot\src\boot_stage1.ds" || exit /b 1
call :check_file "%KERNEL_SRC%" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_mount.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_storage_device.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_partition.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_format.ds" || exit /b 1
call :check_file "%RUNTIME_BRIDGE_SRC%" || exit /b 1
call :check_file "%SHELL_BOOT_UNITS_SRC%" || exit /b 1
call :check_file "%SHELL_BRIDGE_SRC%" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-edx\src\edx_bridge.ds" || exit /b 1
call :check_file "%REPO_ROOT%\dustlib\sector\dustlib_core\src\xdv_os_bridge.ds" || exit /b 1
call :check_file "%REPO_ROOT%\dustlib-k\sector\dustlib-k\lib.ds" || exit /b 1
call :check_file "%REPO_ROOT%\dust-runtime\src\runtime_bridge.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_console_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_init_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_io_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_memory_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_process_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_scheduler_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_string_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_runtime_admin.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_sysmon_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_service_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_log_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_storage_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_security_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_recovery_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_cli.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-runtime-utils\src\xdv_core_command_profile.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_partition.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_mkfs.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_fsck.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_probe.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_dir.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_file.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_mount.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_space.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_perm.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs-utils\src\xdvfs_utils_cli.ds" || exit /b 1
if not exist "%XDV_LIB_BOOT_RUNTIME_ASM%" (
    echo ERROR: missing required file: %XDV_LIB_BOOT_RUNTIME_ASM%
    exit /b 1
)

echo [2/7] Composing Dust boot/kernel source bundles...
if not exist "%~dp0target" mkdir "%~dp0target"
(
    type "%BOOT_SRC%"
    echo.
    type "%BOOT_SPLASH_PROFILE_SRC%"
    echo.
    type "%BOOT_PROFILE_SRC%"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_disk.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_gdt.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_idt.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_paging.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_xdvfs_mount.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_mbr.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_uefi.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_kernel_load.ds"
    echo.
    type "%REPO_ROOT%\xdv-boot\src\boot_stage1.ds"
    echo.
    type "%XDV_LIB_MAIN_SRC%"
    echo.
    type "%XDV_LIB_BOOT_RUNTIME_SRC%"
) > "%BOOT_COMBINED_SRC%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to compose xdv-boot source bundle
    exit /b 1
)
(
    type "%OS_BOOT_CONTRACT_SRC%"
    echo.
    type "%RUNTIME_BRIDGE_SRC%"
    echo.
    type "%SHELL_BOOT_UNITS_SRC%"
    echo.
    type "%SHELL_BRIDGE_SRC%"
    echo.
    type "%KERNEL_SRC%"
    echo.
    type "%XDV_LIB_MAIN_SRC%"
    echo.
    type "%XDV_LIB_BOOT_RUNTIME_SRC%"
) > "%KERNEL_COMBINED_SRC%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to compose xdv-os/xdv-boot/xdv-runtime/xdv-shell/xdv-kernel source bundle
    exit /b 1
)

echo [3/7] Compiling boot object set via Dust obj...
"%DUST_CMD%" obj ^
  "%BOOT_COMBINED_SRC%" ^
  --out-dir "%BOOT_OBJ_STAGE_DIR%" ^
  --target "x86_64-pc-none-elf" ^
  --entry "%BOOT_ENTRY_SYMBOL%" ^
  --auto-entry true ^
  --skip-tests true
if %ERRORLEVEL% neq 0 (
    echo ERROR: dust obj failed while producing boot object set.
    exit /b 1
)

echo [4/7] Compiling kernel object set via Dust obj...
"%DUST_CMD%" obj ^
  "%KERNEL_COMBINED_SRC%" ^
  "%REPO_ROOT%\xdv-xdvfs\src" ^
  --out-dir "%KERNEL_OBJ_STAGE_DIR%" ^
  --target "x86_64-pc-none-elf" ^
  --entry "%KERNEL_ENTRY_SYMBOL%" ^
  --auto-entry true ^
  --skip-tests true
if %ERRORLEVEL% neq 0 (
    echo ERROR: dust obj failed while producing kernel object set.
    exit /b 1
)

where nasm >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: NASM not found. Install from https://www.nasm.us/
    exit /b 1
)
if not exist "%~dp0target\dust" mkdir "%~dp0target\dust"
nasm -f elf64 "%XDV_LIB_BOOT_RUNTIME_ASM%" -o "%XDV_LIB_BOOT_RUNTIME_OBJ%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: NASM failed while assembling xdv-lib boot runtime object.
    exit /b 1
)

echo [5/7] Linking boot.bin via dustlink...
set "BOOT_LINK_OBJECTS="
for %%F in ("%BOOT_OBJ_STAGE_DIR%\*.o") do (
    set "BOOT_LINK_OBJECTS=!BOOT_LINK_OBJECTS! "%%~fF""
)
set "BOOT_LINK_OBJECTS=!BOOT_LINK_OBJECTS! "%XDV_LIB_BOOT_RUNTIME_OBJ%""
echo   [boot-link] frontend: %DUSTLINK_CMD%
"%DUSTLINK_CMD%" -m elf_x86_64 -nostdlib --oformat=binary --image-base 0x10000 -Ttext 0x10000 -Map "%BOOT_MAP_PATH%" -e %BOOT_LINK_ENTRY% -o "%BOOT_BIN_PATH%" !BOOT_LINK_OBJECTS!
if %ERRORLEVEL% neq 0 (
    echo ERROR: dustlink boot link failed.
    exit /b 1
)
set "BOOT_ENTRY_HEX="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "$m = Select-String -Path '%BOOT_MAP_PATH%' -Pattern '\s%BOOT_LINK_ENTRY%(\s|$)' | Select-Object -First 1; if ($m) { ($m.Line.Trim() -split '\s+')[0] }"`) do set "BOOT_ENTRY_HEX=%%I"
if not defined BOOT_ENTRY_HEX (
    echo ERROR: Failed to resolve boot entry offset from %BOOT_MAP_PATH%
    exit /b 1
)
set /a BOOT_ENTRY_OFFSET=0x!BOOT_ENTRY_HEX! - 0x10000
echo   [boot-link] entry offset: !BOOT_ENTRY_OFFSET!

echo [6/7] Linking kernel.bin via dustlink + assembling boot sector (NASM)...
set "KERNEL_LINK_OBJECTS="
for %%F in ("%KERNEL_OBJ_STAGE_DIR%\*.o") do (
    set "KERNEL_LINK_OBJECTS=!KERNEL_LINK_OBJECTS! "%%~fF""
)
echo   [kernel-link] frontend: %DUSTLINK_CMD%
"%DUSTLINK_CMD%" -m elf_x86_64 -nostdlib --oformat=binary --image-base 0x20000 -Ttext 0x20000 --allow-multiple-definition -Map "%KERNEL_MAP_PATH%" -e %KERNEL_LINK_ENTRY% -o "%KERNEL_BIN_PATH%" !KERNEL_LINK_OBJECTS!
if %ERRORLEVEL% neq 0 (
    echo ERROR: dustlink kernel link failed.
    exit /b 1
)
set "KERNEL_ENTRY_HEX="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "$m = Select-String -Path '%KERNEL_MAP_PATH%' -Pattern '\s%KERNEL_LINK_ENTRY%(\s|$)' | Select-Object -First 1; if ($m) { ($m.Line.Trim() -split '\s+')[0] }"`) do set "KERNEL_ENTRY_HEX=%%I"
if not defined KERNEL_ENTRY_HEX (
    echo ERROR: Failed to resolve kernel entry offset from %KERNEL_MAP_PATH%
    exit /b 1
)
set /a KERNEL_ENTRY_OFFSET=0x!KERNEL_ENTRY_HEX! - 0x20000
echo   [kernel-link] entry offset: !KERNEL_ENTRY_OFFSET!
nasm -f bin boot_sector.asm -o boot_sector.bin
if %ERRORLEVEL% neq 0 (
    echo ERROR: NASM failed
    exit /b 1
)

echo [7/8] Creating 64MB partitioned images...
powershell -NoProfile -ExecutionPolicy Bypass -File build_images.ps1 ^
  -BootSectorPath "boot_sector.bin" ^
  -BootPath "%BOOT_BIN_PATH%" ^
  -KernelPath "%KERNEL_BIN_PATH%" ^
  -BootEntryOffset !BOOT_ENTRY_OFFSET! ^
  -KernelEntryOffset !KERNEL_ENTRY_OFFSET! ^
  -RepoRoot "%REPO_ROOT%" ^
  -OutputDir "%~dp0." ^
  -ImageSizeMB 64
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to create partitioned images
    exit /b 1
)

echo [8/8] Syncing VirtualBox VDI from MBR image...
if exist "%SYNC_VDI_SCRIPT%" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SYNC_VDI_SCRIPT%" -RawImagePath "%MBR_IMAGE_PATH%" -VdiPath "%MBR_VDI_PATH%"
    if !ERRORLEVEL! neq 0 (
        echo WARNING: VDI sync failed; raw images are still available.
    )
) else (
    echo   VDI sync script missing; skipping.
)

echo.
echo === Build complete ===
echo   Output (MBR):  %~dp0xdv-os-mbr-64m.img
echo   Output (UEFI): %~dp0xdv-os-uefi-64m.img
echo   Alias:         %~dp0xdv-os.img
echo   Output (VDI):  %~dp0xdv-os-mbr-64m.vdi
echo   VirtualBox BIOS: attach xdv-os-mbr-64m.img (or xdv-os.img)
echo   VirtualBox UEFI: enable EFI and attach xdv-os-uefi-64m.img
echo.
exit /b 0

