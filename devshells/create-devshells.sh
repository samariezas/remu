#!/usr/bin/env bash
set -euo pipefail
set -x

BASEDIR="$(dirname "$0")"
rm -f "$BASEDIR/default" "$BASEDIR/riscv" "$BASEDIR"/*-1-link

nix develop "$BASEDIR/..#devShells.x86_64-linux.default" --profile $BASEDIR/default -c true
nix develop "$BASEDIR/..#devShells.x86_64-linux.riscv" --profile $BASEDIR/riscv -c true
