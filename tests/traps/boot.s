.section .text.boot
.align  6
.extern _stack_start
.extern c_start
.extern c_entry
.extern c_trap_handler

.globl _start
_start:
    # TODO: zero-out .bss? or check it is zeroed?
    la t0, _trap_handler
    csrw mtvec, t0
    la sp, _stack_start
    call c_start
    j c_entry

.section .text
.globl _trap_handler
_trap_handler:
    call c_trap_handler
    la sp, _stack_start
    la t0, c_entry
    csrw mepc, t0
    mret
