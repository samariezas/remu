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
    riscv64-unknown-linux-musl-gcc -DLIBQPU -x c -c -Wall qpu.h -o libqpu.o
    riscv64-unknown-linux-musl-ar rcs libqpu.a libqpu.o 
  '';

  installPhase = ''
    mkdir -p $out/bin $out/include $out/lib
    cp qpu.h $out/include
    cp libqpu.a $out/lib
    cp ./build/* $out/bin
  '';

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
