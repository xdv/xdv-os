# xdv-os

XDV Operating System integration workspace.

## Build

Windows:

```cmd
cd xdv-os\src
build.bat
```

Linux/macOS:

```bash
cd xdv-os/src
./build.sh
```

## Clean

PowerShell cleanup script (dry-run by default):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File xdv-os/scripts/clean_xdv_os.ps1
```

Apply deletion:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File xdv-os/scripts/clean_xdv_os.ps1 -Apply
```

## Artifacts

The build now emits partitioned 64MB disk images:

- `xdv-os/src/xdv-os-mbr-64m.img` - BIOS/MBR boot image.
- `xdv-os/src/xdv-os-uefi-64m.img` - GPT image with ESP and xdvfs partition.
- `xdv-os/src/xdv-os.img` - compatibility alias to the MBR image.

## Image Contents

- Dust boot chain bundle:
  `xdv-os/src/xdv_os_boot_contract.ds`
  + `xdv-boot/src/boot_loader_profile.ds`
  + `xdv-runtime/src/runtime_bridge.ds`
  + `xdv-kernel/sector/xdv_kernel/src/kernel.ds`.
- BIOS stage-0 machine code that reads xdvfs boot-record metadata (kernel LBA/sectors).
- `xdvfs` superblock and layout markers.
- preload payload with `xdv-os`, `xdv-core`, `xdv-edx`, and `xdv-shell`.
