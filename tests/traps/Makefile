CC := riscv64-none-elf-gcc
LDFLAGS := -nostdlib -nostartfiles -nostdlib -nostartfiles -T ./link.ld
LDLIBS := -lprintf
CFLAGS := -c -O2 -march=rv64g -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles

.PHONY: all
all: build/trap

build/tests.o: tests.c tests.h
	$(CC) $(CFLAGS) $< -o $@

build/boot.o: boot.s
	$(CC) $(CFLAGS) $< -o $@

build/trap.o: trap.c tests.h
	$(CC) $(CFLAGS) $< -o $@

build/trap: build/trap.o build/boot.o build/tests.o
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS) 
