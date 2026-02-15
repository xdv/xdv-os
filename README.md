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

## Artifacts

The build now emits partitioned 64MB disk images:

- `xdv-os/src/xdv-os-mbr-64m.img` - BIOS/MBR boot image.
- `xdv-os/src/xdv-os-uefi-64m.img` - GPT image with ESP and xdvfs partition.
- `xdv-os/src/xdv-os.img` - compatibility alias to the MBR image.

## Image Contents

- `xdv-boot` boot path metadata and BIOS stage machine code.
- `xdv-kernel` + `xdv-runtime` combined bare-metal kernel binary.
- `xdvfs` superblock and layout markers.
- preload payload with `xdv-core`, `xdv-edx`, and `xdv-shell`.
