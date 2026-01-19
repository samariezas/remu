{ pkgsCross, ... }:
pkgsCross.stdenv.mkDerivation {
  name = "musl";
  version = "1.2.5";

  src = pkgsCross.fetchzip {
    url = "https://musl.libc.org/releases/musl-1.2.5.tar.gz";
    hash = "sha256-xNKVsRfEK7TkSiYrxPho9ap8MWGix7nVHLecGW0D7kE=";
  };

  enableParallelBuilding = true;

  configureStep = ''
    CROSS_COMPILE=riscv64-unknown-linux-musl- ./configure \
        --prefix=$out \
        --syslibdir=$out/lib \
        --enable-shared \
        --enable-static
  '';

  dontFixup = false;
}
