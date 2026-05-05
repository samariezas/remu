#include <complex.h>
#include "quantum-wrap.h"

float quantum_prob_wrap(float r, float i)
{
    return quantum_prob(r + _Complex_I * i);
}

void quantum_get_reg_node(
    quantum_reg *reg,
    int idx,
    MAX_UNSIGNED *state_out,
    float *amplitude_r_out,
    float *amplitude_i_out)
{
    *state_out = reg->node[idx].state;
    COMPLEX_FLOAT amplitude = reg->node[idx].amplitude;
    *amplitude_r_out = crealf(amplitude);
    *amplitude_i_out = cimagf(amplitude);
}
