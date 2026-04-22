#!/usr/bin/env bash
set -xe
gdb ./image-build/fw_dynamic.elf \
    --eval-command="set architecture riscv:rv64" \
    --eval-command="mem 0x80000000 0x100000000 ro" \
    --eval-command="set mem inaccessible-by-default off" \
    --eval-command="set confirm off" \
    --eval-command="add-symbol-file -readnow ./image-build/linux/vmlinux.unstripped 0xffffffff80000000" \
    --eval-command="set confirm on" \
    --eval-command="target remote ./image-build/gdb.sock" \
    --eval-command="c"
