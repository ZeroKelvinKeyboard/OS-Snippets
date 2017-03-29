
; -----------------------------------------------------
; os_mouse_setup --- setup the mouse driver
; IN/OUT: none

os_mouse_setup:
	API_START
	API_SEGMENTS

	int 0x11
	test al, 0x04
	jz .no_mouse

	mov ah, 0xC2				; BIOS Mouse Services
	mov al, 0x05				; Initialise Mouse
	mov bh, 3				; Packet Size - 3 bytes
	int 0x15
	jc .no_mouse

	mov ah, 0xC2				; BIOS Mouse Services
	mov al, 0x03				; Set Mouse Resolution
	mov bh, 3				; Eight Counts Per Millimeter
	int 0x15
	jc .no_mouse

	mov ah, 0xC2				; BIOS Mouse Services
	mov al, 0x02				; Set Mouse Sampling Rate
	mov bh, 6				; 200 Updates Per Second
	int 0x15
	jc .no_mouse

	mov ah, 0xC2				; BIOS Mouse Services
	mov al, 0x07				; Setup Mouse Handler
	mov bx, mouse_handler			; Address of the Function
	int 0x15
	jc .no_mouse

	mov byte [mouse_prop.exist], 1
	API_END

.no_mouse:
	mov byte [mouse_prop.exist], 0
	API_END
	
	

	
; ----------------------------------------
; TachyonOS Mouse Driver
	
mouse_handler:
	pusha
	push ds

	mov ax, gs
	mov ds, ax
	mov bp, sp

	; Grab the mouse packet provided by BIOS.
	mov al, [bp + 22 + 6]		; Mouse Flags
	mov cl, [bp + 22 + 4]		; Mouse Delta X
	mov dl, [bp + 22 + 2]		; Mouse Delta Y

	; Discard packet if X or Y overflow flags are set.
	test al, 0xC0
	jnz .discard_packet

	; Process the mouse flags by shifting them out and into the carry flag.

	; Set the upper half of the Y value according to the Y sign flag.
	shl al, 3
	sbb dh, dh

	; Same for the X value.
	shl al, 1
	sbb ch, ch

	; Preserve the remaining flags for now.
	mov ah, al

	; Has the middle mouse button been pressed/released? Update the info.
	shl al, 2
	setc cl
	cmp cl, [mouse_prop.middle_btn]
	jne .update_mouse

	; Maybe the right mouse button?
	shl al, 1
	setc cl
	cmp cl, [mouse_prog.right_btn]
	jne .update_mouse

	; Or the left?
	shl al, 1
	setc cl
	cmp cl, [mouse_prop.left_btn]
	jne .update_mouse

	; Is there any horizontal movement?
	cmp cx, 0
	jne .update_mouse

	; What about vertical?
	cmp dx, 0
	jne .update_mouse

	; Nothing has changed, ignore the packet.
	jmp .discard_packet

.update_mouse:
	; Okay, so something has definitely happen that needs to be recorded.

	; Recall the flags from before.
	mov al, ah
	
	; Process the remaining flags and update the button states.
	shl al, 2
	setc byte [mouse_prop.middle_btn]

	shl al, 1
	setc byte [mouse_prop.right_btn]

	shl al, 1
	setc byte [mouse_prop.left_btn]

	; Add the delta to the existing position to get the raw position.
	add cx, [mouse_prop.raw_x]
	add dx, [mouse_prop.raw_y]

	; Correct it if it's out of range.
	call mouse_bounds

	; Update the raw position
	mov [mouse_prop.raw_x], cx
	mov [mouse_prop.raw_y], dx

	; Get the scaled position the API returns to programs.
	call mouse_scaled_position

	; Save the new scaled position.
	mov [mouse_prop.x], cx
	mov [mouse_prop.y], dx

	; Tell the API the mouse state has been updated. It could be waiting.
	mov byte [mouse_prop.updated], 1

	pop ds
	popa
	retf

.discard_packet:
	pop ds
	popa
	ret


; -----------------------------------------------------
; mouse_raw_position --- convert scaled to raw position
; IN: CX = Scaled Mouse X, DX = Scaled Mouse Y
; OUT: CX = Raw Mouse X, DX = Raw Mouse Y

mouse_raw_position:
	push ax
	push bx

	mov ax, cx
	mov cl, [gs:mouse_prop.x_scale]	
	sal ax, cl
	mov bx, ax

	mov ax, dx
	mov cl, [gs:mouse_prop.y_scale]
	sal ax, cl

	mov cx, bx
	mov dx, ax
	
	pop bx
	pop ax
	ret


; -----------------------------------------------------
; mouse_scaled_position - convert raw position to scaled
; IN: CX = Raw Mouse X, DX = Raw Mouse Y
; OUT: CX = Scaled Mouse X, DX = Scaled Mouse Y

mouse_scaled_position:
	push ax
	push bx

	mov ax, cx
	mov cl, [gs:mouse_prop.x_scale]
	sar ax, cl

	mov bx, ax

	mov bx, dx
	mov cl, [gs:mouse_prop.y_scale]
	sar bx, cl

	mov cx, bx
	mov dx, ax

	pop bx
	pop ax
	ret


; --------------------------------------------------
; mouse_bounds
; IN: CX = Raw Mouse X, DX = Raw Mouse Y
; OUT: CX = Corrected Mouse X, DX = Correct Mouse Y

mouse_bounds:
	push ax

	mov ax, cx
	cmp ax, [gs:mouse_prop.min_x]
	jl .x_underflow

.x_min_okay:
	cmp ax, [gs:mouse_prop.max_x]
	jg .x_overflow

.x_max_okay:
	xchg ax, dx

	mov cl, [gs:mouse_prop.y_scale]
	sal ax, cl

	cmp ax, [gs:mouse_prop.min_y]
	jl .y_underflow

.y_min_okay:
	cmp ax, [gs:mouse_prop.max_y]
	jg .y_overflow

.y_max_okay:
	mov cx, ax
	xchg cx, dx

	pop ax
	ret

.x_underflow:
	mov ax, [gs:mouse_prop.min_x]
	jmp .x_min_okay

.x_overflow:
	mov ax, [gs:mouse_prop.max_x]
	jmp .x_max_okay

.y_underflow:
	mov ax, [gs:mouse_prop.min_y]
	jmp .y_min_okay

.y_overflow:
	mov ax, [gs:mouse_prop.max_y]
	jmp .y_max_okay


; --------------------------------------------------
; os_mouse_locate -- return the mouse co-ordinents
; IN: none
; OUT: CX = Mouse X, DX = Mouse Y

os_mouse_locate:
	mov cx, [gs:mouse_prop.x]
	mov dx, [gs:mouse_prop.y]
	jmp os_return


; --------------------------------------------------
; os_mouse_move -- set the mouse co-ordinents
; IN: CX = Mouse X, DX = Mouse Y
; OUT: none

os_mouse_move:
	pusha

	; First convert the program's scaled position to a raw position.
	call mouse_raw_position

	; Correct it if it's out of bounds.
	call mouse_bounds

	; Save the corrected raw position.
	mov [gs:mouse_prop.raw_x], cx
	mov [gs:mouse_prop.raw_y], dx

	; Now store the corrosponding saved position.
	call mouse_scaled_position

	mov [gs:mouse_prop.x], cx
	mov [gs:mouse_prop.y], dx

	popa
	jmp os_return


; os_mouse_wait

os_mouse_wait:
	pusha

	; Set the updated property to zero.
	mov byte [gs:mouse_prop.updated], 0

.loop:
	; Now wait for the drivers to change it.
	cmp byte [gs:mouse_prop.updated], 1
	je .done

	sti
	hlt
	jmp .loop

.done:
	popa
	jmp os_return


; os_mouse_leftclick

os_mouse_leftclick:
	cmp byte [gs:mouse_prop.left_btn], 1
	je .is_clicked

	clc
	jmp os_return

.is_clicked:
	stc
	jmp os_return
	
	
; os_mouse_rightclick

os_mouse_rightclick:
	cmp byte [gs:mouse_prop.right_btn], 1
	je .is_clicked

	clc
	jmp os_return

.is_clicked:
	stc
	jmp os_return


; os_mouse_middleclick

os_mouse_middleclick:
	cmp byte [gs:mouse_prop.middle_btn], 1
	je .is_clicked

	clc
	jmp os_return

.is_clicked:
	stc
	jmp os_return


os_mouse_anyclick:
	cmp byte [gs:mouse_prop.left_btn], 1
	je .is_clicked

	cmp byte [gs:mouse_prop.right_btn], 1
	je .is_clicked

	cmp byte [gs:mouse_prop.middle_btn], 1
	je .is_clicked

	clc
	jmp os_return

.is_clicked:
	stc
	jmp os_return


; os_mouse_range

os_mouse_range:
	pusha

	call mouse_scaled_position	

	mov [gs:mouse_prop.max_x], cx
	mov [gs:mouse_prop.max_y], dx

	mov cx, ax
	mov dx, ax

	call mouse_scaled_position

	mov [gs:mouse_prop.min_x], cx
	mov [gs:mouse_prop.min_y], dx

	popa
	jmp os_return



; os_mouse_scale

; os_mouse_select







; TODO: Implement the rest of the Mouse API.
; Make show/hide cursor internal rather than API
; Replace with os_mouse_select 
; A free selection command.
; Returns position (X = 0-79, Y=0-24) and button number or keyboard key.

	


mouse_prop:
	.exists				db 0	; A mouse is installed
	.updated			db 0	; Set on any mouse action
	.raw_x				dw 0	; Unscaled mouse position
	.raw_y				dw 0
	.x				dw 0	; Scaled mouse position
	.y				dw 0
	.x_scale			db 0	; Scale factor
	.y_scale			db 0
	.min_x				dw 0	; Minimum Position (unscaled)
	.min_y				dw 0
	.max_x				dw 0	; Maximum Position (unscaled)
	.max_y				dw 0
	.left_btn			db 0	; Button states (0/1 = up/down)
	.middle_btn			db 0
	.right_btn			db 0


	
	


