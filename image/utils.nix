{ pkgs, pkgsCross }:
pkgsCross.stdenv.mkDerivation {
  name = "utils";
  version = "0.0.1";
  src = ./utils;

  buildPhase = ''
    riscv64-unknown-linux-musl-gcc floating.c -o floating
    riscv64-unknown-linux-musl-gcc grover.c -o grover
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp floating grover $out/bin
  '';

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
