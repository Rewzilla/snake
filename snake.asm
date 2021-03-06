;
; "Snake" Game implementation
; by Andrew Kramer
;
; If your tab width isn't 4, you're gunna have a bad time
;

; file descriptors
%define STDIN			0
%define STDOUT			1

; syscall definitions
%define SYS_EXIT		0x01
%define SYS_FORK		0x02
%define SYS_READ		0x03
%define SYS_WRITE		0x04
%define SYS_OPEN		0x05
%define SYS_CLOSE		0x06
%define SYS_WAITPID		0x07
%define SYS_EXECVE		0x0b
%define SYS_IOCTL		0x36
%define SYS_FCNTL		0x37
%define SYS_NANOSLEEP	0xa2

; fnctl values
%define F_GETFL 3
%define F_SETFL 4
%define O_NONBLOCK 2048

; the file that stores the initial state
%define BOARD_FILE 'board.txt'

; how to represent everything
%define EMPTY_CHAR			' '
%define WALL_CHAR			'#'
%define FRUIT_CHAR			'Q'
%define SNAKE_UP_CHAR		'A'
%define SNAKE_DOWN_CHAR		'V'
%define SNAKE_LEFT_CHAR		'<'
%define SNAKE_RIGHT_CHAR	'>'

; the size of the game screen in characters
%define HEIGHT	20
%define WIDTH	40

; the snake starting position.
; top left is considered (0,0)
%define HEAD_STARTX 2
%define HEAD_STARTY 2
%define TAIL_STARTX 2
%define TAIL_STARTY 2

; how should the snake initially move
%define STARTDIR DOWN_CHAR

; these keys do things
%define EXITCHAR	'x'
%define UP_CHAR		'w'
%define LEFT_CHAR	'a'
%define DOWN_CHAR	's'
%define RIGHT_CHAR	'd'

; how frequently we check for input
; 1,000,000,000 = 1 second
%define TICK	200000000

segment .data

	; used to fopen() the board file defined above
	_board_file			db BOARD_FILE,0

	; used to implement rand()
	_dev_urandom		db "/dev/urandom",0

	; used to set/unset raw mode
	_bin_sh				db "/bin/sh",0
	_c					db "-c",0
	_raw_mode_on		db "stty raw -echo",0
	_raw_mode_off		db "stty -raw echo",0

	; escape sequence to clear the screen
	_clear_screen		db 27,"c",0

segment .bss

	; this array stores the current rendered gameboard (HxW)
	board	resb	(HEIGHT * WIDTH)

	; these variables store the current player position
	head_xpos	resd	1
	head_ypos	resd	1
	tail_xpos	resd	1
	tail_ypos	resd	1

	last_input	resb	1

segment .text
	global	_start

; === FUNCTION ===
_start:

	; turn on raw mode
	call	raw_mode_on

	; turn off stdin buffering
	call	stdin_blocking_off

	; setup the game state (board, position, etc)
	call	init_game_state

	; run the game
	call	run_game_loop

	; turn on stdin buffering
	call	stdin_blocking_on

	; turn off raw mode
	call	raw_mode_off

	mov		eax, SYS_EXIT
	mov		ebx, 0
	int		0x80

; === FUNCTION ===
stdin_blocking_on:

	push	ebp
	mov		ebp, esp

	sub		esp, 4

	; get current stdin flags
	; flags = fcntl(stdin, F_GETFL, 0)
	mov		eax, SYS_FCNTL
	mov		ebx, STDIN
	mov		ecx, F_GETFL
	mov		edx, 0
	int		0x80
	mov		DWORD [ebp - 4], eax

	; set non-blocking mode on stdin
	; fcntl(stdin, F_SETFL, flags | O_NONBLOCK)
	xor		DWORD [ebp - 4], O_NONBLOCK
	mov		eax, SYS_FCNTL
	mov		ebx, STDIN
	mov		ecx, F_SETFL
	mov		edx, DWORD [ebp - 4]
	int		0x80

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
stdin_blocking_off:

	push	ebp
	mov		ebp, esp

	; get current stdin flags
	; flags = fcntl(stdin, F_GETFL, 0)
	mov		eax, SYS_FCNTL
	mov		ebx, STDIN
	mov		ecx, F_GETFL
	mov		edx, 0
	int		0x80
	mov		DWORD [ebp - 4], eax

	; set non-blocking mode on stdin
	; fcntl(stdin, F_SETFL, flags | O_NONBLOCK)
	or		DWORD [ebp - 4], O_NONBLOCK
	mov		eax, SYS_FCNTL
	mov		ebx, STDIN
	mov		ecx, F_SETFL
	mov		edx, DWORD [ebp - 4]
	int		0x80

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
raw_mode_on:

	push	ebp
	mov		ebp, esp

	push	_raw_mode_on
	call	system
	add		esp, 4

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
raw_mode_off:

	push	ebp
	mov		ebp, esp

	push	_raw_mode_off
	call	system
	add		esp, 4

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
init_game_state:

	push	ebp
	mov		ebp, esp

	; set the player at the proper start position
	mov		DWORD [head_xpos], HEAD_STARTX
	mov		DWORD [head_ypos], HEAD_STARTY
	mov		DWORD [tail_xpos], TAIL_STARTX
	mov		DWORD [tail_ypos], TAIL_STARTY

	; start the snake moving in the initial direction
	mov		BYTE [last_input], STARTDIR

	; read the game board file into the global variable
	call	init_board

	; add the initial snake to the board
	call	init_snake

	; create the first fruit somewhere
	call	create_random_fruit

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
run_game_loop:

	push	ebp
	mov		ebp, esp

	; integer to indicate if we found fruit
	; pointer for saving board position
	sub		esp, 8

	; the game happens in this loop
	game_loop:

		; slow the game down just a tad
		push	TICK
		call	usleep
		add		esp, 4

		; draw the game board
		call	render

		; maybe change the direction
		call	getchar
		cmp		eax, -1
		je		no_char
			cmp		al, EXITCHAR
			je		game_loop_end
			cmp		al, UP_CHAR
			je		maybe_up
			cmp		al, DOWN_CHAR
			je		maybe_down
			cmp		al, LEFT_CHAR
			je		maybe_left
			cmp		al, RIGHT_CHAR
			je		maybe_right
			jmp		no_char
			maybe_up:
				cmp		BYTE [last_input], DOWN_CHAR
				je		no_char
				jne		valid_move
			maybe_down:
				cmp		BYTE [last_input], UP_CHAR
				je		no_char
				jne		valid_move
			maybe_left:
				cmp		BYTE [last_input], RIGHT_CHAR
				je		no_char
				jne		valid_move
			maybe_right:
				cmp		BYTE [last_input], LEFT_CHAR
				je		no_char
				jne		valid_move
			valid_move:
				mov		BYTE [last_input], al
		no_char:

		; get the current head buffer character
		mov		eax, WIDTH
		mul		DWORD [head_ypos]
		add		eax, [head_xpos]
		lea		eax, [board + eax]

		; Update the snake head character
		cmp		BYTE [last_input], UP_CHAR
		je 		head_up
		cmp		BYTE [last_input], LEFT_CHAR
		je		head_left
		cmp		BYTE [last_input], DOWN_CHAR
		je		head_down
		cmp		BYTE [last_input], RIGHT_CHAR
		je		head_right
		head_up:
			mov		BYTE [eax], SNAKE_UP_CHAR
			dec		DWORD [head_ypos]
			jmp		head_end
		head_left:
			mov		BYTE [eax], SNAKE_LEFT_CHAR
			dec		DWORD [head_xpos]
			jmp		head_end
		head_down:
			mov		BYTE [eax], SNAKE_DOWN_CHAR
			inc		DWORD [head_ypos]
			jmp		head_end
		head_right:
			mov		BYTE [eax], SNAKE_RIGHT_CHAR
			inc		DWORD [head_xpos]
		head_end:

		; get the new head buffer character
		mov		eax, WIDTH
		mul		DWORD [head_ypos]
		add		eax, [head_xpos]
		lea		eax, [board + eax]

		; check if we hit a wall
		cmp		BYTE [eax], WALL_CHAR
		je		game_loop_end

		; check if we hit ourselves
		cmp		BYTE [eax], SNAKE_UP_CHAR
		je		game_loop_end
		cmp		BYTE [eax], SNAKE_DOWN_CHAR
		je		game_loop_end
		cmp		BYTE [eax], SNAKE_LEFT_CHAR
		je		game_loop_end
		cmp		BYTE [eax], SNAKE_RIGHT_CHAR
		je		game_loop_end

		; check if we found a fruit (indicate with ebx)
		mov		DWORD [ebp - 4], 0
		cmp		BYTE [eax], FRUIT_CHAR
		jne		no_fruit
			mov		DWORD [ebp - 8], eax	; save this
			call	create_random_fruit
			mov		eax, DWORD [ebp - 8]	; restore it
			mov		DWORD [ebp - 4], 1
		no_fruit:

		cmp		BYTE [last_input], UP_CHAR
		je		new_head_up
		cmp		BYTE [last_input], DOWN_CHAR
		je		new_head_down
		cmp		BYTE [last_input], LEFT_CHAR
		je		new_head_left
		cmp		BYTE [last_input], RIGHT_CHAR
		je		new_head_right
		new_head_up:
			mov		BYTE [eax], SNAKE_UP_CHAR
			jmp		new_head_end
		new_head_down:
			mov		BYTE [eax], SNAKE_DOWN_CHAR
			jmp		new_head_end
		new_head_left:
			mov		BYTE [eax], SNAKE_LEFT_CHAR
			jmp		new_head_end
		new_head_right:
			mov		BYTE [eax], SNAKE_RIGHT_CHAR
		new_head_end:

		; if we hit a fruit, don't delete the current tail end
		; this gives the effect of "growing"
		cmp		DWORD [ebp - 4], 1
		je		game_loop

		; get the tail buffer character
		mov		eax, WIDTH
		mul		DWORD [tail_ypos]
		add		eax, [tail_xpos]
		lea		eax, [board + eax]

		; save current pointer so we can clear the square
		; once we move the tail xpos/ypos
		mov		ebx, eax

		cmp		BYTE [eax], SNAKE_UP_CHAR
		je		tail_up
		cmp		BYTE [eax], SNAKE_DOWN_CHAR
		je		tail_down
		cmp		BYTE [eax], SNAKE_LEFT_CHAR
		je		tail_left
		cmp		BYTE [eax], SNAKE_RIGHT_CHAR
		je		tail_right
		tail_up:
			dec		DWORD [tail_ypos]
			jmp		tail_end
		tail_down:
			inc		DWORD [tail_ypos]
			jmp		tail_end
		tail_left:
			dec		DWORD [tail_xpos]
			jmp		tail_end
		tail_right:
			inc		DWORD [tail_xpos]
		tail_end:
		mov		BYTE [ebx], EMPTY_CHAR

	jmp		game_loop
	game_loop_end:

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
init_board:

	push	ebp
	mov		ebp, esp

	; counters y, x
	sub		esp, 8

	; loop for each row
	mov		DWORD [ebp - 4], 0
	outer_loop_top:
	cmp		DWORD [ebp - 4], HEIGHT
	jge		outer_loop_end

		; loop for each column
		mov		DWORD [ebp - 8], 0
		inner_loop_top:
		cmp		DWORD [ebp - 8], WIDTH
		jge		inner_loop_end

			; find the x/y offset
			mov		eax, WIDTH
			mov		ebx, DWORD [ebp - 4]
			mul		ebx
			add		eax, DWORD [ebp - 8]

			; if we should be printing a wall
			cmp		DWORD [ebp - 4], 0
			je		outer
			cmp		DWORD [ebp - 8], 0
			je		outer
			cmp		DWORD [ebp - 4], (HEIGHT - 1)
			je		outer
			cmp		DWORD [ebp - 8], (WIDTH - 1)
			je		outer

				; print the middle of the board
				mov		BYTE [board + eax], EMPTY_CHAR

			jmp		ifend
			outer:

				; print a wall
				mov		BYTE [board + eax], WALL_CHAR

			ifend:

		inc		DWORD [ebp - 8]
		jmp		inner_loop_top
		inner_loop_end:

	inc		DWORD [ebp - 4]
	jmp		outer_loop_top
	outer_loop_end:

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
init_snake:

	push	ebp
	mov		ebp, esp

	; find starting x/y offset
	mov		eax, WIDTH
	mov		ebx, HEAD_STARTY
	mul		ebx
	add		eax, HEAD_STARTX

	; drop the snake head at that location
	mov		BYTE [board + eax], STARTDIR

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
render:

	push	ebp
	mov		ebp, esp

	; two ints, for two loop counters
	; ebp-4, ebp-8
	sub		esp, 8

	; clear the screen
	push	_clear_screen
	call	puts
	add		esp, 4

	; outside loop by height
	; i.e. for(c=0; c<height; c++)
	mov		DWORD [ebp - 4], 0
	y_loop_start:
	cmp		DWORD [ebp - 4], HEIGHT
	je		y_loop_end

		; inside loop by width
		; i.e. for(c=0; c<width; c++)
		mov		DWORD [ebp - 8], 0
		x_loop_start:
		cmp		DWORD [ebp - 8], WIDTH
		je 		x_loop_end

			mov		eax, [ebp - 4]
			mov		ebx, WIDTH
			mul		ebx
			add		eax, [ebp - 8]
			mov		ebx, 0
			mov		bl, BYTE [board + eax]
			push	ebx
			call	putchar
			add		esp, 4

		inc		DWORD [ebp - 8]
		jmp		x_loop_start
		x_loop_end:

		; write a carriage return (necessary when in raw mode)
		push	0x0d
		call 	putchar
		add		esp, 4

		; write a newline
		push	0x0a
		call	putchar
		add		esp, 4

	inc		DWORD [ebp - 4]
	jmp		y_loop_start
	y_loop_end:

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
create_random_fruit:

	push	ebp
	mov		ebp, esp

	; store random width/height
	sub		esp, 4

	try_to_place_fruit:

	; get a random number between 1->(width-1)
	call	rand
	mov		edx, 0
	mov		ebx, WIDTH
	sub		ebx, 2
	div		ebx
	mov		DWORD [ebp - 4], edx
	add		DWORD [ebp - 4], 1

	; get a random number between 1->(height-1)
	call	rand
	mov		edx, 0
	mov		ebx, HEIGHT
	sub		ebx, 2
	div		ebx
	mov		DWORD [ebp - 8], edx
	add		DWORD [ebp - 8], 1

	; (W * y) + x
	mov		eax, DWORD [ebp - 8]
	mov		ebx, WIDTH
	mul		ebx
	add		eax, DWORD [ebp - 4]

	; if we landed on top of the snake, try again
	cmp		BYTE [board + eax], EMPTY_CHAR
	jne		try_to_place_fruit

	; put fruit there
	mov		BYTE [board + eax], FRUIT_CHAR

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
rand:

	push	ebp
	mov		ebp, esp

	sub		esp, 8

	mov		eax, SYS_OPEN
	mov		ebx, _dev_urandom
	mov		ecx, 0
	mov		edx, 0
	int		0x80

	mov		DWORD [ebp - 4], eax

	mov		eax, SYS_READ
	mov		ebx, DWORD [ebp - 4]
	lea		ecx, [ebp - 8]
	mov		edx, 4
	int		0x80

	mov		eax, SYS_CLOSE
	mov		ebx, DWORD [ebp - 4]
	int		0x80

	mov		eax, DWORD [ebp - 8]
	mov		esp, ebp
	pop		ebp
	ret

usleep:

	push	ebp
	mov		ebp, esp

	; struct timespec
	sub		esp, 8

	mov		DWORD [ebp - 8], 0		; sec
	mov		eax, DWORD [ebp + 8]
	mov		DWORD [ebp - 4], eax	; nsec

	mov		eax, SYS_NANOSLEEP
	lea		ebx, [ebp - 8]
	mov		edx, 0
	int		0x80

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
puts:

	push	ebp
	mov		ebp, esp

	mov		edx, DWORD [ebp + 8]
	len_loop:
	cmp		BYTE [edx], 0
	je		len_loop_end
		inc		edx
	jmp		len_loop
	len_loop_end:
	sub		edx, DWORD [ebp + 8]

	mov		eax, SYS_WRITE
	mov		ebx, STDOUT
	mov		ecx, [ebp + 8]
	; edx set above
	int		0x80

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
getchar:

	push	ebp
	mov		ebp, esp

	sub		esp, 4

	mov		DWORD [ebp - 4], 0

	mov		eax, SYS_READ
	mov		ebx, STDIN
	lea		ecx, [ebp - 4]
	mov		edx, 1
	int		0x80

	mov		eax, DWORD [ebp - 4]

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
putchar:

	push	ebp
	mov		ebp, esp

	mov		eax, SYS_WRITE
	mov		ebx, STDOUT
	lea		ecx, [ebp + 8]
	mov		edx, 1
	int		0x80

	mov		esp, ebp
	pop		ebp
	ret

; === FUNCTION ===
system:

	push	ebp
	mov		ebp, esp

	sub		esp, 12

	; setup argv[]
	mov		eax, DWORD [ebp + 8]
	mov		DWORD [ebp - 12], _bin_sh
	mov		DWORD [ebp - 8], _c
	mov		DWORD [ebp - 4], eax

	; fork()
	mov		eax, SYS_FORK
	int		0x80
	cmp		eax, 0
	jne		parent

	; if(child) execve(argv)
	mov		eax, SYS_EXECVE
	mov		ebx, _bin_sh
	lea		ecx, [ebp - 12]
	mov		edx, 0
	int		0x80

	parent:

	; else(parent) waitpid(pid)
	mov		ebx, eax
	mov		eax, SYS_WAITPID
	mov		ecx, 0
	mov		edx, 0
	int		0x80

	mov		esp, ebp
	pop		ebp
	ret

