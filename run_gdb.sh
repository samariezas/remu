#!/usr/bin/env bash
set -xe
gdb ./opensbi.elf \
    --eval-command="set architecture riscv:rv64" \
    --eval-command="mem 0x80000000 0x100000000 ro" \
    --eval-command="set mem inaccessible-by-default off" \
    --eval-command="add-symbol-file /tmp/building/source/vmlinux.unstripped 0x80000000" \
    --eval-command="add-symbol-file /tmp/building/source/vmlinux.unstripped 0xffffffff80000000" \
    --eval-command="target remote ./gdb.sock" \
    --eval-command="c"

#    --eval-command="add-symbol-file ./linux/vmlinux.unstripped 0x80000000" \
