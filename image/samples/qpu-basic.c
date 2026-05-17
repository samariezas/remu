#include <stdio.h>
#include <qpu.h>

int main(){
    uint64_t id = qpu_new_qureg(0, 3);
    printf("QPU register id: %llu\n", id);
    qpu_hadamard(0, id);
    qpu_cnot(0, 1, id);
    qpu_toffoli(0, 1, 2, id);

    qpu_sigma_x(2, id);
    qpu_sigma_y(1, id);
    qpu_sigma_z(0, id);

    int r2 = qpu_bmeasure(2, id);
    int r1 = qpu_bmeasure(1, id);
    int r0 = qpu_bmeasure(0, id);
    printf("q0=%d, q1=%d, q2=%d\n", r0, r1, r2);
    return 0;
}
