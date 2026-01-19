{ pkgs, pkgsCross }:
pkgs.stdenv.mkDerivation {
  name = "busybox";
  version = "1.36.1";
  src = pkgs.fetchzip {
    url = "https://busybox.net/downloads/busybox-1.36.1.tar.bz2";
    hash = "sha256-jHbZDQxKZsCTCYiRrl3voeBcpQvFzLKthhqjiju8BFc=";
  };

  enableParallelBuilding = true;

  patches = [ ./busybox_libbb.patch ];

  nativeBuildInputs = with pkgsCross; [
    gcc
    binutils
  ];

  configurePhase = ''
    cp ${./configs/busybox.config} ./.config
    ${pkgs.gnused}/bin/sed -e "/CONFIG_PREFIX/d" -e "\$aCONFIG_PREFIX=\"$out\"" -i ./.config
  '';

  makeFlags = [
    "ARCH=riscv"
    "CROSS_COMPILE=riscv64-unknown-linux-musl-"
  ];

  fixupPhase = ''
    ${pkgs.findutils}/bin/find $out -executable -type f -exec patchelf --interpreter /lib/ld-musl-riscv64-sf.so.1 {} \;
  '';
}
