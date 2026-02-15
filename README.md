# xdv-os

Complete XDV Operating System - Bootable for VirtualBox

xdv-os is an operating system built with the **Dust Programming Language (DPL)** toolchain. The kernel is **compiled from DPL** using the **dust** compiler; the build loads and validates **xdv-kernel**, **xdv-runtime**, **xdv-shell**, **xdv-boot**, **xdv-xdvfs**, **dustlib**, **dustlib_k**, and **dust_runtime**. The bootable image is produced by: `dust obj kernel_entry.ds --bare-metal` (kernel) plus a minimal MBR in assembly (required by the BIOS).

## Overview

xdv-os combines all XDV components into a fully functional operating system that boots in VirtualBox:

- **xdv-boot** - Bootloader (MBR, GDT, IDT, Paging, Disk I/O, XDVFS mount, Kernel load)
- **xdv-kernel** - 13-sector kernel
- **xdv-xdvfs** - Native file system
- **xdv-runtime** - User space runtime
- **xdv-shell** - Command line shell

## Quick Start

### Build on Linux/Mac
```bash
cd src
chmod +x build.sh
./build.sh
```

### Build on Windows
```cmd
cd src
build.bat
```

### Run in VirtualBox
1. Download `xdv-os.img` from CI artifacts
2. Open VirtualBox
3. Create new VM: Type=Other, Version=64-bit
4. Set RAM to 64MB
5. Add xdv-os.img as hard disk (or use vmkfdimg for live CD)
6. Start VM

## Boot Process

```
BIOS -> MBR (0x7C00) -> Load kernel to 0x10000 -> Protected mode -> DPL kernel (VGA output, then halt)
```

1. **BIOS** loads MBR at 0x7C00
2. **Boot sector** (assembly) loads the DPL-built kernel from sector 2 to 0x10000, enables protected mode, jumps to kernel
3. **Kernel** (from `dust obj kernel_entry.ds --bare-metal`) runs at 0x10000: prints boot messages to VGA, then halts

## Expected Boot Output (VirtualBox)

When the OS boots in VirtualBox you should see (then the system halts):

```
XDV Kernel starting...
Initializing XDV Kernel v0.2.0
Build date: 2026-02-12
Booting on K-Domain (x64/Intel/AMD)
K-Domain (x64): ONLINE
XDV: Probing for Q-Domain hardware...
XDV: Q-Domain hardware not detected - disabled
XDV: Probing for Phi-Domain hardware...
XDV: Phi-Domain hardware not detected - disabled
XDV Kernel: Initializing process management
Entering kernel main loop
```

## Memory Layout

```
0x00000 - 0x9FFFF   : Real mode memory
0x07C00             : Boot sector load address
0x10000 (64KB)      : Kernel load address (0x1000:0)
0xB8000             : VGA text memory
0x90000             : Stack
```

## Components

### xdv-boot
- MBR boot sector
- Stage 1 loader
- GDT, IDT
- Paging setup
- Disk I/O
- Kernel loading

### xdv-kernel (13 sectors)
1. xdv_boot - Boot integration
2. xdv_memory - Memory management
3. xdv_cpu - CPU control
4. xdv_drivers - Hardware drivers
5. xdv_kernel - Core kernel
6. xdv_dal - Device Abstraction Layer
7. xdv_qdomain - Q-Domain support (stubbed)
8. xdv_phidomain - Φ-Domain support (stubbed)
9. xdv_cds - Core Data Structures
10. xdv_umf - User Mode Facilities
11. xdv_hypervisor - Hypervisor support
12. xdv_sdbm - Simple Database Manager
13. xdv_odt - Object Dispatch Table

### xdv-xdvfs
- Superblock, Inodes, Block allocation
- Directory operations
- File operations (K-domain only)

### xdv-runtime
- I/O, Memory, String, Process
- Scheduler, FS interface, Console, Init

### xdv-shell
- Lexer, Parser, Executor
- Builtins: cd, ls, cat, mkdir, rm, echo, ps, help, exit
- Tab completion

## Architecture

K-Domain only (classical x86-64 hardware). Q/Φ domains stubbed.

## Directory Structure

```
xdv-os/
├── State.toml
├── src/
│   ├── boot_sector.asm   # MBR (loads kernel, switches to protected mode)
│   ├── kernel_entry.ds   # DPL kernel entry (dust obj --bare-metal -> kernel.bin)
│   ├── build.sh          # Linux/Mac build (dust + NASM -> xdv-os.img)
│   └── build.bat         # Windows build
├── xdv-boot/
├── xdv-kernel/
├── xdv-xdvfs/
├── xdv-runtime/
├── xdv-shell/
└── .github/workflows/
    └── ci.yml            # Builds xdv-os.img with dust
```

## Build (dust + NASM)

The build uses the **dust** compiler and validates all DPL components:

1. **dust** compiler: built from repo root `dust/` if not in PATH
2. **dust check** on: dustlib, dustlib_k, dust_runtime, xdv-boot, xdv-kernel, xdv-runtime, xdv-shell, xdv-xdvfs
3. **dust obj** `kernel_entry.ds` **--bare-metal** → `kernel.bin` (32-bit code, VGA output)
4. **NASM** assembles `boot_sector.asm` → MBR
5. Image: 1 MB disk with MBR + kernel at sector 2

## CI Build

GitHub Actions: build dust, run full build (dust obj + NASM), produce `xdv-os.img` artifact.

## Version

0.2.0
