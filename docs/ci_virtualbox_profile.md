# CI VirtualBox Boot Profile

This document defines the enforced VirtualBox boot test profile for `xdv-os`.

## Scope

The CI boot profile validates that the composed MBR image boots in VirtualBox
without early VM abort/guru/triple-fault behavior.

## Script

- `xdv-os/scripts/ci_virtualbox_boot_test.ps1`

The script performs:

1. `convertfromraw` of `xdv-os/src/xdv-os-mbr-64m.img` to a temporary VDI.
2. transient VM creation in BIOS mode.
3. headless boot with fixed VM profile.
4. boot-time wait window (`BootTimeoutSec`, default `20`).
5. failure detection using VM state and `VBox.log` fatal signatures.
6. VM teardown and artifact cleanup (unless `-KeepArtifacts` is set).

## Runner Contract

The workflow job `virtualbox_boot_profile` requires a runner with labels:

- `self-hosted`
- `windows`
- `xdv-virtualbox`

The runner must have:

- `VBoxManage` available (`PATH` or default VirtualBox install path)
- `nasm`
- Rust toolchain (for Dust compiler build dependency path)

## Pass/Fail

Pass criteria:

- VM reaches non-fatal runtime state after the boot wait window.
- `VBox.log` has no fatal boot signatures (`Guru Meditation`, triple fault,
  or VirtualBox fatal error markers).

Fail criteria:

- VM state is `aborted`, `gurumeditation`, or `stuck`.
- `VBox.log` contains fatal boot crash signatures.
- VirtualBox command failures in setup/boot/teardown path.
