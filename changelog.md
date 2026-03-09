# XDV OS Changelog

## 2026-02-28

### Added
- Added VirtualBox CI boot profile test script: `scripts/ci_virtualbox_boot_test.ps1`.
- Added CI boot profile documentation: `docs/ci_virtualbox_profile.md`.

### Changed
- Enforced `XDV-062` integration contract in CI:
  - orchestration-only scope check for `xdv-os/src`
  - deterministic two-pass build hash verification
  - required VirtualBox BIOS boot-profile job on VirtualBox-capable runner
- Made image composition deterministic in `src/build_images.ps1`:
  - deterministic UEFI PE/COFF timestamp
  - deterministic GPT disk and partition GUID generation derived from image inputs
- Made linker input ingestion deterministic in `src/build.bat` and `src/build.sh`
  by sorting object lists before `dustlink` invocation.
- Updated `README.md` and docs to document XDV-062 orchestration, determinism,
  and CI boot profile enforcement.
- Cut over kernel composition to consume standalone split projects:
  - `xdv-dal`
  - `xdv-cds`
  - `xdv-umf`
  - `xdv-hypervisor`
  - `xdv-sdbm`
- Updated build pipelines (`src/build.bat`, `src/build.sh`) to validate and
  bundle split subsystem sources into the kernel compile stage.
- Updated workspace manifest (`State.toml`) to register split projects as
  sectors and explicit entrypoints.
- Updated documentation to reflect standalone dependency consumption in kernel
  linkage and boot contract docs.

## 2026-02-21

### Added
- Added `xdv-os/docs/` documentation set:
  - `docs/README.md`
  - `docs/build_pipeline.md`
  - `docs/boot_contract.md`
  - `docs/image_layout.md`

### Changed
- Updated `README.md` to reflect current integration role of `xdv-os` and the
  current boot contract:
  - stage0 loads `boot.bin` only,
  - `boot.bin` handles `/console/kernel.bin` discovery and handoff,
  - `boot.bin` and `kernel.bin` are linked through `dustlink` from object sets.
- Updated README artifact and build composition descriptions to match current
  build script behavior (`build.bat`, `build.sh`, `build_images.ps1`).

## 2026-02-19

### Changed
- Enforced strict stage0 contract in `xdv-os/src/boot_sector.asm`: stage0 now
  loads only `boot.bin` and never preloads or jumps to `kernel.bin`.
- Updated boot runtime flow in `xdv-boot/src/boot.ds` to show splash, wait
  8 seconds, recognize MBR/UEFI origin, load `kernel.bin` from
  `xdvfs:/console/kernel.bin`, and hand off to kernel.
- Updated firmware detection behavior in `xdv-boot/src/boot_loader_profile.ds`
  to treat MBR/UEFI as loader-origin recognition (not kernel-location strategy).
- Updated xdvfs kernel path resolution in `xdv-boot/src/boot_xdvfs_mount.ds`
  to resolve `/console/kernel.bin`.
- Updated kernel loader path and logs in `xdv-boot/src/boot_kernel_load.ds`,
  `xdv-boot/src/boot_mbr.ds`, and `xdv-boot/src/boot_uefi.ds`.

### Build/Image
- Updated `xdv-os/src/build_images.ps1` preload payload to include
  `console/kernel.bin` in the xdvfs image.
- Added `kernel-path=/console/kernel.bin` to preload manifest content generated
  by `build_images.ps1`.
- Refactored runtime utility source path consumption from `xdv-core/src` to
  `xdv-runtime-utils/src` in `xdv-os/src/build.bat`, `xdv-os/src/build.sh`, and
  `xdv-os/src/build_images.ps1`.

### Runtime
- Updated `xdv-lib/asm/xdv_lib_boot_runtime.asm` so boot runtime performs final
  kernel transfer by loading kernel sectors at handoff time (instead of
  assuming stage0 preloaded kernel).
