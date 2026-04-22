#!/usr/bin/env bash
set -xe
rm -f gdb.sock
# TODO: build opensbi

time zig build -Doptimize=Debug
perf record --call-graph fp -D 3000-23000 zig-out/bin/bemu binary \
    ~/sources/opensbi/build/platform/generic/firmware/fw_dynamic.bin \
    ./simple.dtb \
    /tmp/building/source/arch/riscv/boot/Image


    # /tmp/building/source/arch/riscv/boot/Image \
    # ./gdb.sock

        # gdb ./zig-out/bin/bemu --eval-command="run binary ~/sources/opensbi/build/platform/generic/firmware/fw_dynamic.bin ./simple.dtb /tmp/build/source/arch/riscv/boot/Image"
        # gdb ./zig-out/bin/bemu --eval-command="run binary ~/sources/opensbi/build/platform/generic/firmware/fw_dynamic.bin ./simple.dtb /tmp/build/source/arch/riscv/boot/Image ./gdb.sock"
