# Build Pipeline

`xdv-os/src/build.bat` and `xdv-os/src/build.sh` implement the integration
pipeline.

## High-Level Stages

1. clean generated artifacts (`scripts/clean_xdv_os.ps1 -Apply`)
2. resolve/build `dust`
3. resolve/build `dustlink`
4. validate required subsystem entry files with `dust check`
5. compose boot/kernel bundle sources under `src/target/`
6. compile object sets via `dust obj`
7. assemble required NASM objects (`xdv-lib` boot runtime object + stage0 boot sector)
8. link `boot.bin` and `kernel.bin` with `dustlink`
9. generate partitioned 64 MB images with `build_images.ps1`
10. optionally sync MBR raw image to VirtualBox VDI (`scripts/sync_vdi.ps1`)

## Toolchain Inputs

- `dust` compiler
- `dustlink`
- `nasm`
- PowerShell (`pwsh` or Windows PowerShell) for image generation and cleanup

## Primary Inputs

- `xdv-os/src/xdv_os_boot_contract.ds`
- `xdv-boot/src/*.ds`
- `xdv-kernel/sector/xdv_kernel/src/kernel.ds`
- `xdv-runtime/src/runtime_bridge.ds`
- `xdv-shell/src/shell_boot_units.ds`
- `xdv-shell/src/shell_bridge.ds`
- `xdv-xdvfs/src/*.ds`
- `xdv-os/src/boot_sector.asm`
- `xdv-lib/asm/xdv_lib_boot_runtime.asm`

## Outputs

Generated under `xdv-os/src`:

- `boot.bin`
- `kernel.bin`
- `boot_sector.bin`
- `xdv-os-mbr-64m.img`
- `xdv-os-uefi-64m.img`
- `xdv-os.img`
- `xdv-os-mbr-64m.vdi` (if VDI sync is enabled and VirtualBox tools are present)
