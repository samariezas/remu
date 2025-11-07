#include <stdint.h>
#include <stdbool.h>
#include <printf.h>

static volatile int idx = 0;
// static volatile int last_test_id = -1;

#define ELEM(X) (sizeof(X) / sizeof(X[0]))

typedef void (*test_function_t)(void);

#define TEST_PASS() do { write_tohost(0); } while(0)
#define TEST_FAILED(num) do { write_tohost(num); } while(0)
#define GENERIC_FAILURE(num) do { TEST_FAILED((num) + 64); } while(0)
// TODO: perform asserts
// #define RVTEST(TEST_NUM, TEST_BLOCK) void test ## TEST_NUM (void) { rvtest_assert(idx == TEST_NUM); TEST_BLOCK }
#define RVTEST(TEST_NUM, TEST_BLOCK) void test ## TEST_NUM (void) { TEST_BLOCK }

__attribute__((section(".tohost"))) volatile uint64_t tohost = 0, fromhost = 0;

void write_tohost(uint64_t val) {
    val = val << 1 | 1;
    while(1) {
        tohost = val;
    }
}

void rvtest_assert(bool val) {
    if (!val) GENERIC_FAILURE(1);
}

// Illegal instruction
RVTEST(1, {
    __asm__ __volatile__(".word 0x69420");
    TEST_FAILED(1);
})

// ECALL from machine mode
RVTEST(2, {
    __asm__ __volatile__("ecall");
    TEST_FAILED(2);
})

void c_trap_handler(void);

void test3_userspace(void) {
    TEST_FAILED(3);
}

RVTEST(3, {
    asm volatile (
        "li t0, %0\n"
        "csrrc x0, mstatus, t0\n"
        :: "i"(3UL << 11)
        : "t0"
    );
    asm volatile ("csrw mepc, %0" :: "r"(test3_userspace));
    asm volatile ("mret");
    TEST_FAILED(3);
})

typedef struct {
    uint64_t mcause;
    uint64_t mepc;
    uint64_t mstatus;
} test_result_t;

typedef enum {
    PRIV_USER = 0,
    PRIV_SUPERVISOR = 1,
    PRIV_MACHINE = 3,
} priv_level_t;

typedef struct {
    test_function_t fn;
    priv_level_t priv_level;
} test_t;

static test_t tests[] = {
    { test1, PRIV_MACHINE },
    { test2, PRIV_MACHINE },
    { test3, PRIV_USER    },
};

static volatile __attribute__((section(".data.signature"))) struct {
    // unsigned int privilege_written;
    // uint8_t privilege_levels[16];
    test_result_t interrupt_data[ELEM(tests)];
    uint8_t test3_privilege_level;
} test_results;

// void push_current_privilege(void) {
//     rvtest_assert(test_results.privilege_written < ELEM(test_results.privilege_levels));
//     uint8_t priv = (get_priv() << 1) | 1;
//     test_results.privilege_levels[test_results.privilege_written++] = priv;
// }

#define GETPRIV_ENABLED

static inline uint8_t get_priv(void) {
#ifdef GETPRIV_ENABLED
    uint64_t retval;
    __asm__ __volatile__(
        ".insn u 0xb, %0, 0xf0f00"
        : "=r" (retval)
    );
    return retval;
#else
    return tests[idx].priv_level;
#endif
}

void c_trap_handler(void) {
    static volatile bool currently_handling = false;
    if (currently_handling) {
        // simple double-trap checking
        GENERIC_FAILURE(2);
    }
    currently_handling = true;
    uint8_t current_privilege = get_priv();
    if (current_privilege != tests[idx].priv_level) {
        GENERIC_FAILURE(4);
    }
    if (tests[idx].priv_level == PRIV_MACHINE) {
        uint64_t mcause, mepc, mstatus;
        __asm__ __volatile__ (
            "csrr %0, mcause;"
            "csrr %1, mepc;"
            "csrr %2, mstatus;"
            : "=r" (mcause), "=r" (mepc), "=r" (mstatus)
        );
        test_results.interrupt_data[idx] = (test_result_t) {
            .mcause = mcause,
            .mepc = mepc,
            .mstatus = mstatus,
        };
    }
    idx++;
    currently_handling = false;
}

void putchar_(char c) {
    static char *UART_DEVICE = (char*)0x10000000;
    *UART_DEVICE = c;
}

void c_entry(void) {
    // if (idx < ELEM(tests)) {
    //     tests[idx].fn();
    //     GENERIC_FAILURE(3);
    // }
    test_results.test3_privilege_level = 1;
    int x = 0x1234;
    printf_("Privilege level: %u\n", get_priv());
    TEST_PASS();
}
