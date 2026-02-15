; XDV OS boot sector (MBR style).
; Loads kernel from sector 2, enters protected mode, jumps to 0x10000.

[ORG 0x7C00]
[BITS 16]

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

    ; Reset disk.
    xor ah, ah
    int 0x13
    jc disk_error

    ; Read kernel from CHS 0/0/3 into 0x1000:0000 (physical 0x10000).
    ; build.{bat,sh} writes kernel.bin at LBA 2 (offset 1024), which is sector 3 in CHS.
    ; 8 sectors is enough for current kernel.bin and stays in track.
    mov ax, 0x1000
    mov es, ax
    xor bx, bx
    mov ah, 0x02
    mov al, 0x08
    mov ch, 0x00
    mov cl, 0x03
    mov dh, 0x00
    mov dl, [boot_drive]
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
err_msg db 'BOOTERR', 0

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
times 64 db 0
dw 0xAA55
