bits 16

section _ENTRY class=CODE       ; the section that the linker puts at the start of the binary (see linker.lnk)

extern _cstart_                 ; this is cstart_ in main.c
global entry                    ; used by linker.lnk

entry:
    cli                         ; disable interrupts
    ; setup stack
    mov ax, ds                  ; set stack segment same as data segment
    mov ss, ax
    mov sp, 0                   ; top of stack = 0
    mov bp, sp                  ; stack base pointer
    sti                         ; enable interrupts

    ; expect boot drive in dl, send it as argument to cstart function
    xor dh, dh
    push dx
    call _cstart_

    cli
    hlt
