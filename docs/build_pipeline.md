# Build Pipeline

`xdv-os/src/build.bat` and `xdv-os/src/build.sh` implement the XDV-062
integration pipeline.

## Integration Scope

`xdv-os` remains orchestration-only:

- compose source inputs from component projects
- build/link boot and kernel artifacts
- compose deterministic 64 MB images
- run CI profile tests

Runtime behavior belongs to `xdv-boot`, `xdv-kernel`, `xdv-runtime`, and
related dependency projects.

## High-Level Stages

1. clean generated artifacts (`scripts/clean_xdv_os.ps1 -Apply`)
2. resolve/build `dust`
3. resolve/build `dustlink`
4. validate required subsystem entry files with `dust check`
5. compose boot/kernel bundle sources under `src/target/`
6. compile object sets via `dust obj`
7. assemble required NASM objects (`xdv-lib` boot runtime object + stage0 boot sector)
8. link `boot.bin` and `kernel.bin` with `dustlink` using deterministic object ordering
9. generate deterministic partitioned 64 MB images with `build_images.ps1`
10. optionally sync MBR raw image to VirtualBox VDI (`scripts/sync_vdi.ps1`)

## Determinism Controls

Deterministic composition is enforced by:

- sorted object ingestion during `dustlink` invocations
- deterministic GPT GUID generation derived from image payload inputs
- deterministic PE/COFF timestamp in generated UEFI stub payload
- stable preload manifest/file ordering in xdvfs payload generation

CI validates determinism by running two full builds and diffing SHA-256 hashes
for `boot.bin`, `kernel.bin`, and both image variants.

## Toolchain Inputs

- `dust` compiler
- `dustlink`
- `nasm`
- PowerShell (`pwsh` or Windows PowerShell) for image generation and cleanup

## Primary Inputs

- `xdv-os/src/xdv_os_boot_contract.ds`
- `xdv-boot/src/*.ds`
- `xdv-dal/src/dal.ds`
- `xdv-cds/src/cds.ds`
- `xdv-umf/src/umf.ds`
- `xdv-hypervisor/src/hypervisor.ds`
- `xdv-sdbm/src/sdbm.ds`
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

## CI Boot Validation

The VirtualBox BIOS boot profile is enforced by:

- workflow job: `virtualbox_boot_profile`
- script: `xdv-os/scripts/ci_virtualbox_boot_test.ps1`

See `ci_virtualbox_profile.md` for runner requirements and pass/fail criteria.
