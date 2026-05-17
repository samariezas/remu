#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include <string.h>
#include <time.h>

#include "qpu.h"

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

  struct timespec start, end;
  clock_gettime(CLOCK_MONOTONIC, &start);

  if(width < qpu_getwidth(N+1))
    width = qpu_getwidth(N+1);

  reg = qpu_new_qureg(0, width);

  uint64_t temp_width = qpu_getregwidth(reg);
  qpu_sigma_x(temp_width, reg);

  for(i=0;i<qpu_getregwidth(reg);i++)
    qpu_hadamard(i, reg);

  qpu_hadamard(qpu_getregwidth(reg), reg);

  int iter_count = pi/4*sqrt(1 << qpu_getregwidth(reg));
  printf("Iterating %i times\n", iter_count);

  for(i=1; i<=iter_count; i++)
    {
      // printf("Iteration #%i\n", i);
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
  clock_gettime(CLOCK_MONOTONIC, &end);
  unsigned long long ns_taken = (end.tv_sec - start.tv_sec) * 1000000000 + (end.tv_nsec - start.tv_nsec);
  printf("Time taken: %llu\n", ns_taken);

  return 0;
}
