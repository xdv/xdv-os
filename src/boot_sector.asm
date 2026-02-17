; XDV OS boot sector stage-0 (MBR, partition-aware).
; Reads the xdvfs boot record from the boot partition, loads boot.bin first,
; then loads kernel.bin and performs the handoff chain.
; This stage is transport only; boot policy remains defined in Dust.

[ORG 0x7C00]
[BITS 16]

BOOTREC_BUFFER_SEG equ 0x0000
BOOTREC_BUFFER_OFF equ 0x0600
BOOT_LOAD_SEG equ 0x1000
BOOT_LOAD_OFF equ 0x0000
KERNEL_LOAD_SEG equ 0x2000
KERNEL_LOAD_OFF equ 0x0000
BOOT_STAGE_ADDR equ 0x00010000
KERNEL_STAGE_ADDR equ 0x00020000
PAGE_TABLE_PML4 equ 0x00009000
PAGE_TABLE_PDPT equ 0x0000A000
PAGE_TABLE_PD   equ 0x0000B000

    jmp short start
    nop

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl

    ; Use partition entry 0 from MBR table.
    mov si, partition_table
    ; Partition start LBA is +8 in a 16-byte MBR partition entry.
    mov eax, [si + 8]
    mov [partition_start_lba], eax

    ; Read xdvfs boot record (XDVFSBR0) at partition start LBA.
    mov word [dap_count], 1
    mov word [dap_offset], BOOTREC_BUFFER_OFF
    mov word [dap_segment], BOOTREC_BUFFER_SEG
    mov [dap_lba_low], eax

    mov si, disk_address_packet
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error

    ; boot record offsets:
    ; +16 boot.bin relative LBA
    ; +20 boot.bin sectors
    ; +40 boot.bin entry offset from image base (0x00100000)
    ; +32 kernel.bin relative LBA
    ; +36 kernel.bin sectors
    ; +44 kernel.bin entry offset from image base (0x00100000)
    mov si, BOOTREC_BUFFER_OFF
    mov eax, [si + 16]
    add eax, [partition_start_lba]
    mov [dap_lba_low], eax
    mov ax, [si + 20]
    mov [dap_count], ax
    mov word [dap_offset], BOOT_LOAD_OFF
    mov word [dap_segment], BOOT_LOAD_SEG

    mov si, disk_address_packet
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error

    mov si, BOOTREC_BUFFER_OFF
    mov eax, [si + 32]
    add eax, [partition_start_lba]
    mov [dap_lba_low], eax
    mov ax, [si + 36]
    mov [dap_count], ax
    mov word [dap_offset], KERNEL_LOAD_OFF
    mov word [dap_segment], KERNEL_LOAD_SEG

    mov si, disk_address_packet
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc disk_error

    ; Enable A20 gate.
    in al, 0x92
    or al, 0x02
    out 0x92, al

    ; Enter protected mode with interrupts masked (no IDT installed yet).
    cli
    lgdt [gdt_desc]
    mov eax, cr0
    or eax, 0x00000001
    mov cr0, eax
    jmp 0x08:protected_mode_entry

disk_error:
    jmp $

boot_drive db 0x80
partition_start_lba dd 0

; INT13 extended read packet (16 bytes).
disk_address_packet:
    db 0x10
    db 0x00
dap_count:
    dw 0
dap_offset:
    dw 0
dap_segment:
    dw 0
dap_lba_low:
    dd 0
dap_lba_high:
    dd 0

; Protected mode descriptors.
gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF   ; 0x08 protected-mode code segment
    dq 0x00CF92000000FFFF   ; 0x10 data segment
    dq 0x00AF9A000000FFFF   ; 0x18 long-mode code segment
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt

[BITS 32]
protected_mode_entry:
    cli
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; Prepare minimal identity mapping for long mode (0-2MB via 2MB page).
    mov edi, PAGE_TABLE_PML4
    xor eax, eax
    mov ecx, (4096 * 3) / 4
    rep stosd

    mov dword [PAGE_TABLE_PML4 + 0], PAGE_TABLE_PDPT | 0x03
    mov dword [PAGE_TABLE_PML4 + 4], 0
    mov dword [PAGE_TABLE_PDPT + 0], PAGE_TABLE_PD | 0x03
    mov dword [PAGE_TABLE_PDPT + 4], 0
    mov dword [PAGE_TABLE_PD + 0], 0x00000083
    mov dword [PAGE_TABLE_PD + 4], 0

    mov eax, PAGE_TABLE_PML4
    mov cr3, eax
    mov eax, cr4
    or eax, 0x00000020             ; CR4.PAE
    mov cr4, eax

    mov ecx, 0xC0000080            ; IA32_EFER
    rdmsr
    or eax, 0x00000100             ; EFER.LME
    wrmsr

    mov eax, cr0
    or eax, 0x80000000             ; CR0.PG
    mov cr0, eax

    jmp 0x18:long_mode_entry

[BITS 64]
long_mode_entry:
    mov rsp, 0x90000
    mov eax, [BOOTREC_BUFFER_OFF + 40]
    add eax, BOOT_STAGE_ADDR
    call rax

    mov eax, [BOOTREC_BUFFER_OFF + 44]
    add eax, KERNEL_STAGE_ADDR
    call rax

.hang:
    jmp .hang

[BITS 16]
; MBR sector layout: boot code (0..445), partition table (446..509), signature.
times 446 - ($ - $$) db 0
partition_table:
times 64 db 0
dw 0xAA55
