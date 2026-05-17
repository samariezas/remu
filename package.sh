#!/usr/bin/env bash

nix bundle --bundler github:ralismark/nix-appimage ".#remu"
nix build ".#remu-package" -o remu-package.tar.gz
