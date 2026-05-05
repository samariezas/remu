#ifndef QUANTUM_WRAP_H_
#define QUANTUM_WRAP_H_
#include <quantum.h>

float quantum_prob_wrap(float r, float i);
void quantum_get_reg_node(
    quantum_reg *reg,
    int idx,
    MAX_UNSIGNED *state_out,
    float *amplitude_r_out,
    float *amplitude_i_out);

#endif // QUANTUM_WRAP_H_
