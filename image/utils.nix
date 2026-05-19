{ pkgs, pkgsCross }:
pkgsCross.stdenv.mkDerivation {
  name = "utils";
  version = "0.0.1";
  src = ./utils;

  buildPhase = ''
    mkdir -p ./build
    for CFILE in ./*.c; do
        riscv64-unknown-linux-musl-gcc -O2 -Wall $CFILE -o "./build/''${CFILE%.*}"
    done
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp ./build/* $out/bin
  '';

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
