.section .text.boot
.align  6
.extern _stack_start
.extern c_start
.extern c_entry
.extern c_s_trap_handler
.extern c_m_trap_handler

.globl _start
_start:
    # TODO: zero-out .bss? or check it is zeroed?
    la t0, _s_trap_handler
    csrw stvec, t0
    la t0, _m_trap_handler
    csrw mtvec, t0
    la sp, _stack_start
    call c_start
    j c_entry

.section .text
_s_trap_handler:
    call c_s_trap_handler
    la sp, _stack_start
    j c_entry

_m_trap_handler:
    call c_m_trap_handler
    la sp, _stack_start
    j c_entry
