#include <stdint.h>
#include <stdbool.h>
#include <printf.h>


#define ELEM(X) (sizeof(X) / sizeof(X[0]))

#define TEST_PASS() do { write_tohost(0); } while(0)
#define TEST_FAILED_SPEC(num) do { write_tohost(num); } while(0)
#define TEST_FAILED() TEST_FAILED_SPEC(step_idx)

#define TOHOST      __attribute__((section(".tohost")))
#define SIGNATURE   __attribute__((section(".data.signature")))
#define ASSERT(x) do { rvtest_assert((x), __LINE__); } while(0)

typedef void (*step_function_t)(void);
void c_trap_handler(void);
void c_entry(void);

TOHOST volatile uint64_t tohost = 0, fromhost = 0;
static volatile int step_idx = 0;

static void write_tohost(uint64_t val) {
    val = val << 1 | 1;
    while(1) {
        tohost = val;
    }
}

static void rvtest_assert(bool val, unsigned int line_num) {
    if (!val) {
        printf_("Assertion failed on line %u\n", line_num);
        TEST_FAILED();
    }
}

typedef enum {
    PRIV_USER = 0,
    PRIV_SUPERVISOR = 1,
    PRIV_MACHINE = 3,
} priv_level_t;

const char *priv_level_to_str(priv_level_t level) {
    switch (level) {
        case PRIV_USER: return "USER";
        case PRIV_SUPERVISOR: return "SUPERVISOR";
        case PRIV_MACHINE: return "MACHINE";
        default: return "UNKNOWN";
    }
}

static priv_level_t get_priv(void) {
    uint64_t retval;
    __asm__ __volatile__(
        ".insn u 0xb, %0, 0xf0f00"
        : "=r" (retval)
    );
    return retval;
}

/* Steps */

void test_illegal_instruction(void) {
    asm volatile (".word 0x69420");
}

/* Dropping/raising privilege levels */
void usermode_entry(void) {
    priv_level_t priv = get_priv();
    if (priv == PRIV_USER) {
        printf_("Entered user priv\n");
    } else {
        printf_("Failed to enter user priv (entered %s)\n", priv_level_to_str(priv));
        TEST_FAILED();
    }
    step_idx++;
    c_entry();
}

void supervisor_entry(void) {
    priv_level_t priv = get_priv();
    if (priv == PRIV_SUPERVISOR) {
        printf_("Entered supervisor priv\n");
    } else {
        printf_("Failed to enter supervisor priv (entered %s)\n", priv_level_to_str(priv));
        TEST_FAILED();
    }
    step_idx++;
    c_entry();
}

void ecall(void) {
    asm volatile ("ecall");
}

void drop_from_machine_to_user(void) {
    ASSERT(usermode_entry);
    asm volatile (
        "li t0, %0\n"
        "csrrc x0, mstatus, t0\n"
        "csrw mepc, %1\n" 
        "mret\n"
        :: "i"(3UL << 11), "r"(usermode_entry)
        : "t0"
    );
}

void drop_to_supervisor(void) {
    asm volatile (
        "li t0, %0\n"
        "csrrc x0, mstatus, t0\n"
        "li t0, %1\n"
        "csrrs x0, mstatus, t0\n"
        "csrw mepc, %2\n"
        "mret\n"
        :: "i"(3UL << 11), "i"(1UL << 11), "r"(supervisor_entry)
        : "t0"
    );
}

void drop_from_supervisor_to_user(void) {
    asm volatile (
        "li t0, %0\n"
        "csrrc x0, sstatus, t0\n"
        "csrw sepc, %1\n" 
        "sret\n"
        :: "i"(3UL << 11), "r"(usermode_entry)
        : "t0"
    );
}

typedef struct {
    step_function_t fn;
    bool expect_trap;
} step_t;

static step_t steps[] = {
    { test_illegal_instruction,         true },
    { ecall,                            true },
    { drop_to_supervisor,               true },
    { drop_from_supervisor_to_user,     true },
    { ecall,                            true },
};

SIGNATURE static volatile struct {
    //empty for now
} test_results;

static volatile bool should_trap = false;
void c_trap_handler(void) {
    ASSERT(should_trap);
    // simple double-trap checking
    static volatile bool currently_handling = false;
    if (currently_handling) {
        TEST_FAILED();
    }
    currently_handling = true;

    priv_level_t current_privilege = get_priv();
    printf_("TRAP step %i, priv=%s\n", step_idx, priv_level_to_str(current_privilege));
    if (current_privilege == PRIV_MACHINE) {
        uint64_t mcause, mepc, mstatus;
        __asm__ __volatile__ (
            "csrr %0, mcause;"
            "csrr %1, mepc;"
            "csrr %2, mstatus;"
            : "=r" (mcause), "=r" (mepc), "=r" (mstatus)
        );
        printf_("mcause=%lx, mepc=%lx, mstatus=%lx\n", mcause, mepc, mstatus);
    }
    step_idx++;
    currently_handling = false;
}

void putchar_(char c) {
    static char *UART_DEVICE = (char*)0x10000000;
    *UART_DEVICE = c;
}

void c_entry(void) {
    static int previous_idx = -1;
    while (step_idx < ELEM(steps)) {
        printf_("Executing step %i at priv level %s\n",
                step_idx, priv_level_to_str(get_priv()));
        if (previous_idx == step_idx) {
            printf_("Failed test, executing same step again\n");
            TEST_FAILED();
        }
        previous_idx = step_idx;
        step_t *step = &steps[step_idx];
        should_trap = step->expect_trap;
        step->fn();
        if (step->expect_trap) {
            // should have trapped, but we didn't
            TEST_FAILED();
        }
        step_idx += 1;
    }
    TEST_PASS();
}
