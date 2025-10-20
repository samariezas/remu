#!/usr/bin/env bash
set -xe
riscv64-none-elf-gcc -g -O0 -static -march=rv64g -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -T ./link.ld boot.s trap.c -o trap
