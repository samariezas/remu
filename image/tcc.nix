{ pkgs, pkgsCross, ... }:
pkgsCross.stdenv.mkDerivation {
  name = "tcc";
  version = "mob";
  src = pkgsCross.fetchgit {
    url = "git://repo.or.cz/tinycc.git";
    rev = "601a0882148f11575367c5f2e54261cad9b00141";
    hash = "sha256-LIQgp1feCTDprY7FnLsRxe3VqWpD2ZkZwSzUqm2BWiY=";
  };

  enableParallelBuilding = true;

  patches = [ ./tcc.patch ];

  nativeBuildInputs = (with pkgs; [
    gcc
    binutils
  ]);

  postPatch = ''
    sed -i 's/^arm-libtcc1-usegcc.*$/riscv64-libtcc1-usegcc=yes/' lib/Makefile
  '';

  configurePhase = ''
    ./configure \
        --prefix=$out \
        --tccdir=$out/lib \
        --cross-prefix=riscv64-unknown-linux-musl- \
        --sysincludepaths=/lib/include:/include \
        --triplet=riscv64-linux-musl \
        --libpaths=/lib \
        --crtprefix=/lib \
        --cpu=riscv64 \
        --cc=gcc \
        --ar=ar \
        --enable-cross \
        --config-musl
  '';

  buildFlags = [ "cross-riscv64" ];

  postInstall = ''
    ln -s ./riscv64-tcc $out/bin/tcc
    ln -s ./riscv64-libtcc1.a $out/lib/libtcc1.a
  '';

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
