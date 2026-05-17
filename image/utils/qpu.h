#ifndef QPU_H_
#define QPU_H_
#include <stdint.h>

#define RISCV_QPU_INSTR(funct7) "0b0101011, 1, " funct7

static inline uint64_t qpu_new_qureg(
    uint64_t initval,
    uint64_t width)
{
    uint64_t new_qureg_id;
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x10") ", %0, %1, %2"
        : "=r"(new_qureg_id) : "r"(initval), "r"(width)
    );
    return new_qureg_id;
}

static inline void qpu_cnot(
    uint64_t control,
    uint64_t target,
    uint64_t qureg)
{
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x11") ", %0, %1, %2"
        : : "r"(qureg), "r"(control), "r"(target)
    );
}

static inline void qpu_toffoli(
    uint64_t control1,
    uint64_t control2,
    uint64_t target,
    uint64_t qureg)
{
    asm volatile (
        "mv x10, %1\n"
        ".insn r " RISCV_QPU_INSTR("0x12") ", %3, %0, %2"
        : : "r"(control1), "r"(control2), "r"(target), "r"(qureg)
        : "x10"
    );
}

static inline void qpu_sigma_x(
    uint64_t target,
    uint64_t qureg)
{
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x13") ", %0, x0, %1"
        : : "r"(qureg), "r"(target)
    );
}

static inline void qpu_sigma_y(
    uint64_t target,
    uint64_t qureg)
{
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x14") ", %0, x0, %1"
        : : "r"(qureg), "r"(target)
    );
}

static inline void qpu_sigma_z(
    uint64_t target,
    uint64_t qureg)
{
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x15") ", %0, x0, %1"
        : : "r"(qureg), "r"(target)
    );
}

static inline void qpu_hadamard(
    uint64_t target,
    uint64_t qureg)
{
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x16") ", %0, x0, %1"
        : : "r"(qureg), "r"(target)
    );
}

static inline uint64_t qpu_bmeasure(
    uint64_t pos,
    uint64_t qureg)
{
    uint64_t retval;
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x17") ", %0, %1, %2"
        : "=r"(retval) : "r"(pos), "r"(qureg)
    );
    return retval;
}

static inline uint64_t qpu_getwidth(uint64_t n)
{
    uint64_t retval;
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x18") ", %0, %1, x0"
        : "=r"(retval) : "r"(n)
    );
    return retval;
}

static inline float qpu_prob(float r, float i)
{
    uint64_t retval;
    uint64_t rint = 0, iint = 0;
    *((float*)&rint) = r;
    *((float*)&iint) = i;
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x19") ", %0, %1, %2"
        : "=r"(retval) : "r"(rint), "r"(iint)
    );
    return *(float*)(&retval);
}

static inline uint64_t qpu_getregwidth(uint64_t qureg)
{
    uint64_t retval;
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x20") ", %0, %1, x0"
        : "=r"(retval) : "r"(qureg)
    );
    return retval;
}

static inline void qpu_setregwidth(uint64_t qureg, uint64_t val)
{
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x21") ", %0, %1, x0"
        : : "r"(qureg), "r"(val)
    );
}

static inline void qpu_get_reg_node(
    uint64_t qureg,
    uint64_t idx,
    uint64_t *state_out,
    float *amplitude_r_out,
    float *amplitude_i_out)
{
    uint64_t state, amplitude_r_int, amplitude_i_int;
    asm volatile (
        "mv x11, %3\n"
        "mv x12, %4\n"
        ".insn r " RISCV_QPU_INSTR("0x22") ", %0, %1, %2"
        : "=r"(state), "=r" (amplitude_r_int), "=r"(amplitude_i_int)
        : "r"(qureg), "r"(idx)
        : "x11", "x12"
    );
    *state_out = state;
    *amplitude_r_out = *(float*)(&amplitude_r_int);
    *amplitude_i_out = *(float*)(&amplitude_i_int);
}

static inline uint64_t qpu_getregsize(uint64_t qureg)
{
    uint64_t size;
    asm volatile (
        ".insn r " RISCV_QPU_INSTR("0x23") ", %0, %1, x0"
        : "=r"(size) : "r"(qureg)
    );
    return size;
}

static inline void qpu_incrementregwidth(uint64_t qureg)
{
    uint64_t old_width = qpu_getregwidth(qureg);
    qpu_setregwidth(qureg, old_width + 1);
}

#undef RISCV_QPU_INSTR
#endif // QPU_H_
