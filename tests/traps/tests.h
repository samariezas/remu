#ifndef TESTS_H_
#define TESTS_H_
#include <stdint.h>
#include <stdbool.h>
#include <printf.h>

#define ELEM(X) (sizeof(X) / sizeof(X[0]))

#define TEST_PASS() do { write_tohost(0); } while(0)
#define TEST_FAILED_SPEC(num) do { _test_failed(num, __LINE__); } while(0)
#define TEST_FAILED() TEST_FAILED_SPEC((step_idx + 1))
#define ASSERT(x) do { rvtest_assert((x), __LINE__); } while(0)

#define SIGNATURE   __attribute__((section(".data.signature")))

typedef enum {
    PRIV_USER = 0,
    PRIV_SUPERVISOR = 1,
    PRIV_MACHINE = 3,
} priv_level_t;
typedef void (*step_function_t)(void);

extern volatile int step_idx;

int printf_(const char* format, ...);
void c_start(void);
void c_entry(void);
void c_trap_handler(void);

void write_tohost(uint64_t val);
void _test_failed(unsigned int failure_code, unsigned int line_num);
void rvtest_assert(bool val, unsigned int line_num);
const char *priv_level_to_str(priv_level_t level);
priv_level_t get_priv(void);
void putchar_(char c);

static uint64_t get_csr_no_privcheck(uint32_t csr) {
    uint64_t retval;
    asm volatile(
        ".insn i 0x73, 4, %0, x0, %1"
        : "=r" (retval)
        : "i" (csr)
    );
    return retval;
}

#define MAKE_CSR_GETTER(name, id) static uint64_t get_ ## name ## _no_privcheck(void) \
    { return get_csr_no_privcheck((id)); }
MAKE_CSR_GETTER(mcause, 0x342)
MAKE_CSR_GETTER(mstatus, 0x300)
MAKE_CSR_GETTER(mepc, 0x341)
MAKE_CSR_GETTER(scause, 0x142)
MAKE_CSR_GETTER(sstatus, 0x100)
MAKE_CSR_GETTER(sepc, 0x141)
#undef MAKE_CSR_GETTER

#endif // TESTS_H_
