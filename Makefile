
all: snake.asm
	nasm -f elf32 -F dwarf -g snake.asm
	ld -m elf_i386 -o snake snake.o

clean:
	rm -rf snake
	rm -rf snake.o