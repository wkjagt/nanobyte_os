org 0x7C00
bits 16

%define BYTES_PER_SECTOR    512
%define FAT_COUNT           2
%define SECTORS_PER_FAT     9
%define RESERVED_SECTORS    1
%define ROOT_DIR_LBA        RESERVED_SECTORS + FAT_COUNT * SECTORS_PER_FAT  ; 1 + 2 * 9 = 19
%define DIR_ENTRIES_COUNT   0E0h                                            ; 224
%define ROOT_DIR_SECTORS    (DIR_ENTRIES_COUNT * 32) / BYTES_PER_SECTOR     ; (224 * 32) / 512 = 14
%define FIRST_CLUSTER       ROOT_DIR_LBA + ROOT_DIR_SECTORS - 2             ; 19 + 14 - 2 = 31 (2 reserved)

%define ENDL                0x0D, 0x0A

;
; FAT12 header
; 
jmp short start
nop

bdb_oem:                    db 'MSWIN4.1'           ; 8 bytes
bdb_bytes_per_sector:       dw BYTES_PER_SECTOR
bdb_sectors_per_cluster:    db 1
bdb_reserved_sectors:       dw RESERVED_SECTORS
bdb_fat_count:              db FAT_COUNT
bdb_dir_entries_count:      dw DIR_ENTRIES_COUNT
bdb_total_sectors:          dw 2880                 ; 2880 * 512 = 1.44MB
bdb_media_descriptor_type:  db 0F0h                 ; F0 = 3.5" floppy disk
bdb_sectors_per_fat:        dw SECTORS_PER_FAT
bdb_sectors_per_track:      dw 18
bdb_heads:                  dw 2
bdb_hidden_sectors:         dd 0
bdb_large_sector_count:     dd 0

; extended boot record
ebr_drive_number:           db 0                    ; 0x00 floppy, 0x80 hdd, useless
                            db 0                    ; reserved
ebr_signature:              db 29h
ebr_volume_id:              db 12h, 34h, 56h, 78h   ; serial number, value doesn't matter
ebr_volume_label:           db 'NANOBYTE OS'        ; 11 bytes, padded with spaces
ebr_system_id:              db 'FAT12   '           ; 8 bytes

start:
    ; setup data segments
    mov ax, 0           ; can't set ds/es directly
    mov ds, ax          ; data segment
    mov es, ax          ; extra segment
    
    ; setup stack
    mov ss, ax          ; reset stack
    mov sp, 0x7C00      ; stack grows downwards from where we are loaded in memory

    ; some BIOSes might start us at 07C0:0000 instead of 0000:7C00, make sure we are in the
    ; expected location
    push es
    push word .after
    retf

.after:

    ; read something from floppy disk
    ; BIOS has set the active drive in DL. Store it in ebr_drive_number
    ; in the copy of the boot sector
    mov [ebr_drive_number], dl

;================================================================================
; read root directory
;================================================================================
    mov cl, ROOT_DIR_SECTORS
    mov ax, ROOT_DIR_LBA
    mov dl, [ebr_drive_number]          ; dl = drive number (we saved it previously)
    mov bx, buffer                      ; es:bx = buffer
    call disk_read

;================================================================================
; Search stage 2 file entry in the root directory
;================================================================================
    xor bx, bx                          ; use as entry counter in the loop
    mov di, buffer

.search_kernel:
    mov si, file_stage2_bin             ; point to the file name of the stage 2 binary
    mov cx, 11                          ; used by repe as a counter
    push di                             ; keep di to save start position of entry
    repe cmpsb                          ; compare strings in ES:DI and DS:SI. repe = repeat while equal
    pop di
    je .found_kernel                    ; if strings are equal, DI contains start of entry

    add di, 32                          ; if not, skip to next entry, which is 32 bytes further
    inc bx
    cmp bx, [bdb_dir_entries_count]
    jl .search_kernel

    ; kernel not found
    jmp kernel_not_found_error

.found_kernel:

;================================================================================
; Load stage 2 into memory, starting at the first cluster, which the
; direcory entry found (in DI) above points to.
;================================================================================

    ; di should have the address to the entry
    mov ax, [di + 26]                   ; first logical cluster field (offset 26 within the dir entry)
    mov [stage2_cluster], ax

    ; load FAT from disk into buffer
    mov ax, [bdb_reserved_sectors]      ; LBA of the FAT starts rights after the reserved sectors
    mov bx, buffer                      ; the buffer to load the FAT into
    mov cl, [bdb_sectors_per_fat]       ; the number of sectors to read (the size of the FAT in sectors)
    mov dl, [ebr_drive_number]          ; the drive to read from
    call disk_read

    ; read kernel and process FAT chain
    ; ES: segment
    ; BX: OFFSET (used by disk_read)
    mov bx, STAGE2_LOAD_SEGMENT
    mov es, bx
    mov bx, STAGE2_LOAD_OFFSET

.load_kernel_loop:
    mov ax, [stage2_cluster]
    add ax, FIRST_CLUSTER
    mov cl, 1                           ; number of sectors to read
    mov dl, [ebr_drive_number]          ; from which drive to read
    call disk_read

    add bx, [bdb_bytes_per_sector]      ; advance the pointer to the disk_read buffer

    ; compute location of next cluster
    ; multiply the index of the next cluster by 3, then devide by 2, because each FAT entry is 12 bits
    ; (1.5 bytes) wide.
    mov ax, [stage2_cluster]
    mov cx, 3
    mul cx
    mov cx, 2
    div cx                              ; ax = index of entry in FAT, dx = cluster mod 2

    mov si, buffer                      ; the buffer pointer points to the start of the FAT
    add si, ax                          ; add the result of the multiplication above
    mov ax, [si]                        ; read entry from FAT table at index ax

    or dx, dx                           ; look at the remainder of the division
    jz .even                            ; if it's zero, the result is even

.odd:
    shr ax, 4                           ; for odd clusters, the value is in the top 12 bits
    jmp .next_cluster_after

.even:
    and ax, 0x0FFF                      ; for even clusters, the value is in the bottom 12 bits

.next_cluster_after:
    cmp ax, 0x0FF8                      ; end of chain
    jae .jump_to_next_stage

    mov [stage2_cluster], ax            ; ax contains the next cluster index
    jmp .load_kernel_loop


;================================================================================
; The next stage is loaded into memory. 
;================================================================================

.jump_to_next_stage:
    mov dl, [ebr_drive_number]          ; boot device in dl
    mov ax, STAGE2_LOAD_SEGMENT         ; set segment registers
    mov ds, ax
    mov es, ax

    jmp STAGE2_LOAD_SEGMENT:STAGE2_LOAD_OFFSET

    jmp wait_key_and_reboot             ; should never happen

    cli                                 ; disable interrupts, this way CPU can't get out of "halt" state
    hlt


;================================================================================
; Error handlers
;================================================================================
floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key_and_reboot

kernel_not_found_error:
    mov si, msg_stage2_not_found
    call puts

wait_key_and_reboot:
    mov ah, 0
    int 16h                     ; wait for keypress
    jmp 0FFFFh:0                ; jump to beginning of BIOS, should reboot

.halt:
    cli                         ; disable interrupts, this way CPU can't get out of "halt" state
    hlt


;
; Prints a string to the screen
; Params:
;   - ds:si points to string
;
puts:
    ; save registers we will modify
    push si
    push ax
    push bx

.loop:
    lodsb               ; loads next character in al
    or al, al           ; verify if next character is null?
    jz .done

    mov ah, 0x0E        ; call bios interrupt
    mov bh, 0           ; set page number to 0
    int 0x10

    jmp .loop

.done:
    pop bx
    pop ax
    pop si    
    ret

;
; Disk routines
;

;
; Converts an LBA address to a CHS address
; Parameters:
;   - ax: LBA address
; Returns:
;   - cx [bits 0-5]: sector number
;   - cx [bits 6-15]: cylinder
;   - dh: head
;

lba_to_chs:

    push ax
    push dx

    xor dx, dx                          ; dx = 0
    div word [bdb_sectors_per_track]    ; ax = LBA / SectorsPerTrack
                                        ; dx = LBA % SectorsPerTrack

    inc dx                              ; dx = (LBA % SectorsPerTrack + 1) = sector
    mov cx, dx                          ; cx = sector

    xor dx, dx                          ; dx = 0
    div word [bdb_heads]                ; ax = (LBA / SectorsPerTrack) / Heads = cylinder
                                        ; dx = (LBA / SectorsPerTrack) % Heads = head
    mov dh, dl                          ; dh = head
    mov ch, al                          ; ch = cylinder (lower 8 bits)
    shl ah, 6
    or cl, ah                           ; put upper 2 bits of cylinder in CL

    pop ax
    mov dl, al                          ; restore DL
    pop ax
    ret


;
; Reads sectors from a disk
; Parameters:
;   - ax: LBA address
;   - cl: number of sectors to read (up to 128)
;   - dl: drive number
;   - es:bx: memory address where to store read data
;
disk_read:

    push ax                             ; save registers we will modify
    push bx
    push cx
    push dx
    push di

    push cx                             ; temporarily save CL (number of sectors to read)
    call lba_to_chs                     ; compute CHS
    pop ax                              ; AL = number of sectors to read
    
    mov ah, 02h
    mov di, 3                           ; retry count

.retry:
    pusha                               ; save all registers, we don't know what bios modifies
    stc                                 ; set carry flag, some BIOS'es don't set it
    int 13h                             ; carry flag cleared = success
    jnc .done                           ; jump if carry not set

    ; read failed
    popa
    call disk_reset

    dec di
    test di, di
    jnz .retry

.fail:
    ; all attempts are exhausted
    jmp floppy_error

.done:
    popa

    pop di
    pop dx
    pop cx
    pop bx
    pop ax                             ; restore registers modified
    ret


;
; Resets disk controller
; Parameters:
;   dl: drive number
;
disk_reset:
    pusha
    mov ah, 0
    stc
    int 13h
    jc floppy_error
    popa
    ret


msg_read_failed:        db 'Read from disk failed!', ENDL, 0
msg_stage2_not_found:   db 'STAGE2.BIN file not found!', ENDL, 0
file_stage2_bin:        db 'STAGE2  BIN'
stage2_cluster:         dw 0

STAGE2_LOAD_SEGMENT     equ 0x2000
STAGE2_LOAD_OFFSET      equ 0


times 510-($-$$) db 0
dw 0AA55h

buffer:
