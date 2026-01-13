#ifndef TESTS_H_
#define TESTS_H_
#include <stdint.h>
#include <stdbool.h>
#include <printf.h>
#include <stdnoreturn.h>

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
noreturn void c_entry(void);
void c_s_trap_handler(void);
void c_m_trap_handler(void);

noreturn void write_tohost(uint64_t val);
noreturn void _test_failed(unsigned int failure_code, unsigned int line_num);
void rvtest_assert(bool val, unsigned int line_num);
const char *priv_level_to_str(priv_level_t level);
priv_level_t get_priv(void);
void putchar_(char c);
void dump_csrs(void);

static uint64_t get_csr_no_privcheck(uint32_t csr) {
    uint64_t retval;
    asm volatile(
        ".insn i 0x73, 4, %0, x0, %1"
        : "=r" (retval)
        : "i" (csr)
    );
    return retval;
}

#define STRINGIFY(x) #x
#define TOSTRING(x) STRINGIFY(x)

#define CSR_LIST \
    X_CSR(mtvec, 0x305) \
    X_CSR(mepc, 0x341) \
    X_CSR(mcause, 0x342) \
    X_CSR(mstatus, 0x300) \
    X_CSR(mtval, 0x343) \
    X_CSR(stvec, 0x105) \
    X_CSR(sepc, 0x141) \
    X_CSR(scause, 0x142) \
    X_CSR(sstatus, 0x100) \
    X_CSR(medeleg, 0x302) \
    X_CSR(stval, 0x143)

#define X_CSR(name, id) static uint64_t get_ ## name ## _no_privcheck(void) \
    { return get_csr_no_privcheck((id)); }
CSR_LIST
#undef X_CSR

typedef enum {
    EXCEPTION_MASK_ILLEGAL_INSTR    = (1 << 2),
    EXCEPTION_MASK_ECALL_FROM_U     = (1 << 8),
    EXCEPTION_MASK_ECALL_FROM_S     = (1 << 9),
    EXCEPTION_MASK_ECALL_FROM_M     = (1 << 11),
} exception_mask_t;

#endif // TESTS_H_
