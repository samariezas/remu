#!/usr/bin/env bash

set -xe

OUT_DIR=$(mktemp -d)
rm -f devshells/musl-export devshells/default-export
nix build ".#devShells.x86_64-linux.riscv-musl.inputDerivation" -o devshells/musl-export
nix build ".#devShells.x86_64-linux.default.inputDerivation" -o devshells/default-export
nix-store --export $({ nix-store -qR devshells/musl-export; nix-store -qR devshells/default-export; } | sort -u) | gzip > "${OUT_DIR}/devshell.nar.gz"
nix bundle --bundler github:ralismark/nix-appimage ".#remu" -o "${OUT_DIR}/remu.AppImage"
nix build ".#remu-package" -o remu-package.tar.gz -o "${OUT_DIR}/remu-package.tar.gz"

ssh jope9155@klevas.mif.vu.lt "rm -f ~/www/remu/*"
scp "${OUT_DIR}/"* jope9155@klevas.mif.vu.lt:~/www/remu
