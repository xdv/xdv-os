# Image Layout

`xdv-os` builds 64 MB images with explicit partition/layout policy.

## Image Variants

- `xdv-os-mbr-64m.img`: BIOS/MBR profile
- `xdv-os-uefi-64m.img`: GPT profile with ESP + xdvfs partition
- `xdv-os.img`: alias to MBR image

## xdvfs Layout Markers

The build image script writes xdvfs metadata and staged payload regions:

- partition start LBA base (default profile starts at 2048 in MBR mode)
- boot record and superblock markers
- `boot.bin` staging region
- `kernel.bin` staging region
- preload payload region

The preload payload includes:

- `xdv-os` sources/payload metadata
- `xdv-core` payload set
- `xdv-edx` payload set
- `xdv-shell` payload set
- kernel path marker and staged kernel payload at `console/kernel.bin`

## UEFI Image Additions

UEFI image generation includes:

- protective MBR
- GPT primary/backup headers and partition arrays
- ESP volume content (including boot manager payload)
- xdvfs partition carrying `boot.bin`, `kernel.bin`, and preload payload
