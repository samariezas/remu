#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include <string.h>

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
    // printf("Got: %li %li %li %f %f\n", state, amplitude_r_int, amplitude_i_int, *amplitude_r_out, *amplitude_i_out);
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

#ifdef M_PI
#define pi M_PI
#else
#define pi 3.141592654
#endif

void oracle(int state, uint64_t reg)
{
  int i;

    for(i=0;i<qpu_getregwidth(reg);i++)
    {
        if(!(state & (1 << i)))
        {
          qpu_sigma_x(i, reg);
        }
    }

  qpu_toffoli(0, 1, qpu_getregwidth(reg)+1, reg);

  for(i=1;i<qpu_getregwidth(reg);i++)
    {
        uint64_t width = qpu_getregwidth(reg);
        qpu_toffoli(i, width+i, width+i+1, reg);
    }

  uint64_t width = qpu_getregwidth(reg);
  qpu_cnot(width+i, width, reg);

  for(i=qpu_getregwidth(reg)-1;i>0;i--)
    {
      qpu_toffoli(i, qpu_getregwidth(reg)+i, qpu_getregwidth(reg)+i+1, reg);
    }

  qpu_toffoli(0, 1, qpu_getregwidth(reg)+1, reg);

  for(i=0;i<qpu_getregwidth(reg);i++)
    {
      if(!(state & (1 << i)))
	qpu_sigma_x(i, reg);
    }

}

void inversion(uint64_t reg)
{
  int i;

  for(i=0;i<qpu_getregwidth(reg);i++)
    qpu_sigma_x(i, reg);

  qpu_hadamard(qpu_getregwidth(reg)-1, reg);

  if (qpu_getregwidth(reg) == 3) {
    qpu_toffoli(0, 1, 2, reg);
  } else {
      qpu_toffoli(0, 1, qpu_getregwidth(reg)+1, reg);
      for (i=1;i<qpu_getregwidth(reg)-1;i++)
      {
          uint64_t width = qpu_getregwidth(reg);
          qpu_toffoli(i, width+i, width+i+1, reg);
      }

      {
          uint64_t width = qpu_getregwidth(reg);
          qpu_cnot(width+i, width-1, reg);
      }

      for(i=qpu_getregwidth(reg)-2;i>0;i--)
	  {
          uint64_t width = qpu_getregwidth(reg);
	      qpu_toffoli(i, width+i, width+i+1, reg);
	  }
      qpu_toffoli(0, 1, qpu_getregwidth(reg)+1, reg);
  }

  qpu_hadamard(qpu_getregwidth(reg)-1, reg);

  for(i=0;i<qpu_getregwidth(reg);i++)
    qpu_sigma_x(i, reg);
}


void grover(int target, uint64_t reg)
{
  int i;

  oracle(target, reg);

  for(i=0;i<qpu_getregwidth(reg);i++)
    qpu_hadamard(i, reg);

  inversion(reg);

  for(i=0;i<qpu_getregwidth(reg);i++)
    qpu_hadamard(i, reg);
}

int main(int argc, char **argv)
{
  uint64_t reg;
  int i, N, width=0;

  if(argc==1)
    {
      printf("Usage: grover [number] [[qubits]]\n\n");
      return 3;
    }

  N=atoi(argv[1]);

  if(argc > 2)
    width = atoi(argv[2]);

  if(width < qpu_getwidth(N+1))
    width = qpu_getwidth(N+1);

  printf("Creating qureg with width %i\n", width);
  reg = qpu_new_qureg(0, width);
  printf("Qureg width: %li\n", qpu_getregwidth(reg));

  uint64_t temp_width = qpu_getregwidth(reg);
  qpu_sigma_x(temp_width, reg);

  for(i=0;i<qpu_getregwidth(reg);i++)
    qpu_hadamard(i, reg);

  qpu_hadamard(qpu_getregwidth(reg), reg);

  int iter_count = pi/4*sqrt(1 << qpu_getregwidth(reg));
  printf("Iterating %i times\n", iter_count);

  for(i=1; i<=iter_count; i++)
    {
      printf("Iteration #%i\n", i);
      grover(N, reg);
    }

  qpu_hadamard(qpu_getregwidth(reg), reg);

  qpu_incrementregwidth(reg);

  qpu_bmeasure(qpu_getregwidth(reg)-1, reg);

  for(i=0; i<qpu_getregsize(reg); i++)
    {
      uint64_t state;
      float amplitude_r, amplitude_i;
      qpu_get_reg_node(reg, i, &state, &amplitude_r, &amplitude_i);
      if(state == N)
	  printf("\nFound %i with a probability of %f\n\n", N, 
	       qpu_prob(amplitude_r, amplitude_i));
    }

  // quantum_delete_qureg(&reg);

  return 0;
}
