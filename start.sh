#!/usr/bin/env bash
rm -f gdb.sock && \
        zig build && \
        ./zig-out/bin/bemu binary ~/sources/opensbi/build/platform/generic/firmware/fw_dynamic.bin ./simple.dtb ~/sources/Image
        # gdb ./zig-out/bin/bemu --eval-command="run binary ~/sources/opensbi/build/platform/generic/firmware/fw_dynamic.bin ./simple.dtb /tmp/build/source/arch/riscv/boot/Image"
        # gdb ./zig-out/bin/bemu --eval-command="run binary ~/sources/opensbi/build/platform/generic/firmware/fw_dynamic.bin ./simple.dtb /tmp/build/source/arch/riscv/boot/Image ./gdb.sock"
