{ pkgs, pkgsCross }:
pkgsCross.stdenv.mkDerivation {
  name = "utils";
  version = "0.0.1";
  src = ./utils;

  buildPhase = ''
    riscv64-unknown-linux-musl-gcc -O2 -Wall floating.c -o floating
    riscv64-unknown-linux-musl-gcc -O2 -Wall grover.c -o grover
  '';

  installPhase = ''
    mkdir -p $out/bin $out/include
    cp qpu.h $out/include
    cp floating grover $out/bin
  '';

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
