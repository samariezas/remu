#include "tests.h"

#define TOHOST      __attribute__((section(".tohost")))
static volatile uint64_t tohost = 0;
static volatile uint64_t fromhost = 0;
volatile int step_idx = 0;

void write_tohost(uint64_t val) {
    val = val << 1 | 1;
    while(1) {
        tohost = val;
    }
}

void _test_failed(unsigned int failure_code, unsigned int line_num) {
    if (failure_code == 0) {
        printf_("FIXME: failure code is 0, line %u!", line_num);
        write_tohost(1);
    }
    printf_("Test failed on line %u, code %u\n", line_num, failure_code);
    write_tohost(failure_code);
}

void rvtest_assert(bool val, unsigned int line_num) {
    if (!val) {
        printf_("Assertion failed on line %u\n", line_num);
        TEST_FAILED();
    }
}

const char *priv_level_to_str(priv_level_t level) {
    switch (level) {
        case PRIV_USER: return "USER";
        case PRIV_SUPERVISOR: return "SUPERVISOR";
        case PRIV_MACHINE: return "MACHINE";
        default: return "UNKNOWN";
    }
}

priv_level_t get_priv(void) {
    uint64_t retval;
    asm volatile(
        ".insn u 0xb, %0, 0xf0f00"
        : "=r" (retval)
    );
    return retval;
}

void putchar_(char c) {
    static char *UART_DEVICE = (char*)0x10000000;
    *UART_DEVICE = c;
}
