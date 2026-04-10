# Boot Contract

This document defines boot-stage ownership boundaries in `xdv-os`.

## Stage Ownership

## Stage0 (`boot_sector.asm`)

- Location: `xdv-os/src/boot_sector.asm`
- Responsibility:
  - read xdvfs boot record metadata from boot partition,
  - load `boot.bin`,
  - transfer control to `boot.bin`.
- Non-responsibility:
  - must not preload or jump directly to `kernel.bin`.

## Stage1+ (`boot.bin` / xdv-boot)

- Location: `xdv-boot/src/boot.ds` and supporting boot modules
- Responsibility:
  - display splash profile,
  - hold splash window,
  - detect firmware origin profile (MBR/UEFI),
  - mount xdvfs and locate `/console/kernel.bin`,
  - load kernel and perform final handoff.

## Kernel Stage (`kernel.bin`)

- Location: linked from `xdv-kernel` + split kernel dependencies
  (`xdv-dal`, `xdv-cds`, `xdv-umf`, `xdv-hypervisor`, `xdv-sdbm`) +
  `xdv-runtime` + `xdv-xdvfs`
- Responsibility:
  - start kernel runtime,
  - bring runtime bridge/userspace path online,
  - continue shell/runtime flow.

## Filesystem Contract

- Kernel image must exist in xdvfs at:
  - `/console/kernel.bin`
- Build preload payload and metadata must remain aligned with that path.
