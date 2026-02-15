; XDV OS boot sector stage-0 (MBR, partition-aware).
; Reads the xdvfs boot record from the boot partition and loads kernel
; using metadata fields (relative LBA + sector count).
; This stage is transport only; boot policy remains defined in Dust.

[ORG 0x7C00]
[BITS 16]

BOOTREC_BUFFER_SEG equ 0x0000
BOOTREC_BUFFER_OFF equ 0x0600
KERNEL_LOAD_SEG equ 0x1000
KERNEL_LOAD_OFF equ 0x0000

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

    ; Require INT13 extensions for LBA reads.
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive]
    int 0x13
    jc disk_error
    cmp bx, 0xAA55
    jne disk_error
    test cx, 0x0001
    jz disk_error

    ; Prefer active partition; fallback to partition entry 0.
    mov si, partition_table
    mov cx, 4
.find_active:
    cmp byte [si], 0x80
    je .active_found
    add si, 16
    loop .find_active
    mov si, partition_table

.active_found:
    ; Partition start LBA is +8 in a 16-byte MBR partition entry.
    mov eax, [si + 8]
    test eax, eax
    jz disk_error
    mov [partition_start_lba], eax
    mov dword [dap_lba_high], 0

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

    ; Validate boot record signature and sector trailer.
    mov si, BOOTREC_BUFFER_OFF
    cmp dword [si + 0], 0x46564458   ; "XDVF"
    jne disk_error
    cmp dword [si + 4], 0x30524253   ; "SBR0"
    jne disk_error
    cmp word [si + 510], 0xAA55
    jne disk_error

    ; boot record offsets:
    ; +16 kernel relative LBA (u32)
    ; +20 kernel sectors (u32, low 16 used by INT13h packet)
    mov eax, [si + 16]
    add eax, [partition_start_lba]
    mov [dap_lba_low], eax
    mov ax, [si + 20]
    test ax, ax
    jz disk_error
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
    mov si, err_msg
    call print16
    jmp $

print16:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    mov bh, 0x00
    mov bl, 0x07
    int 0x10
    jmp print16
.done:
    ret

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

err_msg db 'XDVBOOT ERR', 0

; Protected mode descriptors.
gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF   ; 0x08 code segment
    dq 0x00CF92000000FFFF   ; 0x10 data segment
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
    jmp 0x08:0x10000

[BITS 16]
; MBR sector layout: boot code (0..445), partition table (446..509), signature.
times 446 - ($ - $$) db 0
partition_table:
times 64 db 0
dw 0xAA55
