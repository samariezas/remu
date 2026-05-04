#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#define RISCV_QPU_INSTR(funct7) "0b0101011, 1, " funct7

static inline uint64_t qpu_new_qureg(uint64_t initval, uint64_t width) {
    uint64_t new_qureg_id;
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x10") ", %0, x0, x0"
        : "=r"(new_qureg_id)
    );
    return new_qureg_id;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Not enough arguments: %s <amount of registers>\n", argv[0]);
        return 1;
    }
    int count = atoi(argv[1]);
    for (int i = 0; i < count; i++) {
        uint64_t reg = qpu_new_qureg(100, 18);
        printf("Register value: %lu\n", reg);
        sleep(1);
    }
}
