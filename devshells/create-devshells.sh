#!/usr/bin/env bash
set -euo pipefail
set -x

BASEDIR="$(dirname "$0")"
rm -f \
    "$BASEDIR/default" \
    "$BASEDIR/riscv" \
    "$BASEDIR/image-linux" \
    "$BASEDIR/image-initramfs" \
    "$BASEDIR"/*-1-link

nix develop "$BASEDIR/..#devShells.x86_64-linux.default" --profile $BASEDIR/default -c true
nix develop "$BASEDIR/..#devShells.x86_64-linux.riscv" --profile $BASEDIR/riscv -c true
nix develop "$BASEDIR/..#image-linux" --profile $BASEDIR/image-linux -c true
nix develop "$BASEDIR/..#image-initramfs" --profile $BASEDIR/image-initramfs -c true
