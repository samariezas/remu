#!/usr/bin/env bash
EXTRA_ARGS=()
while test $# != 0
do
    case "$1" in
        -d) EXTRA_ARGS=(-s -S)
    esac
    shift
done
set -xe
qemu-system-riscv64 ${EXTRA_ARGS[@]} -bios none -display none -machine spike,signature=/tmp/sig -kernel ./trap
cat /tmp/sig
