#!/usr/bin/env bash
set -xe
gdb ./image-build/linux/vmlinux.unstripped \
    --eval-command="set architecture riscv:rv64" \
    --eval-command="mem 0x0 0xffffffffffffffff ro" \
    --eval-command="set mem inaccessible-by-default off" \
    --eval-command="set confirm off" \
    --eval-command="set confirm on" \
    --eval-command="target remote ./image-build/gdb.sock" \
    --eval-command="set history save on" \
    --eval-command="c"
