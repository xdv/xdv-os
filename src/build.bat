@echo off
REM xdv-os build pipeline:
REM - validates one compileable integration entry per required subsystem
REM - builds a bare-metal kernel binary from a composed source bundle:
REM   xdv-runtime/src/runtime_bridge.ds + xdv-kernel/sector/xdv_kernel/src/kernel.ds
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
set "KERNEL_SRC=%REPO_ROOT%\xdv-kernel\sector\xdv_kernel\src\kernel.ds"
set "RUNTIME_BRIDGE_SRC=%REPO_ROOT%\xdv-runtime\src\runtime_bridge.ds"
set "KERNEL_COMBINED_SRC=%~dp0target\kernel_runtime_bundle.ds"

echo === XDV OS Build (Dust compiler + DPL) ===
echo   OS root: %OS_ROOT%
echo   Repo root: %REPO_ROOT%
echo.

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

echo [1/4] Validating required subsystem entrypoints...
call :check_file "%REPO_ROOT%\xdv-boot\src\boot_mbr.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-boot\src\boot_uefi.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-boot\src\boot_stage1.ds" || exit /b 1
call :check_file "%KERNEL_SRC%" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_mount.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_storage_device.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_partition.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-xdvfs\src\xdvfs_format.ds" || exit /b 1
call :check_file "%RUNTIME_BRIDGE_SRC%" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-shell\src\shell_bridge.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-edx\src\edx_bridge.ds" || exit /b 1
call :check_file "%REPO_ROOT%\dustlib\sector\dustlib_core\src\xdv_os_bridge.ds" || exit /b 1
call :check_file "%REPO_ROOT%\dustlib_k\sector\dustlib_k\lib.ds" || exit /b 1
call :check_file "%REPO_ROOT%\dust_runtime\src\runtime_bridge.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_console_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_init_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_io_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_memory_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_process_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_scheduler_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_string_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_runtime_admin.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_sysmon_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_service_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_log_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_storage_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_security_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_recovery_app.ds" || exit /b 1
call :check_file "%REPO_ROOT%\xdv-core\src\xdv_core_cli.ds" || exit /b 1
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

echo [2/4] Compiling kernel from DPL (kernel + runtime bridge)...
if not exist "%~dp0target" mkdir "%~dp0target"
copy /b "%RUNTIME_BRIDGE_SRC%"+"%KERNEL_SRC%" "%KERNEL_COMBINED_SRC%" >nul
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to compose kernel/runtime source bundle
    exit /b 1
)
"%DUST_CMD%" obj "%KERNEL_COMBINED_SRC%" --bare-metal -o kernel.bin
if %ERRORLEVEL% neq 0 (
    echo ERROR: dust obj failed
    exit /b 1
)

echo [3/4] Assembling boot sector (NASM)...
where nasm >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo ERROR: NASM not found. Install from https://www.nasm.us/
    exit /b 1
)
nasm -f bin boot_sector.asm -o boot_sector.bin
if %ERRORLEVEL% neq 0 (
    echo ERROR: NASM failed
    exit /b 1
)

echo [4/4] Creating 64MB partitioned images...
powershell -NoProfile -ExecutionPolicy Bypass -File build_images.ps1 ^
  -BootSectorPath "boot_sector.bin" ^
  -KernelPath "kernel.bin" ^
  -RepoRoot "%REPO_ROOT%" ^
  -OutputDir "%~dp0." ^
  -ImageSizeMB 64
if %ERRORLEVEL% neq 0 (
    echo ERROR: Failed to create partitioned images
    exit /b 1
)

echo.
echo === Build complete ===
echo   Output (MBR):  %~dp0xdv-os-mbr-64m.img
echo   Output (UEFI): %~dp0xdv-os-uefi-64m.img
echo   Alias:         %~dp0xdv-os.img
echo   VirtualBox BIOS: attach xdv-os-mbr-64m.img (or xdv-os.img)
echo   VirtualBox UEFI: enable EFI and attach xdv-os-uefi-64m.img
echo.
exit /b 0
