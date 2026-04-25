{ pkgs, pkgsCross }:
pkgsCross.stdenv.mkDerivation rec {
  name = "lua";
  version = "5.5.0";
  src = pkgs.fetchzip {
    url = "https://www.lua.org/ftp/lua-${version}.tar.gz";
    hash = "sha256-0hEjDzvMqWZaLLeDjjTH7SP8XDdObgZ+UydGr6/d46o=";
  };

  buildPhase = ''
    make -j8 CC=riscv64-unknown-linux-musl-gcc AR="riscv64-unknown-linux-musl-ar rcu" RANLIB=riscv64-unknown-linux-musl-ranlib linux
  '';

  installPhase = ''
    make -j8 INSTALL_TOP=$out install
  '';

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
