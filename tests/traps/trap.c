#include <stdint.h>
#include <stdbool.h>

static volatile int idx = 0;
// static volatile int last_test_id = -1;

#define ELEM(X) (sizeof(X) / sizeof(X[0]))

typedef void (*test_function_t)(void);

#define TEST_PASS() do { write_tohost(0); } while(0)
#define TEST_FAILED(num) do { write_tohost(num); } while(0)
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
    if (!val) TEST_FAILED(-2);
}

RVTEST(1, {
    __asm__ __volatile__(".word 0x69420");
    TEST_FAILED(1);
})

typedef struct {
    unsigned int mcause;
    unsigned int mepc;
} test_result_t;

static test_function_t tests[] = {
    test1
};

__attribute__((section(".data.signature"))) struct {
    test_result_t interrupt_data[ELEM(tests)];
} test_results;

void c_trap_handler(void) {
    unsigned int mcause, mepc;
    // last_test_id = idx;
    __asm__ __volatile__ (
        "csrr %0, mcause;"
        "csrr %1, mepc;"
        : "=r" (mcause), "=r" (mepc)
    );
    test_results.interrupt_data[idx] = (test_result_t) {
        .mcause = mcause,
        .mepc = mepc,
    };
    idx++;
}

void c_entry(void) {
    // TODO: last_test_id
    // if (idx != last_test_id) {
    //     TEST_FAILED(-1);
    // }
    if (idx < ELEM(tests)) {
        tests[idx]();
        TEST_FAILED(-3);
    }
    TEST_PASS();
}
