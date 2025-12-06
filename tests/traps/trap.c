#include <stdbool.h>
#include <printf.h>
#include "tests.h"

/* Steps */
void test_illegal_instruction(void) {
    asm volatile (".word 0x69420");
}

/* Dropping/raising privilege levels */
// TODO: usermode_entry and supervisor_entry should reset the stack
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
        :: "i"(1UL << 8), "r"(usermode_entry)
        : "t0"
    );
}

void write_medeleg(uint64_t val) {
    asm volatile (
        "csrw medeleg, %0\n"
        :: "r"(val)
    );
}

void set_medeleg(void) {
    write_medeleg((int64_t)-1);
}

void clear_medeleg(void) {
    write_medeleg(0);
}

typedef struct {
    const char *name;
    step_function_t fn;
    bool expect_trap;
} step_t;

#define MAKE_STEP(fn, expect_trap) { TOSTRING(fn), (fn), (expect_trap) }
static step_t steps[] = {
    MAKE_STEP(set_medeleg,                      false),
    MAKE_STEP(test_illegal_instruction,         true),
    MAKE_STEP(ecall,                            true),
    MAKE_STEP(drop_to_supervisor,               true),
    MAKE_STEP(test_illegal_instruction,         true),
    MAKE_STEP(drop_from_supervisor_to_user,     true),
    // MAKE_STEP(ecall,                            true),
};

static volatile bool should_trap = false;
static void c_trap_handler(void) {
    ASSERT(should_trap);
    // simple double-trap checking
    static volatile bool currently_handling = false;
    if (currently_handling) {
        TEST_FAILED();
    }
    currently_handling = true;

    priv_level_t current_privilege = get_priv();
    printf_("TRAP step %i, priv=%s\n", step_idx, priv_level_to_str(current_privilege));
    dump_csrs();
    step_idx++;
    currently_handling = false;
}

void c_s_trap_handler(void) {
    printf_("Entered S trap handler\n");
    c_trap_handler();
}

void c_m_trap_handler(void) {
    printf_("Entered M trap handler\n");
    c_trap_handler();
}

void c_start(void) {
    printf_("Core booting, register dump:\n");
    dump_csrs();
}

void c_entry(void) {
    static int previous_idx = -1;
    printf_("Entrypoint reached, priv=%s\n", priv_level_to_str(get_priv()));
    while (step_idx < ELEM(steps)) {
        step_t *step = &steps[step_idx];
        printf_("Executing step %i (%s)\n", step_idx, step->name);
        dump_csrs();
        if (previous_idx == step_idx) {
            printf_("Failed test, executing same step again\n");
            TEST_FAILED();
        }
        previous_idx = step_idx;
        should_trap = step->expect_trap;
        step->fn();
        if (step->expect_trap) {
            // should have trapped, but we didn't
            TEST_FAILED();
        }
        step_idx += 1;
    }

    printf_("Done with priv=%s\n", priv_level_to_str(get_priv()));
    dump_csrs();
    TEST_PASS();
}
