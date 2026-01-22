#!/usr/bin/env bash
set -xe
# gdb ./tests/traps/build/trap \
gdb ./opensbi.elf \
    --eval-command="set architecture riscv:rv64" \
    --eval-command="mem 0x80000000 0x100000000 ro" \
    --eval-command="add-symbol-file ../vmlinux.unstripped 0x90000000" \
    --eval-command="target remote ./gdb.sock" \
    --eval-command="b *0x90000098" \
    --eval-command="c"

    # --eval-command="b *0x90000094" \
    # --eval-command="b arch/riscv/mm/init.c:1204" \
    # --eval-command="b arch/riscv/mm/init.c:1221" \
    # --eval-command="b create_pgd_mapping" \
    # --eval-command="b setup_vm" \
